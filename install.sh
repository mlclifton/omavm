#!/usr/bin/env bash
#
# install.sh — put omavm on your PATH, or take everything omavm installed away.
#
#   ./install.sh                     link ~/.local/bin/omavm to this repository
#   ./install.sh --with-host         also provision the host (install_host_deps.sh)
#   ./install.sh --bin-dir DIR       link somewhere other than ~/.local/bin
#
#   ./install.sh remove              remove what omavm installed on this host
#   ./install.sh remove --purge      also destroy every VM, the images and the key
#   ./install.sh remove --dry-run    show what would be removed, change nothing
#
# Removal is deliberately not `omavm remove`. `omavm rm <vm>` already deletes a
# single VM, and a command that deletes everything should not sit one letter
# away from it in the same tool.
#
# What remove leaves alone, and why:
#   packages        libvirt and QEMU may be used by other things on this host
#   libvirt group   virt-manager and other VMs rely on it
#   share folders   they hold your files, not omavm's
#   this repository you cloned it; delete it yourself if you want it gone

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=config/omavm.conf
source "${REPO_DIR}/config/omavm.conf"

STATE_DIR="${XDG_STATE_HOME:-${HOME}/.local/state}/omavm"
STATE_FILE="${STATE_DIR}/install.conf"
TOOL="${REPO_DIR}/manage-agent-vm.sh"
VIRSH="virsh --connect qemu:///system"

DRY_RUN=0
ASSUME_YES=0

c_reset=$'\033[0m'; c_blue=$'\033[1;34m'; c_green=$'\033[1;32m'
c_yellow=$'\033[1;33m'; c_red=$'\033[1;31m'; c_bold=$'\033[1m'
stage() { printf '\n%s==> %s%s\n' "$c_blue" "$1" "$c_reset"; }
ok()    { printf '  %s✔%s %s\n' "$c_green" "$c_reset" "$1"; }
warn()  { printf '  %s!%s %s\n' "$c_yellow" "$c_reset" "$1"; }
die()   { printf '  %s✘%s %s\n' "$c_red" "$c_reset" "$1" >&2; exit 1; }
info()  { printf '    %s\n' "$1"; }

run() {
    if (( DRY_RUN )); then
        printf '  %s[dry-run]%s %s\n' "$c_bold" "$c_reset" "$*"
        return 0
    fi
    "$@"
}

# Like run, but silences the command's own output when it really runs. Putting
# the redirection at the call site instead would also swallow the dry-run line,
# so a dry run would quietly under-report what remove is about to do.
run_quiet() {
    if (( DRY_RUN )); then
        printf '  %s[dry-run]%s %s\n' "$c_bold" "$c_reset" "$*"
        return 0
    fi
    "$@" &>/dev/null
}

confirm() {
    (( ASSUME_YES || DRY_RUN )) && return 0
    local reply
    read -r -p "  $1 [y/N] " reply
    [[ "$reply" =~ ^[Yy] ]]
}

usage() { awk 'NR>=3 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; }

# --------------------------------------------------------------------------
# install
# --------------------------------------------------------------------------
do_install() {
    local bin_dir="${OMAVM_BIN_DIR:-${HOME}/.local/bin}" with_host=0 force=0
    while (( $# )); do
        case "$1" in
            --bin-dir)   bin_dir="$2"; shift ;;
            --with-host) with_host=1 ;;
            --force)     force=1 ;;
            --dry-run)   DRY_RUN=1 ;;
            --yes|-y)    ASSUME_YES=1 ;;
            -h|--help)   usage; exit 0 ;;
            *) die "Unknown option for install: $1" ;;
        esac
        shift
    done
    bin_dir="$(realpath -m "$bin_dir")"
    local link="${bin_dir}/omavm"

    stage "Installing omavm"
    [[ -x "$TOOL" ]] || die "Cannot find an executable $TOOL"

    if [[ -L "$link" && "$(readlink -f "$link")" == "$(readlink -f "$TOOL")" ]]; then
        ok "$link already points at this repository"
    elif [[ -e "$link" || -L "$link" ]] && (( ! force )); then
        local what
        if [[ -L "$link" ]]; then
            what="a link to $(readlink "$link")"
        else
            what="a $(file -b "$link" 2>/dev/null || echo 'file')"
        fi
        die "$link already exists and is not this repository's omavm.
    It is ${what}.
    Refusing to replace something that is not ours. Use --force to replace it."
    else
        run mkdir -p "$bin_dir"
        run ln -sfn "$TOOL" "$link"
        (( DRY_RUN )) || ok "Linked $link -> $TOOL"
    fi

    # Remember where it went, so remove takes away exactly this and nothing
    # else, even when --bin-dir was used.
    run mkdir -p "$STATE_DIR"
    if (( ! DRY_RUN )); then
        printf 'BIN_DIR=%q\nREPO_DIR=%q\n' "$bin_dir" "$REPO_DIR" > "$STATE_FILE"
    fi

    case ":${PATH}:" in
        *":${bin_dir}:"*) ok "$bin_dir is on your PATH" ;;
        *) warn "$bin_dir is not on your PATH, so 'omavm' will not be found yet."
           info "Add it to your shell profile:  export PATH=\"${bin_dir}:\$PATH\"" ;;
    esac

    if (( with_host )); then
        stage "Provisioning the host"
        local args=()
        (( DRY_RUN )) && args+=(--dry-run)
        (( ASSUME_YES )) && args+=(--yes)
        "${REPO_DIR}/install_host_deps.sh" "${args[@]}"
    elif ! $VIRSH net-info "$WORKSTATION_NET" &>/dev/null; then
        echo
        info "The host is not provisioned yet. Run this next, or re-run with --with-host:"
        info "  ${REPO_DIR}/install_host_deps.sh"
    fi

    echo
    info "Try it:  omavm list"
}

# --------------------------------------------------------------------------
# remove
# --------------------------------------------------------------------------

# Every VM registered on either network, as "network name".
registered_vms() {
    local net
    for net in "$WORKSTATION_NET" "$SANDBOX_NET"; do
        $VIRSH net-dumpxml "$net" 2>/dev/null \
            | grep -oP "<host mac='[^']+' name='\K[^']+" \
            | sed "s/^/${net} /" || true
    done
}

do_remove() {
    local purge=0
    while (( $# )); do
        case "$1" in
            --purge)   purge=1 ;;
            --dry-run) DRY_RUN=1 ;;
            --yes|-y)  ASSUME_YES=1 ;;
            -h|--help) usage; exit 0 ;;
            *) die "Unknown option for remove: $1" ;;
        esac
        shift
    done

    local bin_dir="${HOME}/.local/bin"
    if [[ -f "$STATE_FILE" ]]; then
        # shellcheck source=/dev/null
        bin_dir="$(source "$STATE_FILE" && echo "$BIN_DIR")"
    fi

    local vms
    vms=$(registered_vms)

    stage "Removing omavm from this host"
    (( DRY_RUN )) && info "Dry run. Nothing will be changed and nothing will ask for a password."

    # Networks cannot go while VMs still sit on them, and quietly deleting
    # someone's VMs is not something to do without being asked twice.
    if [[ -n "$vms" ]] && (( ! purge )); then
        warn "These VMs still exist:"
        printf '%s\n' "$vms" | awk '{print "      " $2 "   on " $1}'
        local tool="${REPO_DIR}/manage-agent-vm.sh"
        command -v omavm &>/dev/null && tool="omavm"
        die "Removing omavm would break them. Either delete them first with
        ${tool} rm <name>
    or remove everything, VMs, images and the SSH key included, with
        $0 remove --purge"
    fi

    echo
    info "This removes, from this host:"
    info "  the omavm command in ${bin_dir}"
    info "  the egress proxy service, its user, its config and its logs"
    info "  the ufw rules tagged omavm"
    info "  the libvirt networks ${WORKSTATION_NET} and ${SANDBOX_NET}"
    if (( purge )); then
        info "  ${c_red}every VM, the base image, staged ISOs and ${IMAGE_DIR}${c_reset}"
        info "  ${c_red}the SSH key ${SSH_KEY} and its known_hosts file${c_reset}"
    fi
    info "It leaves packages, your libvirt group membership, share folders under"
    info "${SHARE_ROOT:-the share root} and this repository."
    if [[ -f /etc/omavm/credentials.env ]] || (( DRY_RUN )); then
        warn "/etc/omavm/credentials.env may hold API keys. It will be deleted."
    fi
    echo
    confirm "Remove omavm$( (( purge )) && echo ', and destroy all VMs and images')?" \
        || die "Aborted. Nothing was changed."

    (( purge )) && purge_vms "$vms"
    remove_proxy
    remove_firewall_rules
    remove_networks
    remove_link "$bin_dir"
    run rm -rf "$STATE_DIR"

    stage "Done"
    (( DRY_RUN )) && { info "Dry run only. Nothing was changed."; return; }
    ok "omavm is removed from this host"
    [[ -n "$SHARE_ROOT" && -d "$SHARE_ROOT" ]] && info "Your share folders are still in ${SHARE_ROOT}."
    info "To remove the packages as well:  sudo pacman -Rns libvirt qemu-desktop virt-manager virt-viewer"
    info "Only do that if nothing else on this host uses them."
}

purge_vms() {
    stage "Destroying VMs and images"
    local net name
    while read -r net name; do
        [[ -n "$name" ]] || continue
        local domain="omarchy-${name}"
        run_quiet $VIRSH destroy "$domain" || true
        run_quiet $VIRSH undefine --nvram "$domain" || true
        (( DRY_RUN )) || ok "Removed VM ${name}"
    done <<<"$1"
    run sudo rm -rf "$IMAGE_DIR"
    run sudo rm -f "${NVRAM_DIR}"/omarchy-*_VARS.fd
    run rm -f "$SSH_KEY" "${SSH_KEY}.pub" "${HOME}/.ssh/known_hosts_omavm" "${HOME}/.ssh/known_hosts_omavm.old"
    (( DRY_RUN )) || ok "Images, UEFI variables and the SSH key removed"
}

remove_proxy() {
    stage "Removing the egress proxy"
    run_quiet sudo systemctl disable --now omavm-agent-proxy || true
    run sudo rm -f /etc/systemd/system/omavm-agent-proxy.service
    run sudo systemctl daemon-reload
    run sudo rm -rf /usr/local/lib/omavm /etc/omavm /var/log/omavm
    if (( DRY_RUN )) || id omavm-proxy &>/dev/null; then
        run sudo userdel omavm-proxy
    fi
    (( DRY_RUN )) || ok "Proxy service, config, logs and user removed"
}

# Delete by rule number, highest first, so earlier numbers stay valid as rules
# disappear. Matching on the comment means only rules omavm created are touched.
remove_firewall_rules() {
    stage "Removing firewall rules"
    command -v ufw &>/dev/null || { info "ufw is not installed"; return; }
    if (( DRY_RUN )); then
        info "[dry-run] would delete every ufw rule whose comment starts with 'omavm'"
        return
    fi
    local nums n count=0
    nums=$(sudo ufw status numbered 2>/dev/null \
        | grep -E "# omavm" | grep -oE '^\[ *[0-9]+\]' | tr -dc '0-9\n' | sort -rn)
    for n in $nums; do
        sudo ufw --force delete "$n" >/dev/null && count=$((count + 1))
    done
    ok "Deleted ${count} ufw rule(s)"
}

remove_networks() {
    stage "Removing libvirt networks"
    local net
    for net in "$WORKSTATION_NET" "$SANDBOX_NET" agent-build-net; do
        $VIRSH net-info "$net" &>/dev/null || continue
        run_quiet $VIRSH net-destroy "$net" || true
        run_quiet $VIRSH net-undefine "$net"
        (( DRY_RUN )) || ok "Removed network ${net}"
    done
}

# Only remove the link if it is ours. Something else called omavm in the same
# directory is not ours to delete.
remove_link() {
    local link="$1/omavm"
    stage "Removing the omavm command"
    if [[ -L "$link" && "$(readlink -f "$link")" == "$(readlink -f "$TOOL")" ]]; then
        run rm -f "$link"
        (( DRY_RUN )) || ok "Removed $link"
    elif [[ -e "$link" ]]; then
        warn "$link exists but does not point at this repository. Left alone."
    else
        info "No omavm command in $1"
    fi
}

# --------------------------------------------------------------------------
case "${1:-}" in
    remove)           shift; do_remove "$@" ;;
    -h|--help|help)   usage ;;
    *)                do_install "$@" ;;
esac
