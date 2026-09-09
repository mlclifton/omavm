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
#   reboot    Restart the guest over ACPI, no guest password needed.
#   gui       Attach a display to a running VM. Steals the pointer when focused.
#   watch     Stream screenshots from the guest without touching its cursor.
#   screenshot  Save one frame from the guest to a file.
#   ssh       Run a command in the guest, or open a shell.
#   paste     Type the host clipboard into the guest, key by key. For use
#             before the guest is sealed, when nothing else works.
#   clip      Move the clipboard between host and guest over SSH.
#             `clip pull` guest to host, `clip push` host to guest.
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

# Starting a domain against an undefined network fails deep inside libvirt with
# a message that says nothing about how to fix it. Check first and say what to
# run.
require_network() {
    local net="$1"
    if ! $VIRSH net-info "$net" &>/dev/null; then
        die "The libvirt network '$net' is not defined.

    Networks are created by the host installer, which is idempotent and will
    only add what is missing:

        ./install_host_deps.sh

    If you have just changed PROFILE or upgraded this repository, that is
    expected: the installer also migrates networks whose bridge or address
    has moved."
    fi
    if [[ "$($VIRSH net-info "$net" 2>/dev/null | awk '/Active/{print $2}')" != "yes" ]]; then
        $VIRSH net-start "$net" >/dev/null \
            || die "Could not start the network '$net'. Check: $VIRSH net-info $net"
        ok "Started network '$net'"
    fi
}
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

# The seal script inside the guest requests /whoami/<user>. Watch the server's
# access log for it, so the host learns the real account name rather than
# assuming the configured one is right.
wait_for_guest_user() {
    local log="$1" timeout="${2:-900}" i=0 line name
    printf '    waiting for the guest to run it ' >&2
    while (( i < timeout * 2 )); do
        # Match the whole path segment against what a user name may contain,
        # rather than extracting loosely and validating after. A path with
        # slashes in it then never matches at all, instead of being reduced to
        # its last component and passing as a plausible name.
        line=$(grep -oE 'GET /whoami/[A-Za-z0-9_][A-Za-z0-9_-]{0,31} ' "$log" 2>/dev/null | tail -1) || true
        if [[ -n "$line" ]]; then
            name="${line#GET /whoami/}"
            name="${name% }"
            printf ' reported\n' >&2
            echo "$name"
            return 0
        fi
        (( i % 20 == 0 )) && printf '.' >&2
        sleep 0.5
        i=$(( i + 1 ))
    done
    printf ' no report\n' >&2
    return 0
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
    require_network "$VM_NET"
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

    require_network "$VM_NET"

    stage "Preparing installer media"
    stage_iso "$iso"

    stage "Booting the installer"
    domain_running && $VIRSH destroy "$VM_NAME" >/dev/null
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

# Kill a seal server left over from an earlier, interrupted run. Matched on our
# own exact command line rather than on the port, so nothing else is touched.
stop_stale_seal_server() {
    local pids
    pids=$(pgrep -f "http\.server ${SEAL_HTTP_PORT} --bind " 2>/dev/null) || return 0
    [[ -n "$pids" ]] || return 0
    local pid
    for pid in $pids; do
        [[ "$pid" == "$$" ]] && continue
        warn "Stopping a seal server left over from an earlier run (pid ${pid})."
        kill "$pid" 2>/dev/null || true
    done
    sleep 0.5
}

# Render the seal script with everything substituted. $1 is the SEAL_URL, left
# empty when the script is delivered over SSH rather than served over HTTP.
render_seal() {
    local url="$1" out="$2" pubkey
    pubkey=$(< "${SSH_KEY}.pub")
    sed -e "s|@GUEST_USER@|${GUEST_USER}|g" \
        -e "s|@VM_NAME@|${VM_NAME}|g" \
        -e "s|@SANDBOX_HOST_IP@|${SANDBOX_HOST_IP}|g" \
        -e "s|@SANDBOX_SUBNET_PREFIX@|${SANDBOX_HOST_IP%.*}|g" \
        -e "s|@PROXY_PORT@|${PROXY_PORT}|g" \
        -e "s|@GATEWAY_PORT@|${GATEWAY_PORT}|g" \
        -e "s|@SHARE_TAG@|${SHARE_TAG}|g" \
        -e "s|@SHARE_MOUNT@|${SHARE_MOUNT}|g" \
        -e "s|@WORKSTATION_SUBNET@|${WORKSTATION_SUBNET}|g" \
        -e "s|@SANDBOX_SUBNET@|${SANDBOX_SUBNET}|g" \
        -e "s|@SEAL_URL@|${url}|g" \
        -e "s|@PUBKEY@|${pubkey}|g" \
        "$SEAL_SRC" > "$out"
}

# Once the guest has SSH, sealing needs no HTTP server and nothing typed in the
# guest. Re-sealing happens on every base refresh, so this is the common path.
# The served-over-HTTP route below exists only for the first seal, when there is
# no way in yet.
seal_over_ssh() {
    local work
    work=$(mktemp -d)
    trap 'rm -rf "$work"' RETURN

    stage "Sealing over SSH"
    ok "Guest already reachable at ${GUEST_IP}, no manual step needed"

    tar -C "${REPO_DIR}/guest/skills" -czf "${work}/skills.tar.gz" . \
        || die "Could not package guest/skills"
    render_seal "" "${work}/seal.sh"

    scp -q -i "$SSH_KEY" $SSH_OPTS "${work}/skills.tar.gz" "${work}/seal.sh" \
        "${GUEST_USER}@${GUEST_IP}:/tmp/" \
        || die "Could not copy the seal files into the guest"
    guest_exec "mv /tmp/skills.tar.gz /tmp/omavm-skills.tar.gz"

    # Copy the script in and run it from there rather than feeding it on
    # stdin. With the script on stdin there is no terminal left for sudo to
    # prompt on, and it refuses instead of asking for a password.
    info "The guest will ask for the sudo password for ${GUEST_USER}."
    ssh -t -i "$SSH_KEY" $SSH_OPTS "${GUEST_USER}@${GUEST_IP}" \
        "sudo bash /tmp/seal.sh; rm -f /tmp/seal.sh"
}

cmd_seal() {
    domain_running || die "The guest is not running. Run '$0 build' and finish the install first."
    [[ "$PROFILE" != "sandbox" ]] \
        || die "Sealing needs internet to install the guest tooling.
    Run it with the workstation profile: OMAVM_PROFILE=workstation $0 seal"
    [[ -f "${SSH_KEY}.pub" ]] || die "Missing ${SSH_KEY}.pub. Run install_host_deps.sh first."

    if guest_exec true 2>/dev/null; then
        seal_over_ssh
        echo
        info "Reboot the guest so the session services start, then freeze:"
        info "  $0 reboot"
        info "  $0 stop && $0 freeze"
        return
    fi

    stage "Serving the seal script to the guest"
    local serve_dir
    serve_dir=$(mktemp -d)
    trap 'rm -rf "$serve_dir"' RETURN

    # The guest fetches the agent skill from the same server that serves this
    # script, so there is one transfer mechanism rather than two.
    tar -C "${REPO_DIR}/guest/skills" -czf "${serve_dir}/skills.tar.gz" . \
        || die "Could not package guest/skills"

    render_seal "http://${HOST_IP}:${SEAL_HTTP_PORT}" "${serve_dir}/s"

    # A server left behind by an interrupted seal keeps the port, so the new
    # one fails to bind and the guest silently fetches the previous script.
    # That is invisible from the guest: the command works, it just runs a stale
    # copy with the old settings baked in.
    stop_stale_seal_server

    # Keep the access log: it is how the guest reports which account it has.
    python3 -m http.server "$SEAL_HTTP_PORT" --bind "$HOST_IP" \
        --directory "$serve_dir" &>"${serve_dir}/access.log" &
    local server_pid=$!
    # RETURN alone does not fire when the user interrupts, which is how the
    # stale servers accumulated in the first place.
    trap 'kill '"$server_pid"' 2>/dev/null; rm -rf "$serve_dir"' RETURN EXIT INT TERM

    local waited=0
    while (( waited < 20 )); do
        ss -ltn "src = ${HOST_IP}:${SEAL_HTTP_PORT}" 2>/dev/null | grep -q LISTEN && break
        sleep 0.25
        waited=$(( waited + 1 ))
    done
    if ! ss -ltn "src = ${HOST_IP}:${SEAL_HTTP_PORT}" 2>/dev/null | grep -q LISTEN; then
        sed 's/^/    /' "${serve_dir}/access.log" >&2
        die "The seal server did not start on ${HOST_IP}:${SEAL_HTTP_PORT}."
    fi
    ok "Serving on ${HOST_IP}:${SEAL_HTTP_PORT}"

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

    local reported
    reported=$(wait_for_guest_user "${serve_dir}/access.log" 900)
    if [[ -n "$reported" && "$reported" != "$GUEST_USER" ]]; then
        warn "The guest account is '${reported}', not '${GUEST_USER}'."
        info "Sealing continues with '${reported}'. To make that permanent, set"
        info "GUEST_USER=\"${reported}\" in config/omavm.conf, otherwise ssh and"
        info "the other commands will keep looking for '${GUEST_USER}'."
        GUEST_USER="$reported"
    fi

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
    require_network "$VM_NET"
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

# Reboot without needing a password in the guest. ACPI goes through the
# hypervisor, so it works even when sudo would prompt, and when the guest agent
# is not running.
cmd_reboot() {
    domain_running || die "The guest is not running."
    stage "Rebooting the guest"
    $VIRSH reboot "$VM_NAME" >/dev/null || die "Reboot request failed."
    ok "ACPI reboot requested"
    info "Session services such as spice-vdagent and ydotoold start on the next login."
    if wait_for_ssh "$GUEST_IP" 120; then
        ok "Guest is back"
    else
        warn "SSH did not come back within 120s. Check with: $0 status"
    fi
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
    apply_keyboard_layout
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
    # Allocate a terminal only when stdout is one. Without it sudo in the guest
    # has nowhere to prompt and refuses; with it unconditionally, a piped
    # command like `ssh -- omarchy-ui shot -` would have its binary output
    # mangled by the pty's line-ending translation.
    local -a tty_flag=()
    [[ -t 1 ]] && tty_flag=(-t)
    exec ssh "${tty_flag[@]}" -i "$SSH_KEY" $SSH_OPTS "${GUEST_USER}@${GUEST_IP}" "$@"
}

cmd_refresh() {
    [[ -f "$BASE_IMAGE" ]] || die "No base image to refresh."
    require_network "$VM_NET"

    stage "Booting a writable copy of the base image for updating"
    domain_running && $VIRSH destroy "$VM_NAME" >/dev/null

    # The base is read-only, so the refresh happens on a fresh writable copy
    # which then becomes the new base. The old base stays intact until freeze
    # replaces it, so a failed refresh costs nothing.
    sudo rm -f "$WORK_IMAGE"
    info "Copying the base to a writable image. This takes a moment."
    sudo qemu-img convert -O qcow2 "$BASE_IMAGE" "$WORK_IMAGE"
    sudo install -m 0600 -o root -g root "$OVMF_VARS_TEMPLATE" "$NVRAM_FILE"
    define_domain "$WORK_IMAGE" "$VM_NET"
    $VIRSH start "$VM_NAME" >/dev/null
    ok "Base running on $VM_NET with internet access"
    info "Update it: $0 ssh, then 'sudo pacman -Syu' and 'omarchy-update'."
    info "When done: $0 stop, then $0 freeze"
}

# Typing into the guest without a guest agent.
#
# SPICE clipboard sharing needs spice-vdagent running inside the guest, which
# means it cannot work in the installer or on any guest that has not been
# sealed yet. That is exactly when you most want to paste something.
#
# qemu can inject keystrokes at the virtual keyboard, below anything the guest
# is running, so this works from the firmware screen onwards.
#
# Assumes a US keyboard layout in the guest. Letters and digits are safe on any
# layout; symbols are not, because the keycode for a symbol depends on layout.
# The guest's keyboard layout decides which physical key carries which symbol.
# Letters and digits are the same everywhere; symbols are not. Getting this
# wrong is silent: the text arrives, with the wrong punctuation in it.
apply_keyboard_layout() {
    case "${KEYBOARD_LAYOUT:-us}" in
        us) ;;
        gb|uk)
            OMAVM_SYMKEY['"']="KEY_LEFTSHIFT KEY_2"
            OMAVM_SYMKEY['@']="KEY_LEFTSHIFT KEY_APOSTROPHE"
            OMAVM_SYMKEY['#']="KEY_BACKSLASH"
            OMAVM_SYMKEY['~']="KEY_LEFTSHIFT KEY_BACKSLASH"
            OMAVM_SYMKEY['\']="KEY_102ND"
            OMAVM_SYMKEY['|']="KEY_LEFTSHIFT KEY_102ND"
            ;;
        *)
            die "Unknown KEYBOARD_LAYOUT '${KEYBOARD_LAYOUT}'. Supported: us, gb."
            ;;
    esac
}

declare -A OMAVM_SYMKEY=(
    [' ']="KEY_SPACE"          [$'\n']="KEY_ENTER"        [$'\t']="KEY_TAB"
    ['-']="KEY_MINUS"          ['_']="KEY_LEFTSHIFT KEY_MINUS"
    ['=']="KEY_EQUAL"          ['+']="KEY_LEFTSHIFT KEY_EQUAL"
    ['[']="KEY_LEFTBRACE"      ['{']="KEY_LEFTSHIFT KEY_LEFTBRACE"
    [']']="KEY_RIGHTBRACE"     ['}']="KEY_LEFTSHIFT KEY_RIGHTBRACE"
    ['\']="KEY_BACKSLASH"      ['|']="KEY_LEFTSHIFT KEY_BACKSLASH"
    [';']="KEY_SEMICOLON"      [':']="KEY_LEFTSHIFT KEY_SEMICOLON"
    ["'"]="KEY_APOSTROPHE"     ['"']="KEY_LEFTSHIFT KEY_APOSTROPHE"
    [',']="KEY_COMMA"          ['<']="KEY_LEFTSHIFT KEY_COMMA"
    ['.']="KEY_DOT"            ['>']="KEY_LEFTSHIFT KEY_DOT"
    ['/']="KEY_SLASH"          ['?']="KEY_LEFTSHIFT KEY_SLASH"
    ['`']="KEY_GRAVE"          ['~']="KEY_LEFTSHIFT KEY_GRAVE"
    ['!']="KEY_LEFTSHIFT KEY_1"   ['@']="KEY_LEFTSHIFT KEY_2"
    ['#']="KEY_LEFTSHIFT KEY_3"   ['$']="KEY_LEFTSHIFT KEY_4"
    ['%']="KEY_LEFTSHIFT KEY_5"   ['^']="KEY_LEFTSHIFT KEY_6"
    ['&']="KEY_LEFTSHIFT KEY_7"   ['*']="KEY_LEFTSHIFT KEY_8"
    ['(']="KEY_LEFTSHIFT KEY_9"   [')']="KEY_LEFTSHIFT KEY_0"
)

keycodes_for() {
    local c="$1"
    case "$c" in
        [a-z]) printf 'KEY_%s' "${c^^}" ;;
        [A-Z]) printf 'KEY_LEFTSHIFT KEY_%s' "$c" ;;
        [0-9]) printf 'KEY_%s' "$c" ;;
        *)     printf '%s' "${OMAVM_SYMKEY[$c]:-}" ;;
    esac
}

cmd_paste() {
    # Flags are recognised wherever they appear. Stopping at the first
    # non-flag argument meant a trailing --enter was typed into the guest as
    # literal text, which is exactly where it reads most naturally.
    local press_enter=0 dry=0
    local -a words=()
    while (( $# )); do
        case "$1" in
            --enter)   press_enter=1 ;;
            --dry-run) dry=1 ;;
            --)        shift; words+=("$@"); break ;;
            *)         words+=("$1") ;;
        esac
        shift
    done
    local text="${words[*]}"

    domain_running || die "The guest is not running."
    apply_keyboard_layout

    if [[ -z "$text" ]]; then
        if [[ ! -t 0 ]]; then
            text=$(cat)
        elif command -v wl-paste &>/dev/null; then
            text=$(wl-paste --no-newline 2>/dev/null) \
                || die "Could not read the clipboard. Pass the text as an argument instead."
        else
            die "No text given, nothing on stdin, and wl-paste is not installed."
        fi
    fi
    [[ -n "$text" ]] || die "Nothing to send."

    local -a batch=()
    local i c codes skipped=0
    for (( i = 0; i < ${#text}; i++ )); do
        c="${text:i:1}"
        codes=$(keycodes_for "$c")
        if [[ -z "$codes" ]]; then
            skipped=$((skipped + 1))
            continue
        fi
        batch+=("send-key $VM_NAME --holdtime 20 $codes")
    done
    (( press_enter )) && batch+=("send-key $VM_NAME --holdtime 20 KEY_ENTER")

    (( ${#batch[@]} )) || die "Nothing in that text can be typed on that layout."

    if (( dry )); then
        printf '%s\n' "${batch[@]}"
        return
    fi

    stage "Typing ${#batch[@]} keystrokes into the guest"
    info "Click into the guest window first, so the keys land where you want them."
    # One virsh session for the whole batch. A process per character makes
    # pasting a command line take tens of seconds.
    #
    # Batch mode exits 0 even when individual commands fail, so the output has
    # to be checked rather than the status.
    local output
    output=$(printf '%s\n' "${batch[@]}" | $VIRSH 2>&1)
    if grep -q '^error:' <<<"$output"; then
        grep '^error:' <<<"$output" | head -3 | sed 's/^/    /'
        die "Some keystrokes were rejected. The guest may have received part of the text."
    fi
    ok "Sent"
    (( skipped )) && warn "$skipped character(s) skipped: not typeable on a ${KEYBOARD_LAYOUT} layout."
    info "If the punctuation came out wrong, the guest layout is not '${KEYBOARD_LAYOUT}'."
    info "Set KEYBOARD_LAYOUT in config/omavm.conf, or OMAVM_KEYBOARD_LAYOUT for one run."
    return 0
}

# Clipboard transfer over SSH.
#
# SPICE clipboard sharing does not work with a Hyprland guest. The packaged
# spice-vdagent is an X11 agent: its own help says "guest agent: X11", it links
# libx11 and takes an X --display, and it syncs the XWayland clipboard rather
# than the Wayland one. Neither direction propagates in practice.
#
# This route does not involve SPICE at all, so it works headless with no viewer
# attached, which is the normal state for an agent-driven guest anyway.
cmd_clip() {
    domain_running || die "The guest is not running."
    local direction="${1:-pull}"
    case "$direction" in
        pull)
            command -v wl-copy &>/dev/null || die "wl-copy is not installed on the host."
            local content
            content=$(guest_exec "${OMAVM_UI:-omarchy-ui} clip-get") \
                || die "Could not read the guest clipboard. Try: $0 ssh -- omarchy-ui doctor"
            printf '%s' "$content" | wl-copy
            ok "Guest clipboard copied to the host ($(printf '%s' "$content" | wc -c) bytes)"
            ;;
        push)
            command -v wl-paste &>/dev/null || die "wl-paste is not installed on the host."
            wl-paste --no-newline | guest_exec "${OMAVM_UI:-omarchy-ui} clip-set" \
                || die "Could not set the guest clipboard."
            ok "Host clipboard copied to the guest"
            ;;
        *)
            die "usage: $0 clip [pull|push]
    pull   guest clipboard -> host   (the default)
    push   host clipboard -> guest"
            ;;
    esac
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
    apply_keyboard_layout
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
    apply_keyboard_layout
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
        init|build|rebuild|seal|freeze|reset|start|stop|reboot|gui|ssh|watch|screenshot|paste|clip|refresh|status|logs)
            require_libvirt_access
            "cmd_${cmd}" "$@"
            ;;
        -h|--help|help) usage ;;
        *) usage; exit 2 ;;
    esac
}

main "$@"
