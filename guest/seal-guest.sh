#!/usr/bin/env bash
#
# Runs INSIDE the Omarchy guest, once, at the end of the interactive install.
# manage-agent-vm.sh renders the placeholders and serves this over the build
# bridge; you fetch and run it with the single command that command prints.
#
# It provisions remote access, points the guest at the host proxy, and removes
# the per-install state that would otherwise make every reset slightly
# different from the last.
#
# Deliberately NOT removed: the SSH host keys. Regenerating them would change
# the guest fingerprint on every reset and train you to click through host key
# warnings, which is exactly the habit that makes a man-in-the-middle warning
# useless. Keeping them means a fingerprint change is a real signal.
#
# Also deliberately NOT removed: /etc/machine-id. A stable machine id keeps the
# DHCP client identifier stable, so the guest always receives the reserved
# address, and makes resets byte-for-byte more repeatable.

set -euo pipefail

GUEST_USER="@GUEST_USER@"
VM_HOSTNAME="@VM_NAME@"
SANDBOX_HOST_IP="@SANDBOX_HOST_IP@"
SANDBOX_PREFIX="@SANDBOX_SUBNET_PREFIX@"
PROXY_PORT="@PROXY_PORT@"
GATEWAY_PORT="@GATEWAY_PORT@"
SHARE_TAG="@SHARE_TAG@"
SHARE_MOUNT="@SHARE_MOUNT@"
PUBKEY="@PUBKEY@"

if [[ $EUID -ne 0 ]]; then
    echo "seal-guest: re-running under sudo" >&2
    exec sudo -E bash "$0" "$@"
fi

if ! id "$GUEST_USER" &>/dev/null; then
    echo "seal-guest: no such user '$GUEST_USER' in this guest." >&2
    echo "Set GUEST_USER in config/omavm.conf to the account you created" >&2
    echo "during the Omarchy install, then run the seal step again." >&2
    exit 1
fi

step() { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }

# --------------------------------------------------------------------------
step "Installing guest support packages"
# Needs working internet, which is why sealing runs under the workstation
# profile even if you intend to use the guest in the sandbox profile later.
#
# The second group is the agent control kit. An agent driving this desktop
# reads it with grim and hyprctl and acts on it with ydotool and wtype, all
# over SSH, so it never needs a viewer attached and never touches your host
# cursor.
pacman -Sy --needed --noconfirm \
    openssh qemu-guest-agent spice-vdagent \
    grim slurp wl-clipboard wtype ydotool jq

# --------------------------------------------------------------------------
step "Configuring SSH for key-only access"
install -d -m 0700 -o "$GUEST_USER" -g "$GUEST_USER" "/home/${GUEST_USER}/.ssh"
printf '%s\n' "$PUBKEY" > "/home/${GUEST_USER}/.ssh/authorized_keys"
chown "${GUEST_USER}:${GUEST_USER}" "/home/${GUEST_USER}/.ssh/authorized_keys"
chmod 0600 "/home/${GUEST_USER}/.ssh/authorized_keys"

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
systemctl enable sshd

# --------------------------------------------------------------------------
step "Enabling guest agent and display agent"
# qemu-guest-agent gives the host clean ACPI shutdown and state queries without
# opening another network path. spice-vdagent lets the guest Hyprland session
# follow the viewer window size.
systemctl enable qemu-guest-agent
systemctl enable spice-vdagentd

# --------------------------------------------------------------------------
step "Enabling synthetic input for the agent"
# ydotool injects through /dev/uinput, which is independent of SPICE. That is
# what keeps agent input from fighting the host pointer: events originate
# inside the guest rather than arriving from the viewer.
echo uinput > /etc/modules-load.d/omavm-uinput.conf
modprobe uinput 2>/dev/null || true
cat > /etc/udev/rules.d/60-omavm-uinput.rules <<'UDEV'
KERNEL=="uinput", GROUP="input", MODE="0660", OPTIONS+="static_node=uinput"
UDEV
usermod -aG input "$GUEST_USER"

# Run the daemon in the user session so its socket belongs to the agent user.
# The packaged system unit puts a root-owned socket in /tmp, which the agent
# then cannot use without sudo on every single call.
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
systemctl --global enable ydotoold.service

# --------------------------------------------------------------------------
step "Configuring the host file share"
# nofail matters: the share is optional and absent in the sandbox profile, so
# without it the guest would drop to an emergency shell whenever it is not
# attached.
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
# The proxy variables apply only in the sandbox profile, detected by the guest
# address. Under the workstation profile the guest has ordinary NAT internet
# and exporting a proxy that is not there would break everything.
# Dots are regex metacharacters; an unescaped prefix would match addresses it
# should not, such as 192x168x101.
SANDBOX_PREFIX_RE="${SANDBOX_PREFIX//./\\.}"
cat > /etc/profile.d/omavm-proxy.sh <<PROFILE
# Managed by omavm seal-guest.sh. Do not edit in the guest; edit the seal
# script on the host and re-seal, otherwise your change is lost at next reset.
# ydotool talks to the daemon in this user's session.
export YDOTOOL_SOCKET="\${XDG_RUNTIME_DIR:-/run/user/\$(id -u)}/ydotoold.socket"

# Sandbox profile only. Under the workstation profile the guest has ordinary
# NAT internet and none of this applies.
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
journalctl --rotate --quiet || true
journalctl --vacuum-time=1s --quiet || true
rm -rf /var/log/journal/* /var/tmp/* /tmp/* 2>/dev/null || true
pacman -Scc --noconfirm >/dev/null 2>&1 || true
rm -f /root/.bash_history "/home/${GUEST_USER}/.bash_history" 2>/dev/null || true
rm -f /var/lib/systemd/random-seed 2>/dev/null || true
# Zero free space so the base image compacts well when it is frozen.
fstrim -av 2>/dev/null || true

# --------------------------------------------------------------------------
step "Recording the SSH host key fingerprint"
echo
echo "Record this fingerprint. It must not change across resets:"
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub

touch /etc/omavm-sealed
date -u +'%Y-%m-%dT%H:%M:%SZ' > /etc/omavm-sealed

echo
echo "Guest sealed. Shut it down now, then run: ./manage-agent-vm.sh freeze"
echo
echo "The agent drives this desktop from the host over SSH, with no viewer"
echo "attached, so it never competes with your own cursor:"
echo "  grim -                          capture the screen to stdout"
echo "  hyprctl -j clients              window geometry as JSON"
echo "  ydotool mousemove -a X Y        absolute pointer move"
echo "  ydotool click 0xC0              left click"
echo "  wtype 'text'                    type text"
