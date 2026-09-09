#!/usr/bin/env bash
#
# Runs INSIDE the Omarchy guest, once, after the interactive install.
# manage-agent-vm.sh renders the placeholders and serves this over the network;
# you fetch and run it with the single command that command prints.
#
# It provisions remote access, installs the agent control kit, points the guest
# at the host, and removes the per-install state that would otherwise make
# every reset slightly different from the last.
#
# Ordering is deliberate: SSH is enabled and started as early as possible, so
# that if any later step fails you can still get in from the host and see what
# happened, instead of being locked out of a guest that is almost ready.
#
# Deliberately NOT removed: the SSH host keys. Regenerating them would change
# the guest fingerprint on every reset and train you to click through host key
# warnings, which is the habit that makes such a warning useless. Also kept:
# /etc/machine-id, so the DHCP client identifier is stable and the guest always
# receives its reserved address.

set -uo pipefail

GUEST_USER="@GUEST_USER@"
VM_HOSTNAME="@VM_NAME@"
SANDBOX_HOST_IP="@SANDBOX_HOST_IP@"
SANDBOX_PREFIX="@SANDBOX_SUBNET_PREFIX@"
PROXY_PORT="@PROXY_PORT@"
GATEWAY_PORT="@GATEWAY_PORT@"
SHARE_TAG="@SHARE_TAG@"
SHARE_MOUNT="@SHARE_MOUNT@"
WORKSTATION_SUBNET="@WORKSTATION_SUBNET@"
SANDBOX_SUBNET="@SANDBOX_SUBNET@"
SEAL_URL="@SEAL_URL@"
PUBKEY="@PUBKEY@"

WARNINGS=()

step() { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }
note() { printf '    %s\n' "$1"; }
warn() { printf '  \033[1;33m!\033[0m %s\n' "$1"; WARNINGS+=("$1"); }
fatal() { printf '  \033[1;31m✘\033[0m %s\n' "$1" >&2; exit 1; }

# Run a step that is worth having but not worth aborting for. A failure here
# leaves a usable guest and a message at the end, rather than a half-sealed one.
optional() {
    local what="$1"; shift
    if ! "$@"; then
        warn "${what} failed. The guest still works; see the summary below."
        return 1
    fi
}

if [[ $EUID -ne 0 ]]; then
    echo "seal-guest: re-running under sudo" >&2
    exec sudo -E bash "$0" "$@"
fi

# --------------------------------------------------------------------------
# The account name is chosen during the Omarchy install and the host has no way
# to know it in advance. Rather than insisting the two match, take the account
# that invoked sudo and tell the host what it was.
if ! id "$GUEST_USER" &>/dev/null; then
    if [[ -n "${SUDO_USER:-}" ]] && id "$SUDO_USER" &>/dev/null && [[ "$SUDO_USER" != root ]]; then
        note "No user '$GUEST_USER' here; using '$SUDO_USER' instead."
        GUEST_USER="$SUDO_USER"
    else
        fatal "No such user '$GUEST_USER', and could not work out which account you use.
    Set GUEST_USER in config/omavm.conf and run the seal step again."
    fi
fi
HOME_DIR=$(getent passwd "$GUEST_USER" | cut -d: -f6)
[[ -d "$HOME_DIR" ]] || fatal "No home directory for '$GUEST_USER'."

# Report the account back over the same server that served this script, so the
# host knows which user to connect as. The request 404s; the point is the entry
# it leaves in the server's access log.
if [[ -n "$SEAL_URL" ]]; then
    curl -s -o /dev/null "${SEAL_URL}/whoami/${GUEST_USER}" 2>/dev/null || true
fi

# --------------------------------------------------------------------------
step "Installing remote access"
# Everything else can be repaired over SSH, so this is the one group whose
# failure is fatal.
if ! pacman -Sy --needed --noconfirm openssh; then
    fatal "Could not install openssh. Check the guest has working internet:
    ping -c1 archlinux.org"
fi

install -d -m 0700 -o "$GUEST_USER" -g "$GUEST_USER" "${HOME_DIR}/.ssh"
printf '%s\n' "$PUBKEY" > "${HOME_DIR}/.ssh/authorized_keys"
chown "${GUEST_USER}:${GUEST_USER}" "${HOME_DIR}/.ssh/authorized_keys"
chmod 0600 "${HOME_DIR}/.ssh/authorized_keys"

install -d -m 0755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/10-omavm.conf <<'SSHD'
# Managed by omavm seal-guest.sh
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
SSHD

# Start it now, not just enable it. From this point the host can get in even if
# something below goes wrong.
systemctl enable --now sshd || fatal "sshd would not start. Check: systemctl status sshd"

# Omarchy ships ufw with "default deny incoming", so a running sshd is still
# unreachable until the port is opened. Scoped to the two subnets this VM is
# ever on, so nothing else can reach it.
if command -v ufw &>/dev/null && ufw status 2>/dev/null | head -1 | grep -q active; then
    for net in "$WORKSTATION_SUBNET" "$SANDBOX_SUBNET"; do
        ufw allow from "$net" to any port 22 proto tcp comment 'omavm ssh' >/dev/null 2>&1 \
            || warn "could not open port 22 in the guest firewall for ${net}"
    done
    note "Opened port 22 in the guest firewall for the host subnets."
fi

note "SSH is up. The host can connect from here on, whatever happens below."

# --------------------------------------------------------------------------
step "Installing the guest agents and the agent control kit"
# spice-vdagent is what makes host clipboard sharing work at all, and
# qemu-guest-agent gives the host clean shutdown and state queries.
optional "installing guest agents" \
    pacman -S --needed --noconfirm qemu-guest-agent spice-vdagent

# An agent driving this desktop reads it with grim and hyprctl and acts on it
# with ydotool and wtype. jq parses the compositor's JSON.
optional "installing the agent control kit" \
    pacman -S --needed --noconfirm grim slurp wl-clipboard wtype ydotool jq

systemctl enable --now qemu-guest-agent 2>/dev/null || warn "could not start qemu-guest-agent"
systemctl enable --now spice-vdagentd 2>/dev/null || warn "could not start spice-vdagentd"

# Clipboard sharing needs two processes, not one. spice-vdagentd is the system
# daemon that talks to the host; spice-vdagent is a per-session client that
# talks to the compositor. Without the second one the clipboard silently does
# nothing, which is the usual reason "I enabled the agent and it still does not
# work". Packaged as an XDG autostart entry, which Hyprland does not read
# directly, so give it a user unit instead.
if command -v spice-vdagent &>/dev/null; then
    install -d -m 0755 /etc/systemd/user
    cat > /etc/systemd/user/spice-vdagent.service <<'VDAGENT'
[Unit]
Description=SPICE per-session agent (clipboard, resolution)
PartOf=graphical-session.target
After=graphical-session.target

[Service]
ExecStart=/usr/bin/spice-vdagent -x
Restart=on-failure
RestartSec=2

[Install]
WantedBy=graphical-session.target
VDAGENT
    systemctl --global enable spice-vdagent.service 2>/dev/null \
        || warn "could not enable the per-session spice-vdagent"
fi

# --------------------------------------------------------------------------
step "Enabling synthetic input for the agent"
# ydotool injects through /dev/uinput, which is independent of SPICE. That is
# what keeps agent input from fighting the host pointer: events originate
# inside the guest rather than arriving from a viewer.
if command -v ydotoold &>/dev/null; then
    echo uinput > /etc/modules-load.d/omavm-uinput.conf
    modprobe uinput 2>/dev/null || true
    cat > /etc/udev/rules.d/60-omavm-uinput.rules <<'UDEV'
KERNEL=="uinput", GROUP="input", MODE="0660", OPTIONS+="static_node=uinput"
UDEV
    usermod -aG input "$GUEST_USER"

    # Run the daemon in the user session so its socket belongs to the agent
    # user. The packaged system unit puts a root-owned socket in /tmp, which
    # the agent then cannot use without sudo on every single call.
    install -d -m 0755 /etc/systemd/user
    cat > /etc/systemd/user/ydotoold.service <<'YDOTOOL'
[Unit]
Description=ydotool daemon (user session)

[Service]
ExecStart=/usr/bin/ydotoold --socket-path=%t/ydotoold.socket --socket-perm=0600
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
YDOTOOL
    systemctl --global enable ydotoold.service 2>/dev/null \
        || warn "could not enable ydotoold; run 'omarchy-ui doctor' in the guest"
else
    warn "ydotool is not installed, so the agent will not be able to click or move the pointer"
fi

# --------------------------------------------------------------------------
step "Installing the omarchy-ui agent skill"
# Delivered either as a file already copied in over SSH, or fetched from the
# temporary HTTP server, depending on how this script was run.
skills_ok=1
if [[ -f /tmp/omavm-skills.tar.gz ]]; then
    tar -xzf /tmp/omavm-skills.tar.gz -C /tmp 2>/dev/null || skills_ok=0
elif [[ -n "$SEAL_URL" ]]; then
    curl -fsSL "${SEAL_URL}/skills.tar.gz" | tar -xz -C /tmp 2>/dev/null || skills_ok=0
else
    skills_ok=0
fi
if (( skills_ok )); then
    install -m 0755 /tmp/omarchy-ui/scripts/omarchy-ui /usr/local/bin/omarchy-ui \
        && install -d -m 0755 -o "$GUEST_USER" -g "$GUEST_USER" \
            "${HOME_DIR}/.claude" "${HOME_DIR}/.claude/skills" "${HOME_DIR}/.claude/skills/omarchy-ui" \
        && install -m 0644 -o "$GUEST_USER" -g "$GUEST_USER" \
            /tmp/omarchy-ui/SKILL.md "${HOME_DIR}/.claude/skills/omarchy-ui/SKILL.md" \
        && note "omarchy-ui installed; the skill is available to agents run as ${GUEST_USER}" \
        || warn "could not install the omarchy-ui skill"
    rm -rf /tmp/omarchy-ui /tmp/omavm-skills.tar.gz
else
    warn "could not unpack the skill bundle"
fi

# --------------------------------------------------------------------------
step "Configuring the host file share"
# nofail matters: the share is optional and absent in the sandbox profile, so
# without it the guest would drop to an emergency shell when it is not there.
install -d -m 0755 "$SHARE_MOUNT"
if ! grep -q "^${SHARE_TAG}[[:space:]]" /etc/fstab; then
    printf '%s %s virtiofs defaults,nofail,x-systemd.device-timeout=5s 0 0\n' \
        "$SHARE_TAG" "$SHARE_MOUNT" >> /etc/fstab
fi

# --------------------------------------------------------------------------
step "Pinning the DHCP client identifier to the interface MAC"
# Without this the client id is derived from other state and dnsmasq may not
# match the reservation, so the guest silently lands on a different address.
install -d -m 0755 /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/10-omavm-dhcp.conf <<'NMCONF'
[connection]
ipv4.dhcp-client-id=mac
NMCONF

# --------------------------------------------------------------------------
step "Writing the guest environment"
# Dots are regex metacharacters; an unescaped prefix would match addresses it
# should not, such as 192x168x101.
SANDBOX_PREFIX_RE="${SANDBOX_PREFIX//./\\.}"
cat > /etc/profile.d/omavm-proxy.sh <<PROFILE
# Managed by omavm seal-guest.sh. Do not edit in the guest; edit the seal
# script on the host and re-seal, otherwise your change is lost at next reset.

# ydotool talks to the daemon in this user's session.
export YDOTOOL_SOCKET="\${XDG_RUNTIME_DIR:-/run/user/\$(id -u)}/ydotoold.socket"

# Sandbox profile only, detected by the guest address. Under the workstation
# profile the guest has ordinary NAT internet and none of this applies.
if ip -4 -brief addr show 2>/dev/null | grep -q " ${SANDBOX_PREFIX_RE}\\."; then
    export http_proxy="http://${SANDBOX_HOST_IP}:${PROXY_PORT}"
    export https_proxy="\$http_proxy"
    export HTTP_PROXY="\$http_proxy"
    export HTTPS_PROXY="\$http_proxy"
    export no_proxy="localhost,127.0.0.1,${SANDBOX_HOST_IP}"
    export NO_PROXY="\$no_proxy"

    # Requests go to the host gateway over plain HTTP and the key is attached
    # there, so it never exists inside this guest.
    export ANTHROPIC_BASE_URL="http://${SANDBOX_HOST_IP}:${GATEWAY_PORT}/anthropic"
fi
PROFILE
chmod 0644 /etc/profile.d/omavm-proxy.sh

# --------------------------------------------------------------------------
step "Ensuring autologin to the Hyprland session"
# Omarchy uses sddm. A GUI agent needs the desktop to come up unattended after
# every reset, with no password prompt in the way.
install -d -m 0755 /etc/sddm.conf.d
cat > /etc/sddm.conf.d/autologin.conf <<AUTOLOGIN
[Autologin]
User=${GUEST_USER}
Session=omarchy.desktop
AUTOLOGIN

hostnamectl set-hostname "$VM_HOSTNAME" 2>/dev/null || echo "$VM_HOSTNAME" > /etc/hostname

# --------------------------------------------------------------------------
step "Removing per-install state"
journalctl --rotate --quiet 2>/dev/null || true
journalctl --vacuum-time=1s --quiet 2>/dev/null || true
rm -rf /var/log/journal/* /var/tmp/* 2>/dev/null || true
pacman -Scc --noconfirm >/dev/null 2>&1 || true
rm -f /root/.bash_history "${HOME_DIR}/.bash_history" 2>/dev/null || true
rm -f /var/lib/systemd/random-seed 2>/dev/null || true
fstrim -av >/dev/null 2>&1 || true

# --------------------------------------------------------------------------
step "Done"
echo
echo "Record this SSH host key fingerprint. It must not change across resets:"
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null || true

date -u +'%Y-%m-%dT%H:%M:%SZ' > /etc/omavm-sealed

if (( ${#WARNINGS[@]} )); then
    echo
    printf '\033[1;33m%d step(s) did not complete:\033[0m\n' "${#WARNINGS[@]}"
    printf '  - %s\n' "${WARNINGS[@]}"
    echo
    echo "SSH still works, so you can fix these from the host:"
    echo "  ./manage-agent-vm.sh ssh"
    echo "  ./manage-agent-vm.sh ssh -- omarchy-ui doctor"
else
    echo
    echo "Sealed cleanly. Account: ${GUEST_USER}"
fi

echo
echo "Reboot the guest before freezing. The clipboard agent and the input"
echo "daemon are session services, so they only start at the next login:"
echo "  ./manage-agent-vm.sh ssh -- sudo reboot"
echo
echo "Then, on the host:  ./manage-agent-vm.sh stop && ./manage-agent-vm.sh freeze"
