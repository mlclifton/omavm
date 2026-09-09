#!/usr/bin/env bash
#
# install_host_deps.sh — provision an Omarchy/Arch host to run the omavm agent VM.
#
# Idempotent. Run it as your normal user; it calls sudo only for the steps that
# need it. Every step reports what it is about to do, and --dry-run shows the
# whole plan without changing anything.
#
#   ./install_host_deps.sh --dry-run     # show what would happen
#   ./install_host_deps.sh               # apply, prompting before each stage
#   ./install_host_deps.sh --yes         # apply without prompting

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config/omavm.conf
source "${REPO_DIR}/config/omavm.conf"

DRY_RUN=0
ASSUME_YES=0
FAILURES=0

# Bridges this toolkit created in earlier versions. They are recognised so a
# leftover network reads as stale state to clean up rather than as a collision
# with something else on the machine.
RETIRED_BRIDGES=(virbr-build)

PACKAGES=(
    libvirt          # the management layer everything else is defined against
    qemu-desktop     # x86_64 system emulation plus the desktop UI and display bits
    virt-manager     # GUI, useful for the one interactive install
    virt-viewer      # what actually attaches to the SPICE socket
    dnsmasq          # libvirt uses it for DHCP on both networks
    swtpm            # not required by Omarchy, but cheap to have available
    edk2-ovmf        # UEFI firmware
    openbsd-netcat   # used by verify-isolation.sh inside the guest checks
    dmidecode
)

# --------------------------------------------------------------------------
# output helpers
# --------------------------------------------------------------------------
c_reset=$'\033[0m'; c_bold=$'\033[1m'; c_blue=$'\033[1;34m'
c_green=$'\033[1;32m'; c_yellow=$'\033[1;33m'; c_red=$'\033[1;31m'

stage()  { printf '\n%s==> %s%s\n' "$c_blue" "$1" "$c_reset"; }
ok()     { printf '  %s✔%s %s\n' "$c_green" "$c_reset" "$1"; }
warn()   { printf '  %s!%s %s\n' "$c_yellow" "$c_reset" "$1"; }
fail()   { printf '  %s✘%s %s\n' "$c_red" "$c_reset" "$1"; FAILURES=$((FAILURES + 1)); }
# Confirmation of an action that actually happened. Silent during a dry run,
# where claiming success for work that was not done would be misleading.
did()    { (( DRY_RUN )) || ok "$1"; }
info()   { printf '    %s\n' "$1"; }

run() {
    if (( DRY_RUN )); then
        printf '  %s[dry-run]%s %s\n' "$c_bold" "$c_reset" "$*"
        return 0
    fi
    "$@"
}

confirm() {
    (( ASSUME_YES || DRY_RUN )) && return 0
    local reply
    read -r -p "  Proceed? [Y/n] " reply
    [[ -z "$reply" || "$reply" =~ ^[Yy] ]]
}

# --------------------------------------------------------------------------
# preflight
# --------------------------------------------------------------------------
preflight() {
    stage "Preflight checks"

    if [[ $EUID -eq 0 ]]; then
        fail "Run this as your normal user, not as root. It needs \$USER to set group membership."
        exit 1
    fi

    if [[ ! -r /etc/os-release ]] || ! grep -qE '^(ID|ID_LIKE)=.*arch' /etc/os-release; then
        fail "This host does not look like Arch or an Arch derivative."
        exit 1
    fi
    ok "Arch-family host: $(. /etc/os-release && echo "${PRETTY_NAME:-$NAME} ${VERSION_ID:-}")"

    if grep -qE '^flags.*\b(vmx|svm)\b' /proc/cpuinfo; then
        ok "CPU virtualisation extensions present"
    else
        fail "No vmx/svm in /proc/cpuinfo. Enable virtualisation in firmware and retry."
    fi

    if [[ -c /dev/kvm ]]; then
        ok "/dev/kvm present ($(stat -c '%A %G' /dev/kvm))"
    else
        fail "/dev/kvm missing. Is the kvm_intel or kvm_amd module loaded?"
    fi

    if [[ -c "$RENDER_NODE" ]]; then
        ok "Render node $RENDER_NODE present ($(stat -c '%A %G' "$RENDER_NODE"))"
        if [[ ! -r "$RENDER_NODE" ]]; then
            warn "Cannot read $RENDER_NODE as $USER. virgl needs the qemu process to open it."
            info "Check that you are in the 'render' group, or that the node is mode 0666."
        fi
    else
        fail "Render node $RENDER_NODE not found. Set RENDER_NODE in config/omavm.conf."
        info "Available: $(ls /dev/dri/renderD* 2>/dev/null | tr '\n' ' ')"
    fi

    local avail_gb
    avail_gb=$(df --output=avail -BG /var/lib 2>/dev/null | tail -1 | tr -dc '0-9')
    if (( avail_gb >= 120 )); then
        ok "Free space under /var/lib: ${avail_gb}G"
    else
        warn "Only ${avail_gb}G free under /var/lib. A base image plus an overlay wants roughly 120G."
    fi

    check_subnet_free "$WORKSTATION_SUBNET" "workstation"
    check_subnet_free "$SANDBOX_SUBNET" "sandbox"

    if systemctl is-active --quiet incus 2>/dev/null; then
        warn "incus is running and manages its own bridges and nftables tables."
        info "The two coexist, but re-run ./verify-isolation.sh after any incus upgrade."
    fi
}

check_subnet_free() {
    local subnet="$1" label="$2" prefix owner
    prefix="${subnet%.0/24}"
    # Field 3 of an "ip route" line is the interface. A route on one of our own
    # bridges is this toolkit's own network, not a collision with something else.
    owner=$(ip -4 route show | awk -v p="^${prefix}[.]" '$1 ~ p {print $3; exit}')
    if [[ -z "$owner" ]]; then
        ok "${label} subnet ${subnet} is free"
    elif [[ "$owner" == "$WORKSTATION_BRIDGE" || "$owner" == "$SANDBOX_BRIDGE" ]]; then
        ok "${label} subnet ${subnet} is in use by our own bridge ${owner}"
    elif [[ " ${RETIRED_BRIDGES[*]} " == *" ${owner} "* ]]; then
        warn "${label} subnet ${subnet} is held by ${owner}, from an earlier version"
        info "The networks step below will offer to remove it."
    else
        fail "The ${label} subnet ${subnet} collides with a route on ${owner}:"
        ip -4 route show | grep "^${prefix}\." | sed 's/^/      /'
        info "Change the addresses in config/omavm.conf and the libvirt/*.xml files."
    fi
}

# --------------------------------------------------------------------------
# packages
# --------------------------------------------------------------------------
install_packages() {
    stage "Installing host packages"

    # The brief asked for qemu-full and iptables-nft. Neither is right on a
    # current Arch host, and saying so here is cheaper than debugging it later.
    info "Note: installing qemu-desktop rather than qemu-full. qemu-full adds every"
    info "foreign-architecture emulator, none of which this VM uses."
    if pacman -Qq iptables &>/dev/null && iptables -V 2>/dev/null | grep -q nf_tables; then
        info "Note: not installing iptables-nft. The installed iptables package is"
        info "already the nftables-backed build, and swapping it would pull out a"
        info "dependency of the running ufw."
    fi

    local missing=()
    local pkg
    for pkg in "${PACKAGES[@]}"; do
        pacman -Qq "$pkg" &>/dev/null || missing+=("$pkg")
    done

    if (( ${#missing[@]} == 0 )); then
        ok "All required packages already installed"
        return
    fi

    info "To install: ${missing[*]}"
    confirm || { warn "Skipped package installation"; return; }
    run sudo pacman -S --needed --noconfirm "${missing[@]}"
    did "Packages installed"
}

# --------------------------------------------------------------------------
# services and groups
# --------------------------------------------------------------------------
enable_services() {
    stage "Enabling libvirt"

    # Modern libvirt is socket activated. Enabling the socket rather than the
    # daemon means libvirtd starts on first use and does not sit resident.
    if systemctl is-enabled --quiet libvirtd.socket 2>/dev/null; then
        ok "libvirtd.socket already enabled"
    else
        confirm && run sudo systemctl enable --now libvirtd.socket || true
    fi
    run sudo systemctl start libvirtd.socket 2>/dev/null || true

    if systemctl is-active --quiet virtlogd.socket 2>/dev/null; then
        ok "virtlogd.socket active"
    else
        run sudo systemctl enable --now virtlogd.socket 2>/dev/null || true
    fi
}

configure_groups() {
    stage "Group membership"

    # The kvm group is included for completeness. On current Arch /dev/kvm is
    # mode 0666, so membership changes nothing; libvirt is the group that
    # actually grants passwordless access to qemu:///system.
    local group added=0
    for group in libvirt kvm; do
        if id -nG "$USER" | tr ' ' '\n' | grep -qx "$group"; then
            ok "$USER already in group '$group'"
        else
            confirm && { run sudo usermod -aG "$group" "$USER"; added=1; } || true
        fi
    done

    if (( added )) && ! (( DRY_RUN )); then
        warn "Group membership does not apply to your current Hyprland session."
        info "Log out and back in, or the virsh commands below will ask for a password."
        info "To test without logging out, run a single command as: newgrp libvirt"
    fi
}

# --------------------------------------------------------------------------
# ssh key
# --------------------------------------------------------------------------
create_ssh_key() {
    stage "Isolated SSH keypair"

    if [[ -f "$SSH_KEY" ]]; then
        ok "Key already present: $SSH_KEY"
        return
    fi
    info "Creating a dedicated key used only for this VM: $SSH_KEY"
    info "It is separate from your personal keys so the guest never sees them."
    confirm || { warn "Skipped key creation"; return; }
    run ssh-keygen -t ed25519 -N '' -C "omavm-agent" -f "$SSH_KEY"
    did "Keypair created"
}

# --------------------------------------------------------------------------
# storage
# --------------------------------------------------------------------------
create_storage() {
    stage "Image storage"
    if [[ -d "$IMAGE_DIR" ]]; then
        ok "$IMAGE_DIR exists"
    else
        run sudo install -d -m 0711 -o root -g root "$IMAGE_DIR"
        did "Created $IMAGE_DIR"
    fi
    run sudo install -d -m 0755 /var/lib/libvirt/qemu/nvram
}

# --------------------------------------------------------------------------
# proxy
# --------------------------------------------------------------------------
install_proxy() {
    stage "Installing the egress proxy"

    if ! id omavm-proxy &>/dev/null; then
        info "Creating the system user 'omavm-proxy'."
        info "The proxy holds API keys, so it does not run as root."
        confirm && run sudo useradd --system --no-create-home \
            --shell /usr/bin/nologin --comment "omavm agent proxy" omavm-proxy || true
    else
        ok "System user 'omavm-proxy' exists"
    fi

    run sudo install -d -m 0755 /usr/local/lib/omavm
    run sudo install -m 0755 "${REPO_DIR}/proxy/agent-proxy.py" /usr/local/lib/omavm/agent-proxy.py
    run sudo install -d -m 0750 -o root -g omavm-proxy /etc/omavm
    run sudo install -d -m 0750 -o omavm-proxy -g omavm-proxy /var/log/omavm

    # Configuration files are installed only if absent, so re-running this
    # script never discards an allowlist you have curated.
    local src dst
    for src in allowlist.conf routes.conf; do
        dst="/etc/omavm/${src}"
        if [[ -f "$dst" ]]; then
            ok "Keeping existing $dst"
        else
            run sudo install -m 0640 -o root -g omavm-proxy "${REPO_DIR}/proxy/${src}" "$dst"
            did "Installed $dst"
        fi
    done

    if [[ -f /etc/omavm/credentials.env ]]; then
        ok "Keeping existing /etc/omavm/credentials.env"
    else
        run sudo install -m 0640 -o root -g omavm-proxy \
            "${REPO_DIR}/proxy/credentials.env.example" /etc/omavm/credentials.env
        warn "Put your API key in /etc/omavm/credentials.env before using a gateway route."
    fi

    # The unit binds to the sandbox bridge address, which comes from the config
    # file, so the shipped unit is a template rather than a fixed file.
    if (( DRY_RUN )); then
        info "[dry-run] would install omavm-agent-proxy.service bound to ${SANDBOX_HOST_IP}"
    else
        sed "s|192\\.168\\.100\\.1|${SANDBOX_HOST_IP}|g" \
            "${REPO_DIR}/proxy/omavm-agent-proxy.service" \
            | sudo tee /etc/systemd/system/omavm-agent-proxy.service >/dev/null
    fi
    run sudo systemctl daemon-reload
    did "Service unit installed. It is started by manage-agent-vm.sh once the bridge is up."
}

# --------------------------------------------------------------------------
# networks
# --------------------------------------------------------------------------
define_networks() {
    stage "Defining libvirt networks"

    # Both are defined so switching profile is a config change rather than a
    # provisioning step. Only the one the active profile names is autostarted.
    local ws_mode="no-autostart" sb_mode="no-autostart"
    if [[ "$PROFILE" == "sandbox" ]]; then sb_mode="autostart"; else ws_mode="autostart"; fi
    define_one_network "$WORKSTATION_NET" "${REPO_DIR}/libvirt/agent-net.xml" "$ws_mode"
    define_one_network "$SANDBOX_NET" "${REPO_DIR}/libvirt/agent-sandbox-net.xml" "$sb_mode"
    retire_network "agent-build-net"

    if (( DRY_RUN )); then return; fi
    if sudo virsh net-info "$SANDBOX_NET" &>/dev/null; then
        if sudo virsh net-dumpxml "$SANDBOX_NET" | grep -q '<forward'; then
            fail "$SANDBOX_NET has a <forward> element. It is NOT isolated. Redefine it."
        else
            ok "$SANDBOX_NET has no <forward> element, so it is isolated"
        fi
    fi
}

define_one_network() {
    local name="$1" xml="$2" mode="$3"
    if (( DRY_RUN )); then
        run sudo virsh net-define "$xml"
        return
    fi
    if sudo virsh net-info "$name" &>/dev/null; then
        # A network defined from an older version of this repository keeps its
        # old bridge and address until something replaces it, which then looks
        # like an address collision rather than stale state.
        local want_bridge have_bridge want_ip have_ip
        want_bridge=$(grep -oP "(?<=<bridge name=')[^']+" "$xml" | head -1)
        want_ip=$(grep -oP "(?<=<ip address=')[^']+" "$xml" | head -1)
        have_bridge=$(sudo virsh net-dumpxml "$name" | grep -oP "(?<=<bridge name=')[^']+" | head -1)
        have_ip=$(sudo virsh net-dumpxml "$name" | grep -oP "(?<=<ip address=')[^']+" | head -1)
        if [[ "$want_bridge" == "$have_bridge" && "$want_ip" == "$have_ip" ]]; then
            ok "Network '$name' already defined"
        else
            warn "Network '$name' does not match this repository:"
            info "  defined here: bridge ${have_bridge}, address ${have_ip}"
            info "  wanted:       bridge ${want_bridge}, address ${want_ip}"
            info "Replacing it stops the network, which disconnects a running guest."
            if confirm; then
                sudo virsh net-destroy "$name" &>/dev/null || true
                sudo virsh net-undefine "$name" >/dev/null
                sudo virsh net-define "$xml" >/dev/null
                did "Redefined '$name'"
            else
                warn "Left '$name' as it is. Networking will not match the config."
                return
            fi
        fi
    else
        run sudo virsh net-define "$xml"
        did "Defined '$name'"
    fi
    if [[ "$mode" == autostart ]]; then
        run sudo virsh net-autostart "$name" >/dev/null
        run sudo virsh net-start "$name" &>/dev/null || true
    else
        # The build network is a deliberate hole in the sandbox. It stays off
        # until a build or a base refresh explicitly starts it.
        run sudo virsh net-autostart --disable "$name" >/dev/null 2>&1 || true
    fi
}

# Networks this toolkit used to create and no longer does. Left behind they
# hold a bridge name and a subnet that the current networks may want.
retire_network() {
    local name="$1"
    (( DRY_RUN )) && return
    sudo virsh net-info "$name" &>/dev/null || return
    warn "'$name' is left over from an earlier version of this toolkit."
    info "It is no longer used and holds an address range the current networks need."
    confirm || { warn "Left '$name' defined"; return; }
    sudo virsh net-destroy "$name" &>/dev/null || true
    sudo virsh net-undefine "$name" >/dev/null
    did "Removed '$name'"
}

# --------------------------------------------------------------------------
# firewall
# --------------------------------------------------------------------------
configure_firewall() {
    stage "Host firewall"

    if ! command -v ufw &>/dev/null; then
        warn "ufw is not installed. Skipping firewall rules."
        return
    fi
    if (( DRY_RUN )); then
        info "[dry-run] would allow DHCP and ports ${PROXY_PORT}/${GATEWAY_PORT} on ${SANDBOX_BRIDGE}"
        return
    fi
    if ! sudo ufw status 2>/dev/null | head -1 | grep -q 'Status: active'; then
        warn "ufw is installed but inactive. The sandbox network is still isolated by"
        info "libvirt, but nothing restricts which host services the guest may reach."
        return
    fi
    ok "ufw is active"

    local fwd
    fwd=$(grep -E '^DEFAULT_FORWARD_POLICY' /etc/default/ufw 2>/dev/null | cut -d'"' -f2)
    if [[ "$fwd" == "DROP" ]]; then
        ok "ufw default forward policy is DROP"
    else
        warn "ufw DEFAULT_FORWARD_POLICY is '${fwd:-unset}', not DROP."
        info "This script will not change it, because doing so affects your whole host."
        info "Isolation still holds, but DROP is the safer default. See OPERATIONS.md."
    fi

    confirm || { warn "Skipped firewall rules"; return; }

    # DHCP DISCOVER is broadcast to 255.255.255.255, so a rule scoped to the
    # bridge address never matches it and the guest silently gets no lease.
    # Scoping by interface is what keeps the rule narrow without breaking it.
    local br
    for br in "$WORKSTATION_BRIDGE" "$SANDBOX_BRIDGE"; do
        run sudo ufw delete allow in on "$br" to any port 67 proto udp >/dev/null 2>&1 || true
        run sudo ufw allow in on "$br" to any port 67 proto udp comment 'omavm dhcp'
    done
    did "DHCP allowed on both bridges"

    if [[ "$PROFILE" == "workstation" ]]; then
        # NAT needs forwarding off the bridge, which ufw's default DROP blocks.
        # Scoped to this bridge and this uplink, so nothing else is opened up.
        local wan
        wan=$(ip -4 route show default | awk '{print $5; exit}')
        run sudo ufw route allow in on "$WORKSTATION_BRIDGE" out on "$wan" comment 'omavm nat'
        run sudo ufw allow in on "$WORKSTATION_BRIDGE" to "$WORKSTATION_HOST_IP" port 53 comment 'omavm dns'
        did "Workstation bridge allowed to reach the internet via ${wan}"
    else
        # The sandbox reaches exactly two host ports and nothing else.
        run sudo ufw allow in on "$SANDBOX_BRIDGE" to "$SANDBOX_HOST_IP" port "$PROXY_PORT" proto tcp comment 'omavm proxy'
        run sudo ufw allow in on "$SANDBOX_BRIDGE" to "$SANDBOX_HOST_IP" port "$GATEWAY_PORT" proto tcp comment 'omavm gateway'
        did "Sandbox bridge rules applied"
    fi
}

# --------------------------------------------------------------------------
summary() {
    stage "Summary"
    if (( DRY_RUN )); then
        info "Dry run only. Nothing was changed."
        return
    fi
    if (( FAILURES )); then
        fail "$FAILURES check(s) failed. Resolve them before building the VM."
        exit 1
    fi
    ok "Host is provisioned."
    echo
    info "Profile: ${PROFILE}"
    info "Next steps:"
    info "  1. Log out and back in if your groups changed."
    info "  2. Download the Omarchy ISO and set OMARCHY_ISO in config/omavm.conf."
    info "  3. ./manage-agent-vm.sh build --iso /path/to/omarchy.iso"
    info "  4. Follow README.md from 'Installing the guest'."
}

# --------------------------------------------------------------------------
main() {
    while (( $# )); do
        case "$1" in
            --dry-run) DRY_RUN=1 ;;
            --yes|-y)  ASSUME_YES=1 ;;
            -h|--help) awk 'NR>=3 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; exit 0 ;;
            *) echo "Unknown option: $1" >&2; exit 2 ;;
        esac
        shift
    done

    preflight
    install_packages
    enable_services
    configure_groups
    create_ssh_key
    create_storage
    install_proxy
    define_networks
    configure_firewall
    summary
}

main "$@"
