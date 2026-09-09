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
HOST_IP="@HOST_IP@"
PROXY_PORT="@PROXY_PORT@"
GATEWAY_PORT="@GATEWAY_PORT@"
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
# Requires the build network. On the sandbox network this step cannot work,
# which is why sealing happens before the guest is moved to the sandbox.
pacman -Sy --needed --noconfirm openssh qemu-guest-agent spice-vdagent

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
step "Pinning the DHCP client identifier to the interface MAC"
# Without this the client id is derived from other state and dnsmasq may not
# match the reservation, so the guest silently lands on a different address.
install -d -m 0755 /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/10-omavm-dhcp.conf <<'NMCONF'
[connection]
ipv4.dhcp-client-id=mac
NMCONF

# --------------------------------------------------------------------------
step "Pointing the guest at the host proxy"
# The proxy variables are set only when the guest is actually on the sandbox
# network. On the build network the guest has real NAT, and exporting a proxy
# address that does not exist there would break pacman during a base refresh.
cat > /etc/profile.d/omavm-proxy.sh <<PROFILE
# Managed by omavm seal-guest.sh. Do not edit in the guest; edit the seal
# script on the host and re-seal, otherwise your change is lost at next reset.
if ip -4 -brief addr show 2>/dev/null | grep -q ' 192\\.168\\.100\\.'; then
    export http_proxy="http://${HOST_IP}:${PROXY_PORT}"
    export https_proxy="http://${HOST_IP}:${PROXY_PORT}"
    export HTTP_PROXY="\$http_proxy"
    export HTTPS_PROXY="\$https_proxy"
    export no_proxy="localhost,127.0.0.1,${HOST_IP}"
    export NO_PROXY="\$no_proxy"

    # LLM clients talk to the host gateway over plain HTTP. The API key is
    # attached on the host, so it is never present inside this guest.
    export ANTHROPIC_BASE_URL="http://${HOST_IP}:${GATEWAY_PORT}/anthropic"
    export ANTHROPIC_API_KEY="not-a-real-key-the-host-gateway-supplies-it"
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
