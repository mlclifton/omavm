#!/usr/bin/env bash
#
# manage-agent-vm.sh — lifecycle for the Omarchy agent VM.
#
#   init      Create the writable build disk.
#   build     Boot the installer with a display attached.
#   rebuild   Throw away a part-finished install and start it over.
#   seal      Provision the installed guest for automation. Guest must be running.
#   freeze    Turn the sealed build disk into the read-only base image.
#   reset     Discard all guest state and return to the base. The common one.
#   start     Boot the VM. --gui to attach a display.
#   stop      Shut down. --force to pull the plug.
#   gui       Attach a display to a running VM. Steals the pointer when focused.
#   watch     Stream screenshots from the guest without touching its cursor.
#   screenshot  Save one frame from the guest to a file.
#   ssh       Run a command in the guest, or open a shell.
#   refresh   Boot a writable copy of the base so you can update it.
#   status    Show the profile, the domain, the share and image sizes.
#   logs      Follow the proxy audit log (sandbox profile only).
#
# The domain XML is rendered from libvirt/omarchy-agent.xml.in and redefined on
# every boot, so this repository is the source of truth. Changes made through
# virt-manager are discarded rather than quietly persisting.
#
# PROFILE in config/omavm.conf decides the network, the clipboard and whether
# file sharing is possible. Override it for one command with, for example:
#   OMAVM_PROFILE=sandbox ./manage-agent-vm.sh start

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config/omavm.conf
source "${REPO_DIR}/config/omavm.conf"

TEMPLATE="${REPO_DIR}/libvirt/omarchy-agent.xml.in"
SEAL_SRC="${REPO_DIR}/guest/seal-guest.sh"
VIRSH="virsh --connect qemu:///system"
SEAL_HTTP_PORT=8765

c_reset=$'\033[0m'; c_blue=$'\033[1;34m'; c_green=$'\033[1;32m'
c_yellow=$'\033[1;33m'; c_red=$'\033[1;31m'; c_bold=$'\033[1m'

stage() { printf '\n%s==> %s%s\n' "$c_blue" "$1" "$c_reset"; }
ok()    { printf '  %s✔%s %s\n' "$c_green" "$c_reset" "$1"; }
warn()  { printf '  %s!%s %s\n' "$c_yellow" "$c_reset" "$1"; }
die()   { printf '  %s✘%s %s\n' "$c_red" "$c_reset" "$1" >&2; exit 1; }
info()  { printf '    %s\n' "$1"; }

# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------
require_libvirt_access() {
    $VIRSH version &>/dev/null && return 0
    die "Cannot reach qemu:///system as $USER.
    If you have just run install_host_deps.sh, log out and back in so the
    'libvirt' group applies to your session, or test with: newgrp libvirt"
}

domain_exists()  { $VIRSH dominfo "$VM_NAME" &>/dev/null; }
domain_running() { [[ "$($VIRSH domstate "$VM_NAME" 2>/dev/null)" == "running" ]]; }

current_network() {
    domain_exists || { echo "undefined"; return; }
    $VIRSH dumpxml "$VM_NAME" 2>/dev/null \
        | grep -oP "(?<=<source network=')[^']+" | head -1
}

wan_interface() {
    ip -4 route show default | awk '{print $5; exit}'
}

# QEMU does not run as you. libvirt starts it as an unprivileged system user,
# which cannot traverse a 0700 home directory, so an ISO under ~/Downloads is
# unreadable no matter what mode the file itself has. libvirt also applies
# dynamic ownership to whatever it is pointed at, so naming a file in your home
# directory leaves that file chowned away from you afterwards.
#
# Staging a copy into the image directory avoids both problems. The copy is
# reflinked where the filesystem supports it, so on btrfs or xfs it is instant
# and costs no extra space.
STAGED_ISO=""
stage_iso() {
    local src="$1" staged
    [[ -f "$src" ]] || die "ISO not found: $src"
    staged="${IMAGE_DIR}/$(basename "$src")"

    if [[ "$src" -ef "$staged" ]]; then
        STAGED_ISO="$staged"
        return 0
    fi

    local src_size staged_size
    src_size=$(stat -c %s "$src")
    staged_size=$(sudo stat -c %s "$staged" 2>/dev/null || echo 0)

    if [[ "$src_size" == "$staged_size" ]]; then
        ok "Installer media already staged at $staged"
    else
        info "Staging the ISO where qemu can read it. $(numfmt --to=iec "$src_size")."
        sudo cp --reflink=auto "$src" "${staged}.part"
        sudo mv "${staged}.part" "$staged"
        sudo chown root:root "$staged"
        sudo chmod 0644 "$staged"
        ok "Staged at $staged"
    fi

    # An earlier failed attempt may have left the original chowned to the qemu
    # user by libvirt's dynamic ownership. Give it back.
    local owner
    owner=$(stat -c %U "$src")
    if [[ "$owner" != "$USER" ]]; then
        warn "libvirt had taken ownership of $src (now $owner). Restoring it to $USER."
        sudo chown "${USER}:$(id -gn)" "$src"
    fi

    STAGED_ISO="$staged"
}

# Render the domain template. Everything variable about the VM lives here.
#   $1 disk image   $2 network name   $3 optional ISO path
render_domain() {
    local disk="$1" network="$2" iso="${3:-}"
    local cdrom="" mem_kib=$((VM_MEM_MB * 1024))

    # Clipboard sharing follows the network rather than being a global setting.
    # It is a host-to-guest channel that bypasses the network controls, so it
    # has no place on the sandbox network. During a build there is no agent yet
    # and you need to paste commands into the guest, so leaving it off there
    # just makes the install painful for no security gain.
    # Clipboard and file sharing are host-to-guest channels. In the sandbox
    # profile they would bypass the network controls entirely, so they are off
    # there and on everywhere else.
    local clipboard="yes"
    [[ "$PROFILE" == "sandbox" ]] && clipboard="no"

    # virtiofs needs the guest memory to be shareable with the virtiofsd
    # process, so the share and the memory backing are one decision, not two.
    local membacking="" share=""
    if [[ "$PROFILE" != "sandbox" && -n "$SHARE_DIR" ]]; then
        [[ -d "$SHARE_DIR" ]] || die "SHARE_DIR is set to '$SHARE_DIR', which does not exist."
        local readonly_tag=""
        [[ "$SHARE_READONLY" == "yes" ]] && readonly_tag=$'\n      <readonly/>'
        membacking=$(cat <<MEMBACK
  <memoryBacking>
    <source type='memfd'/>
    <access mode='shared'/>
  </memoryBacking>
MEMBACK
        )
        share=$(cat <<SHARECFG

    <filesystem type='mount' accessmode='passthrough'>
      <driver type='virtiofs'/>
      <source dir='${SHARE_DIR}'/>
      <target dir='${SHARE_TAG}'/>${readonly_tag}
    </filesystem>
SHARECFG
        )
    fi

    if [[ -n "$iso" ]]; then
        cdrom=$(cat <<CDROM

    <disk type='file' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source file='${iso}'/>
      <target dev='sda' bus='sata'/>
      <readonly/>
    </disk>
CDROM
        )
    fi

    # An existing domain must keep its UUID. virsh define matches on UUID, and
    # XML without one makes libvirt mint a fresh UUID and then refuse the define
    # because the name is already taken. Redefining on every boot only works if
    # the UUID is carried through.
    local uuid=""
    if domain_exists; then
        uuid=$($VIRSH domuuid "$VM_NAME" 2>/dev/null | tr -d '[:space:]')
    fi

    local rendered
    rendered=$(mktemp -t "${VM_NAME}.XXXXXX.xml")
    # shellcheck disable=SC2016
    awk -v vm="$VM_NAME" -v uuid="$uuid" -v mem="$mem_kib" -v vcpus="$VM_VCPUS" \
        -v code="$OVMF_CODE" -v nvram="$NVRAM_FILE" -v vars="$OVMF_VARS_TEMPLATE" \
        -v disk="$disk" -v net="$network" -v mac="$GUEST_MAC" -v node="$RENDER_NODE" \
        -v accel="${ACCEL3D:-yes}" -v gl="${GL_ENABLE:-yes}" -v cdrom="$cdrom" \
        -v vw="$VIDEO_WIDTH" -v vh="$VIDEO_HEIGHT" -v clip="$clipboard" \
        -v membacking="$membacking" -v share="$share" '
        { gsub(/@VM_NAME@/, vm); gsub(/@VM_MEM_KIB@/, mem); gsub(/@VM_VCPUS@/, vcpus);
          gsub(/@OVMF_CODE@/, code); gsub(/@NVRAM_FILE@/, nvram);
          gsub(/@OVMF_VARS_TEMPLATE@/, vars); gsub(/@DISK_IMAGE@/, disk);
          gsub(/@NETWORK@/, net); gsub(/@GUEST_MAC@/, mac); gsub(/@RENDER_NODE@/, node);
          gsub(/@ACCEL3D@/, accel); gsub(/@GL_ENABLE@/, gl);
          gsub(/@VIDEO_WIDTH@/, vw); gsub(/@VIDEO_HEIGHT@/, vh);
          gsub(/@CLIPBOARD@/, clip);
          if ($0 ~ /@UUID_LINE@/) {
              if (uuid == "") next
              sub(/@UUID_LINE@/, "<uuid>" uuid "</uuid>")
          }
          if ($0 ~ /@CDROM_BLOCK@/) { sub(/@CDROM_BLOCK@/, cdrom) }
          if ($0 ~ /@MEMBACKING_BLOCK@/) {
              if (membacking == "") next
              sub(/@MEMBACKING_BLOCK@/, membacking)
          }
          if ($0 ~ /@SHARE_BLOCK@/) {
              if (share == "") next
              sub(/@SHARE_BLOCK@/, share)
          }
          print }
    ' "$TEMPLATE" > "$rendered"
    echo "$rendered"
}

define_domain() {
    local disk="$1" network="$2" iso="${3:-}"
    local xml
    xml=$(render_domain "$disk" "$network" "$iso")
    if ! $VIRSH define "$xml" >/dev/null; then
        rm -f "$xml"
        die "Failed to define the domain. The rendered XML is shown above."
    fi
    rm -f "$xml"
}

# Run a command in the guest and stream its stdout back. Kept separate from
# cmd_ssh, which execs and therefore cannot be called from another function.
guest_exec() {
    ssh -i "$SSH_KEY" $SSH_OPTS -o BatchMode=yes "${GUEST_USER}@${GUEST_IP}" "$@"
}

wait_for_ssh() {
    local host="$1" timeout="${2:-180}" elapsed=0
    printf '    waiting for ssh on %s ' "$host"
    while (( elapsed < timeout )); do
        if ssh -i "$SSH_KEY" $SSH_OPTS -o BatchMode=yes \
               "${GUEST_USER}@${host}" true 2>/dev/null; then
            printf ' up\n'
            return 0
        fi
        printf '.'
        sleep 3
        elapsed=$((elapsed + 3))
    done
    printf ' timed out\n'
    return 1
}

start_proxy() {
    # The proxy exists to give an isolated guest a controlled way out. With a
    # NAT network there is nothing for it to do, so it stays stopped.
    [[ "$PROFILE" == "sandbox" ]] || return 0
    if ! systemctl is-active --quiet omavm-agent-proxy; then
        sudo systemctl start omavm-agent-proxy \
            || warn "Proxy failed to start. Check: journalctl -u omavm-agent-proxy -n 30"
    fi
    systemctl is-active --quiet omavm-agent-proxy \
        && ok "Egress proxy running on ${HOST_IP}:${PROXY_PORT} and :${GATEWAY_PORT}"
}

# --------------------------------------------------------------------------
# commands
# --------------------------------------------------------------------------
cmd_init() {
    stage "Creating the build disk"
    [[ -f "$WORK_IMAGE" ]] && die "$WORK_IMAGE already exists. Remove it first if you mean to start over."
    sudo qemu-img create -f qcow2 "$WORK_IMAGE" "$DISK_SIZE" >/dev/null
    ok "Created $WORK_IMAGE ($DISK_SIZE, thin provisioned)"
    info "Next: $0 build --iso /path/to/omarchy.iso"
}

cmd_rebuild() {
    stage "Discarding the guest and starting the install over"
    domain_running && $VIRSH destroy "$VM_NAME" >/dev/null
    sudo rm -f "$WORK_IMAGE" "$NVRAM_FILE"
    ok "Removed the build disk and the UEFI variables"
    cmd_init
    cmd_build "$@"
}

cmd_build() {
    local iso="$OMARCHY_ISO"
    while (( $# )); do
        case "$1" in
            --iso) iso="$2"; shift 2 ;;
            *) die "Unknown option for build: $1" ;;
        esac
    done

    [[ -f "$iso" ]] || die "ISO not found: $iso
    Download the Omarchy ISO from https://omarchy.org and pass --iso /path/to/it,
    or set OMARCHY_ISO in config/omavm.conf."
    [[ -f "$WORK_IMAGE" ]] || die "No build disk. Run: $0 init"

    stage "Preparing installer media"
    stage_iso "$iso"

    stage "Booting the installer on the build network"
    domain_running && $VIRSH destroy "$VM_NAME" >/dev/null
    $VIRSH net-start "$VM_NET" &>/dev/null || true
    sudo rm -f "$NVRAM_FILE"
    define_domain "$WORK_IMAGE" "$VM_NET" "$STAGED_ISO"
    $VIRSH start "$VM_NAME" >/dev/null
    ok "Guest started with the installer attached"
    echo
    info "Install Omarchy normally. Two things matter for the rest of this toolkit:"
    info "  * Create the user account named '${GUEST_USER}'."
    info "    If you use a different name, change GUEST_USER in config/omavm.conf."
    info "  * Disk encryption is fine but you will have to type the passphrase"
    info "    at every boot, which defeats unattended resets. Leave it off."
    echo
    info "When the install has finished and you are at the desktop, run: $0 seal"
    cmd_gui
}

cmd_seal() {
    domain_running || die "The guest is not running. Run '$0 build' and finish the install first."
    [[ "$PROFILE" != "sandbox" ]] \
        || die "Sealing needs internet to install the guest tooling.
    Run it with the workstation profile: OMAVM_PROFILE=workstation $0 seal"
    [[ -f "${SSH_KEY}.pub" ]] || die "Missing ${SSH_KEY}.pub. Run install_host_deps.sh first."

    stage "Serving the seal script to the guest"
    local serve_dir rendered pubkey
    serve_dir=$(mktemp -d)
    trap 'rm -rf "$serve_dir"' RETURN
    pubkey=$(< "${SSH_KEY}.pub")

    sed -e "s|@GUEST_USER@|${GUEST_USER}|g" \
        -e "s|@VM_NAME@|${VM_NAME}|g" \
        -e "s|@SANDBOX_HOST_IP@|${SANDBOX_HOST_IP}|g" \
        -e "s|@SANDBOX_SUBNET_PREFIX@|${SANDBOX_HOST_IP%.*}|g" \
        -e "s|@PROXY_PORT@|${PROXY_PORT}|g" \
        -e "s|@GATEWAY_PORT@|${GATEWAY_PORT}|g" \
        -e "s|@SHARE_TAG@|${SHARE_TAG}|g" \
        -e "s|@SHARE_MOUNT@|${SHARE_MOUNT}|g" \
        -e "s|@PUBKEY@|${pubkey}|g" \
        "$SEAL_SRC" > "${serve_dir}/s"

    python3 -m http.server "$SEAL_HTTP_PORT" --bind "$HOST_IP" \
        --directory "$serve_dir" &>/dev/null &
    local server_pid=$!
    trap 'kill '"$server_pid"' 2>/dev/null; rm -rf "$serve_dir"' RETURN

    if command -v ufw &>/dev/null && sudo ufw status | head -1 | grep -q active; then
        sudo ufw allow in on "$VM_BRIDGE" to "$HOST_IP" port "$SEAL_HTTP_PORT" \
            proto tcp comment 'omavm seal' >/dev/null 2>&1 || true
    fi

    echo
    printf '  %sIn a terminal inside the guest, run this one line:%s\n\n' "$c_bold" "$c_reset"
    printf '    curl -sL %s:%s/s | sudo bash\n\n' "$HOST_IP" "$SEAL_HTTP_PORT"
    info "Clipboard sharing is on during a build, so you can paste this."
    info "It is off on the sandbox network, where an agent could abuse it."
    info "This script waits until the guest accepts the new SSH key."

    if wait_for_ssh "$GUEST_IP" 900; then
        ok "Guest sealed and reachable over SSH"
        info "Next: shut the guest down, then run: $0 freeze"
    else
        die "Timed out waiting for SSH. Check the seal output in the guest terminal."
    fi

    if command -v ufw &>/dev/null && sudo ufw status | head -1 | grep -q active; then
        sudo ufw delete allow in on "$VM_BRIDGE" to "$HOST_IP" port "$SEAL_HTTP_PORT" \
            proto tcp >/dev/null 2>&1 || true
    fi
}

cmd_freeze() {
    domain_running && die "Shut the guest down first: $0 stop"
    [[ -f "$WORK_IMAGE" ]] || die "No build disk at $WORK_IMAGE"

    stage "Freezing the build disk into the read-only base"
    if [[ -f "$BASE_IMAGE" ]]; then
        warn "A base image already exists and will be replaced:"
        info "$(sudo ls -lh "$BASE_IMAGE" | awk '{print $5, $6, $7, $8, $9}')"
        read -r -p "  Replace it? [y/N] " reply
        [[ "$reply" =~ ^[Yy] ]] || die "Aborted."
        sudo chmod 0644 "$BASE_IMAGE"
    fi

    # Converting rather than copying compacts the image and flattens any
    # accumulated internal snapshots, so the base is a single clean layer.
    info "Compacting. This takes a few minutes for a desktop install."
    sudo qemu-img convert -O qcow2 -c "$WORK_IMAGE" "${BASE_IMAGE}.tmp"
    sudo mv "${BASE_IMAGE}.tmp" "$BASE_IMAGE"
    sudo chmod 0444 "$BASE_IMAGE"
    ok "Base image written: $(sudo du -h "$BASE_IMAGE" | cut -f1) at $BASE_IMAGE"
    warn "The base is now mode 0444. Never boot it directly; boot overlays of it."
    cmd_reset
}

cmd_reset() {
    [[ -f "$BASE_IMAGE" ]] || die "No base image at $BASE_IMAGE. Run the build and freeze steps first."

    stage "Resetting the guest to the base image"
    if domain_running; then
        # Nothing in the overlay is worth preserving, so this is a hard stop
        # rather than a graceful shutdown. That is the point of the command.
        $VIRSH destroy "$VM_NAME" >/dev/null
        ok "Running guest destroyed"
    fi

    sudo rm -f "$OVERLAY_IMAGE"
    sudo qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMAGE" "$OVERLAY_IMAGE" >/dev/null
    ok "Fresh overlay created over $(basename "$BASE_IMAGE")"

    # Resetting the disk alone is not a clean reset. UEFI variables live in a
    # separate file, so boot entries and anything else the guest wrote to NVRAM
    # would survive. Restoring the vars template closes that gap.
    sudo install -m 0600 -o root -g root "$OVMF_VARS_TEMPLATE" "$NVRAM_FILE"
    ok "UEFI variables restored from the firmware template"

    define_domain "$OVERLAY_IMAGE" "$VM_NET"
    ok "Domain redefined on the isolated network"
    info "Start it with: $0 start --gui"
}

cmd_start() {
    local attach=0
    while (( $# )); do
        case "$1" in
            --gui) attach=1 ;;
            --headless) attach=0 ;;
            *) die "Unknown option for start: $1" ;;
        esac
        shift
    done

    [[ -f "$OVERLAY_IMAGE" ]] || die "No overlay. Run: $0 reset"
    stage "Starting the sandbox VM"
    $VIRSH net-start "$VM_NET" &>/dev/null || true
    start_proxy

    if domain_running; then
        ok "Already running"
    else
        define_domain "$OVERLAY_IMAGE" "$VM_NET"
        $VIRSH start "$VM_NAME" >/dev/null
        ok "Started on $VM_NET (profile: $PROFILE)"
    fi
    (( attach )) && cmd_gui
    info "SSH in with: $0 ssh"
}

cmd_stop() {
    local force=0
    [[ "${1:-}" == "--force" ]] && force=1
    domain_running || { ok "Not running"; return; }
    stage "Stopping the guest"
    if (( force )); then
        $VIRSH destroy "$VM_NAME" >/dev/null
        ok "Powered off"
    else
        $VIRSH shutdown "$VM_NAME" >/dev/null
        local waited=0
        while domain_running && (( waited < 60 )); do sleep 2; waited=$((waited + 2)); done
        if domain_running; then
            warn "Guest ignored the shutdown request after 60s. Use --force to power it off."
        else
            ok "Shut down cleanly"
        fi
    fi
}

cmd_gui() {
    domain_running || die "The guest is not running."
    command -v virt-viewer &>/dev/null || die "virt-viewer is not installed."
    stage "Attaching a display"
    # --attach is required: with GL enabled the SPICE server has no network
    # listener, so the client gets the socket through libvirt rather than by
    # connecting to a port.
    virt-viewer --connect qemu:///system --attach "$VM_NAME" &>/dev/null &
    disown
    ok "virt-viewer launched"
}

cmd_ssh() {
    domain_running || die "The guest is not running. Run: $0 start"
    [[ "${1:-}" == "--" ]] && shift
    local host
    host="$GUEST_IP"
    exec ssh -i "$SSH_KEY" $SSH_OPTS "${GUEST_USER}@${host}" "$@"
}

cmd_refresh() {
    [[ -f "$BASE_IMAGE" ]] || die "No base image to refresh."
    stage "Booting the base image on the build network for updating"
    domain_running && $VIRSH destroy "$VM_NAME" >/dev/null

    # The base is read-only, so the refresh happens on a fresh writable copy
    # which then becomes the new base. The old base stays intact until freeze
    # replaces it, so a failed refresh costs nothing.
    sudo rm -f "$WORK_IMAGE"
    info "Copying the base to a writable image. This takes a moment."
    sudo qemu-img convert -O qcow2 "$BASE_IMAGE" "$WORK_IMAGE"
    $VIRSH net-start "$VM_NET" &>/dev/null || true
    sudo install -m 0600 -o root -g root "$OVMF_VARS_TEMPLATE" "$NVRAM_FILE"
    define_domain "$WORK_IMAGE" "$VM_NET"
    $VIRSH start "$VM_NAME" >/dev/null
    ok "Base running on the build network with internet access"
    info "Update it: $0 ssh, then 'sudo pacman -Syu' and 'omarchy-update'."
    info "When done: $0 stop, then $0 freeze"
}

cmd_status() {
    stage "Status"
    printf '  %-22s %s\n' "profile" "$PROFILE"
    printf '  %-22s %s\n' "domain" "$($VIRSH domstate "$VM_NAME" 2>/dev/null || echo 'undefined')"
    printf '  %-22s %s\n' "network" "$(current_network)"
    printf '  %-22s %s\n' "guest address" "$GUEST_IP"
    if [[ -n "$SHARE_DIR" && "$PROFILE" != "sandbox" ]]; then
        printf '  %-22s %s -> %s%s\n' "file share" "$SHARE_DIR" "$SHARE_MOUNT" \
            "$([[ "$SHARE_READONLY" == "yes" ]] && echo ' (read-only)')"
    else
        printf '  %-22s %s\n' "file share" "disabled"
    fi
    if [[ "$PROFILE" == "sandbox" ]]; then
        printf '  %-22s %s\n' "proxy" "$(systemctl is-active omavm-agent-proxy 2>/dev/null)"
    fi
    if [[ -f "$BASE_IMAGE" ]]; then
        printf '  %-22s %s (sealed %s)\n' "base image" \
            "$(sudo du -h "$BASE_IMAGE" | cut -f1)" \
            "$(sudo stat -c %y "$BASE_IMAGE" | cut -d' ' -f1)"
    else
        printf '  %-22s %s\n' "base image" "missing"
    fi
    if [[ -f "$OVERLAY_IMAGE" ]]; then
        printf '  %-22s %s written since the last reset\n' "overlay" \
            "$(sudo du -h "$OVERLAY_IMAGE" | cut -f1)"
    else
        printf '  %-22s %s\n' "overlay" "missing, run reset"
    fi
}

# Watching without interfering. Attaching a viewer means your pointer enters
# the guest whenever it is over the window, which fights an agent that is
# driving the cursor. Pulling frames over SSH lets you see what is happening
# and touch nothing. Host-side capture is not an option here: qemu cannot
# screendump a virgl guest, it reports "no surface".
cmd_watch() {
    domain_running || die "The guest is not running."
    local interval="${1:-2}" out
    out=$(mktemp -t "omavm-watch.XXXXXX.png")
    command -v imv &>/dev/null || command -v swayimg &>/dev/null \
        || warn "No lightweight image viewer found. Install imv to see frames update."
    stage "Pulling frames from the guest every ${interval}s. Ctrl-C to stop."
    info "Your pointer never enters the guest, so the agent keeps the cursor."
    while true; do
        if guest_exec "grim -" > "$out".new 2>/dev/null && [[ -s "$out".new ]]; then
            mv "$out".new "$out"
            printf '\r  %s  %s' "$(date +%H:%M:%S)" "$out"
        else
            printf '\r  %s  no frame (is a session running in the guest?)' "$(date +%H:%M:%S)"
        fi
        sleep "$interval"
    done
}

cmd_screenshot() {
    domain_running || die "The guest is not running."
    local out="${1:-omavm-$(date +%Y%m%d-%H%M%S).png}"
    guest_exec "grim -" > "$out" || die "Capture failed. Is a graphical session running in the guest?"
    [[ -s "$out" ]] || die "Capture produced an empty file."
    ok "Wrote $out ($(du -h "$out" | cut -f1))"
}

cmd_logs() {
    stage "Proxy audit log"
    info "ALLOW and DENY lines show every destination the guest asked for."
    sudo tail -f "$PROXY_LOG"
}

usage() { awk 'NR>=3 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; }

# --------------------------------------------------------------------------
main() {
    local cmd="${1:-status}"
    shift || true
    case "$cmd" in
        init|build|rebuild|seal|freeze|reset|start|stop|gui|ssh|watch|screenshot|refresh|status|logs)
            require_libvirt_access
            "cmd_${cmd}" "$@"
            ;;
        -h|--help|help) usage ;;
        *) usage; exit 2 ;;
    esac
}

main "$@"
