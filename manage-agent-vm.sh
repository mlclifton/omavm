#!/usr/bin/env bash
#
# manage-agent-vm.sh — lifecycle for named Omarchy agent VMs.
#
#   manage-agent-vm.sh <vm> <command> [args]
#
# The VM name always comes first. It cannot be omitted and it cannot be
# confused with a command's own arguments, so there is no way to reset the
# wrong guest by forgetting a flag.
#
# Per-VM commands:
#   start     Boot the VM. --gui to attach a display.
#   stop      Shut down. --force to pull the plug.
#   reboot    Restart over ACPI, no guest password needed.
#   reset     Discard all guest state and return to the shared base.
#   ssh       Run a command in the guest, or open a shell.
#   gui       Attach a display. Steals the pointer when focused.
#   watch     Stream frames without touching the guest's cursor.
#   screenshot  Save one frame to a file.
#   clip      Move the clipboard: `clip pull` guest to host, `clip push` back.
#   paste     Type the host clipboard into the guest, key by key.
#   sync-ui   Install the current omarchy-ui and skill into a running guest.
#   status    Show what this VM is doing.
#
# Base-image commands, accepted only for the reserved VM name `base`:
#   init      Create the writable build disk.
#   build     Boot the installer with a display attached.
#   rebuild   Throw away a part-finished install and start over.
#   seal      Provision the installed guest for automation.
#   freeze    Turn the build disk into the shared read-only base image.
#   refresh   Boot a writable copy of the base so you can update it.
#
# Commands that act on the set rather than one member:
#   list      Every VM, its address and what it is doing.
#   new       Create a VM as a fresh overlay of the shared base.
#   rm        Destroy a VM and release its address.
#   logs      Follow the proxy audit log (sandbox profile only).
#
# The domain XML is rendered from libvirt/omarchy-agent.xml.in and redefined on
# every boot, so this repository is the source of truth. Changes made through
# virt-manager are discarded rather than quietly persisting.
#
# PROFILE in config/omavm.conf decides the network, the clipboard and whether
# file sharing is possible. Override it for one command with, for example:
#   OMAVM_PROFILE=sandbox ./manage-agent-vm.sh webapp start

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
# libvirt access
# --------------------------------------------------------------------------
require_libvirt_access() {
    $VIRSH version &>/dev/null && return 0
    die "Cannot reach qemu:///system as $USER.
    If you have just run install_host_deps.sh, log out and back in so the
    'libvirt' group applies to your session, or test with: newgrp libvirt"
}

require_network() {
    local net="$1"
    if ! $VIRSH net-info "$net" &>/dev/null; then
        die "The libvirt network '$net' is not defined.

    Networks are created by the host installer, which is idempotent and will
    only add what is missing:

        ./install_host_deps.sh"
    fi
    if [[ "$($VIRSH net-info "$net" 2>/dev/null | awk '/Active/{print $2}')" != "yes" ]]; then
        $VIRSH net-start "$net" >/dev/null \
            || die "Could not start the network '$net'."
        ok "Started network '$net'"
    fi
}

# --------------------------------------------------------------------------
# the VM registry
#
# The libvirt network's DHCP reservations ARE the registry. There is no second
# file to drift out of sync with them, they survive reboots, and `virsh
# net-dumpxml` shows the same truth this script works from.
# --------------------------------------------------------------------------

# Every VM gets a MAC derived from its address, so the two can never disagree.
mac_for_index() { printf '52:54:00:a9:e1:%02x' "$1"; }

# name<TAB>ip for every registered VM, in address order.
registry() {
    # An empty registry is normal, not an error. Under `set -o pipefail` grep
    # finding nothing would otherwise abort the caller.
    $VIRSH net-dumpxml "$VM_NET" 2>/dev/null \
        | grep -oP "<host mac='[^']+' name='[^']+' ip='[^']+'" \
        | sed -E "s/.*name='([^']+)' ip='([^']+)'/\1\t\2/" \
        | sort -t. -k4 -n || true
}

vm_registered() { registry | cut -f1 | grep -qx "$1" || return 1; }

ip_for_vm() { registry | awk -F'\t' -v n="$1" '$1 == n {print $2}' || true; }

next_free_index() {
    local used i
    used=$(registry | cut -f2 | awk -F. '{print $4}')
    for (( i = GUEST_IP_FIRST; i <= GUEST_IP_LAST; i++ )); do
        grep -qx "$i" <<<"$used" || { echo "$i"; return 0; }
        :
    done
    die "No free addresses left in ${NET_PREFIX}.${GUEST_IP_FIRST}-${GUEST_IP_LAST}."
}

register_vm() {
    local name="$1" index ip mac
    index=$(next_free_index)
    ip="${NET_PREFIX}.${index}"
    mac=$(mac_for_index "$index")
    # --live only works when the network is running; --config always applies.
    local live=""
    [[ "$($VIRSH net-info "$VM_NET" | awk '/Active/{print $2}')" == "yes" ]] && live="--live"
    $VIRSH net-update "$VM_NET" add ip-dhcp-host \
        "<host mac='${mac}' name='${name}' ip='${ip}'/>" \
        $live --config >/dev/null \
        || die "Could not add a DHCP reservation for '${name}'."
    echo "$ip"
}

unregister_vm() {
    local name="$1" ip mac index
    ip=$(ip_for_vm "$name") || return 0
    [[ -n "$ip" ]] || return 0
    index="${ip##*.}"
    mac=$(mac_for_index "$index")
    local live=""
    [[ "$($VIRSH net-info "$VM_NET" | awk '/Active/{print $2}')" == "yes" ]] && live="--live"
    $VIRSH net-update "$VM_NET" delete ip-dhcp-host \
        "<host mac='${mac}' name='${name}' ip='${ip}'/>" \
        $live --config >/dev/null 2>&1 || true
}

# --------------------------------------------------------------------------
# resolving a name to a VM
# --------------------------------------------------------------------------
validate_vm_name() {
    local name="$1"
    [[ "$name" =~ $VM_NAME_PATTERN ]] \
        || die "'${name}' is not a valid VM name.
    Use lower case letters, digits and hyphens, starting with a letter,
    up to 20 characters. This keeps a name from being mistaken for a
    command or a flag."
}

# Sets VM, VM_DOMAIN, VM_IP, VM_MAC, DISK_IMAGE, NVRAM_FILE and SHARE_DIR.
resolve_vm() {
    VM="$1"
    validate_vm_name "$VM"

    if ! vm_registered "$VM"; then
        if [[ "$VM" == "$BASE_VM" ]]; then
            # The build guest is reserved rather than created, so register it
            # on first use instead of making you run an extra command.
            require_network "$VM_NET"
            register_vm "$VM" >/dev/null
            ok "Reserved an address for the build guest '${BASE_VM}'"
        else
            local known
            known=$(registry | cut -f1 | paste -sd', ' -)
            die "No VM named '${VM}'.
    Known VMs: ${known:-none}
    Create one with:  $0 new ${VM}"
        fi
    fi

    VM_DOMAIN="omarchy-${VM}"
    VM_IP=$(ip_for_vm "$VM")
    VM_MAC=$(mac_for_index "${VM_IP##*.}")
    NVRAM_FILE="${NVRAM_DIR}/${VM_DOMAIN}_VARS.fd"

    # The base VM writes to a full disk of its own, because it is what
    # produces the image everything else overlays. Every other VM is a
    # copy-on-write overlay, which is why a new one costs almost nothing.
    if [[ "$VM" == "$BASE_VM" ]]; then
        DISK_IMAGE="${IMAGE_DIR}/base-build.qcow2"
    else
        DISK_IMAGE="${IMAGE_DIR}/${VM}-overlay.qcow2"
    fi

    SHARE_DIR=""
    if [[ -n "$SHARE_ROOT" && "$PROFILE" != "sandbox" && -d "${SHARE_ROOT}/${VM}" ]]; then
        SHARE_DIR="${SHARE_ROOT}/${VM}"
    fi

    # Per-VM overrides last, so they win over anything derived above.
    # An if rather than a test-and-source: a bare test as the last statement in
    # a function makes the function return 1 when the file is absent, which
    # under `set -e` takes the caller down with it.
    local override="${REPO_DIR}/config/vm/${VM}.conf"
    if [[ -f "$override" ]]; then
        # shellcheck source=/dev/null
        source "$override"
    fi
    return 0
}

require_base_vm() {
    [[ "$VM" == "$BASE_VM" ]] || die "'$1' builds the shared base image, so it
    only accepts the reserved VM name '${BASE_VM}':
        $0 ${BASE_VM} $1"
}

refuse_base_vm() {
    [[ "$VM" != "$BASE_VM" ]] || die "'${BASE_VM}' is the build guest, not a
    working VM. Use a VM created with '$0 new <name>'."
}

# --------------------------------------------------------------------------
# generic helpers
# --------------------------------------------------------------------------
domain_exists()  { $VIRSH dominfo "$VM_DOMAIN" &>/dev/null; }
domain_running() { [[ "$($VIRSH domstate "$VM_DOMAIN" 2>/dev/null)" == "running" ]]; }

guest_exec() {
    ssh -i "$SSH_KEY" $SSH_OPTS -o BatchMode=yes "${GUEST_USER}@${VM_IP}" "$@"
}

guest_frame() { guest_exec "${OMAVM_UI:-omarchy-ui} shot -"; }

# The seal script inside the guest requests /whoami/<user>. Watch the server's
# access log for it, so the host learns the real account name rather than
# assuming the configured one is right. Without this, a mismatch between the
# account you created and GUEST_USER leaves seal waiting for an SSH login that
# will never succeed, with nothing on screen to say why.
wait_for_guest_user() {
    local log="$1" timeout="${2:-900}" i=0 line name
    printf '    waiting for the guest to run it ' >&2
    while (( i < timeout * 2 )); do
        # Match the whole path segment against what a user name may contain,
        # rather than extracting loosely and validating afterwards.
        line=$(grep -oE 'GET /whoami/[A-Za-z0-9_][A-Za-z0-9_-]{0,31} ' "$log" 2>/dev/null | tail -1) || true
        if [[ -n "$line" ]]; then
            name="${line#GET /whoami/}"
            printf ' reported\n' >&2
            echo "${name% }"
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
    local timeout="${1:-180}" elapsed=0 err
    printf '    waiting for ssh on %s ' "$VM_IP"
    while (( elapsed < timeout )); do
        if err=$(guest_exec true 2>&1); then printf ' up\n'; return 0; fi
        # A changed host key never resolves by waiting, and the failure is
        # invisible because the loop swallows it. StrictHostKeyChecking
        # accept-new takes an unknown key but refuses a changed one, which is
        # exactly what a rebuilt guest presents.
        if grep -qiE 'host key verification failed|identification has changed' <<<"$err"; then
            printf '\n'
            die "The guest at ${VM_IP} is presenting a different SSH host key.

    That is expected after rebuilding: a fresh install generates new host keys,
    and the old ones are still recorded here. Forget the old key and retry:

        ssh-keygen -R ${VM_IP} -f ${HOME}/.ssh/known_hosts_omavm

    If you have NOT rebuilt this guest, do not clear it. A host key that
    changes on its own is the warning it is meant to be."
        fi
        printf '.'
        sleep 3
        elapsed=$((elapsed + 3))
    done
    printf ' timed out\n'
    return 1
}

# A fresh install generates new SSH host keys, so anything recorded for this
# address is now wrong and would block every later connection.
forget_host_key() {
    ssh-keygen -R "$VM_IP" -f "${HOME}/.ssh/known_hosts_omavm" &>/dev/null || true
}

start_proxy() {
    [[ "$PROFILE" == "sandbox" ]] || return 0
    systemctl is-active --quiet omavm-agent-proxy || sudo systemctl start omavm-agent-proxy \
        || warn "Proxy failed to start. Check: journalctl -u omavm-agent-proxy -n 30"
}

# --------------------------------------------------------------------------
# rendering the domain
# --------------------------------------------------------------------------
render_domain() {
    local iso="${1:-}"
    local cdrom="" mem_kib=$((VM_MEM_MB * 1024))

    # Clipboard and file sharing are host-to-guest channels. In the sandbox
    # profile they would bypass the network controls, so they are off there.
    local clipboard="yes"
    [[ "$PROFILE" == "sandbox" ]] && clipboard="no"

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

    # virtiofs needs the guest memory to be shareable with virtiofsd, so the
    # share and the memory backing are one decision, not two.
    local membacking="" share=""
    if [[ -n "$SHARE_DIR" ]]; then
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

    # An existing domain must keep its UUID. virsh define matches on UUID, and
    # XML without one makes libvirt mint a fresh UUID and then refuse the
    # define because the name is already taken.
    local uuid=""
    domain_exists && uuid=$($VIRSH domuuid "$VM_DOMAIN" 2>/dev/null | tr -d '[:space:]')

    local rendered
    rendered=$(mktemp -t "${VM_DOMAIN}.XXXXXX.xml")
    awk -v vm="$VM_DOMAIN" -v uuid="$uuid" -v mem="$mem_kib" -v vcpus="$VM_VCPUS" \
        -v code="$OVMF_CODE" -v nvram="$NVRAM_FILE" -v vars="$OVMF_VARS_TEMPLATE" \
        -v disk="$DISK_IMAGE" -v net="$VM_NET" -v mac="$VM_MAC" -v node="$RENDER_NODE" \
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
          if ($0 ~ /@UUID_LINE@/) { if (uuid == "") next; sub(/@UUID_LINE@/, "<uuid>" uuid "</uuid>") }
          if ($0 ~ /@CDROM_BLOCK@/) { sub(/@CDROM_BLOCK@/, cdrom) }
          if ($0 ~ /@MEMBACKING_BLOCK@/) { if (membacking == "") next; sub(/@MEMBACKING_BLOCK@/, membacking) }
          if ($0 ~ /@SHARE_BLOCK@/) { if (share == "") next; sub(/@SHARE_BLOCK@/, share) }
          print }
    ' "$TEMPLATE" > "$rendered"
    echo "$rendered"
}

define_domain() {
    local xml
    xml=$(render_domain "${1:-}")
    if ! $VIRSH define "$xml" >/dev/null; then
        rm -f "$xml"
        die "Failed to define ${VM_DOMAIN}."
    fi
    rm -f "$xml"
}

# --------------------------------------------------------------------------
# installer media
# --------------------------------------------------------------------------

# QEMU does not run as you. libvirt starts it as an unprivileged system user,
# which cannot traverse a 0700 home directory, so an ISO under ~/Downloads is
# unreadable no matter what mode the file itself has. libvirt also applies
# dynamic ownership to whatever it is pointed at, so naming a file in your home
# directory leaves that file chowned away from you afterwards.
STAGED_ISO=""
stage_iso() {
    local src="$1" staged
    [[ -f "$src" ]] || die "ISO not found: $src"
    staged="${IMAGE_DIR}/$(basename "$src")"

    if [[ "$src" -ef "$staged" ]]; then STAGED_ISO="$staged"; return 0; fi

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

    local owner
    owner=$(stat -c %U "$src")
    if [[ "$owner" != "$USER" ]]; then
        warn "libvirt had taken ownership of $src (now $owner). Restoring it."
        sudo chown "${USER}:$(id -gn)" "$src"
    fi
    STAGED_ISO="$staged"
}

# --------------------------------------------------------------------------
# sealing
# --------------------------------------------------------------------------
render_seal() {
    local url="$1" out="$2" pubkey
    pubkey=$(< "${SSH_KEY}.pub")
    sed -e "s|@GUEST_USER@|${GUEST_USER}|g" \
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

stop_stale_seal_server() {
    local pids pid
    pids=$(pgrep -f "http\.server ${SEAL_HTTP_PORT} --bind " 2>/dev/null) || return 0
    for pid in $pids; do
        [[ "$pid" == "$$" ]] && continue
        warn "Stopping a seal server left over from an earlier run (pid ${pid})."
        kill "$pid" 2>/dev/null || true
    done
    sleep 0.5
}

seal_over_ssh() {
    local work
    work=$(mktemp -d)
    trap 'rm -rf "$work"' RETURN

    stage "Sealing over SSH"
    ok "Guest already reachable at ${VM_IP}, no manual step needed"

    tar -C "${REPO_DIR}/guest/skills" -czf "${work}/skills.tar.gz" . \
        || die "Could not package guest/skills"
    render_seal "" "${work}/seal.sh"

    scp -q -i "$SSH_KEY" $SSH_OPTS "${work}/skills.tar.gz" "${work}/seal.sh" \
        "${GUEST_USER}@${VM_IP}:/tmp/" \
        || die "Could not copy the seal files into the guest"
    guest_exec "mv /tmp/skills.tar.gz /tmp/omavm-skills.tar.gz"

    info "The guest will ask for the sudo password for ${GUEST_USER}."
    ssh -t -i "$SSH_KEY" $SSH_OPTS "${GUEST_USER}@${VM_IP}" \
        "sudo bash /tmp/seal.sh; rm -f /tmp/seal.sh"
}

# --------------------------------------------------------------------------
# base-image commands
# --------------------------------------------------------------------------
cmd_init() {
    require_base_vm init
    [[ -f "$DISK_IMAGE" ]] && die "$DISK_IMAGE already exists. Remove it to start over."
    stage "Creating the build disk"
    sudo qemu-img create -f qcow2 "$DISK_IMAGE" "$DISK_SIZE" >/dev/null
    ok "Created $DISK_IMAGE ($DISK_SIZE, thin provisioned)"
    info "Next: $0 ${BASE_VM} build --iso /path/to/omarchy.iso"
}

cmd_build() {
    require_base_vm build
    local iso="$OMARCHY_ISO"
    while (( $# )); do
        case "$1" in
            --iso) iso="$2"; shift 2 ;;
            *) die "Unknown option for build: $1" ;;
        esac
    done
    [[ -f "$iso" ]] || die "ISO not found: $iso
    Download the Omarchy ISO from https://omarchy.org and pass --iso /path/to/it."
    [[ -f "$DISK_IMAGE" ]] || die "No build disk. Run: $0 ${BASE_VM} init"

    require_network "$VM_NET"
    stage "Preparing installer media"
    stage_iso "$iso"

    stage "Booting the installer"
    domain_running && $VIRSH destroy "$VM_DOMAIN" >/dev/null
    forget_host_key
    sudo rm -f "$NVRAM_FILE"
    define_domain "$STAGED_ISO"
    $VIRSH start "$VM_DOMAIN" >/dev/null
    ok "Guest started with the installer attached"
    echo
    info "Install Omarchy normally. Two things matter for the rest of this toolkit:"
    info "  * Create the user account named '${GUEST_USER}'."
    info "    If you use a different name, change GUEST_USER in config/omavm.conf."
    info "  * Leave disk encryption off, or you will type a passphrase at every boot."
    echo
    info "When you reach the desktop, run: $0 ${BASE_VM} seal"
    cmd_gui
}

cmd_rebuild() {
    require_base_vm rebuild
    require_network "$VM_NET"
    stage "Discarding the build guest and starting the install over"
    domain_running && $VIRSH destroy "$VM_DOMAIN" >/dev/null
    sudo rm -f "$DISK_IMAGE" "$NVRAM_FILE"
    ok "Removed the build disk and the UEFI variables"
    cmd_init
    cmd_build "$@"
}

cmd_seal() {
    require_base_vm seal
    domain_running || die "The build guest is not running. Run '$0 ${BASE_VM} build' first."
    [[ "$PROFILE" != "sandbox" ]] \
        || die "Sealing needs internet. Run it with the workstation profile."
    [[ -f "${SSH_KEY}.pub" ]] || die "Missing ${SSH_KEY}.pub. Run install_host_deps.sh first."

    if guest_exec true 2>/dev/null; then
        seal_over_ssh
        echo
        info "Reboot so the session services start, then freeze:"
        info "  $0 ${BASE_VM} reboot"
        info "  $0 ${BASE_VM} stop && $0 ${BASE_VM} freeze"
        return
    fi

    stage "Serving the seal script to the guest"
    local serve_dir
    serve_dir=$(mktemp -d)
    trap 'rm -rf "$serve_dir"' RETURN

    tar -C "${REPO_DIR}/guest/skills" -czf "${serve_dir}/skills.tar.gz" . \
        || die "Could not package guest/skills"
    render_seal "http://${HOST_IP}:${SEAL_HTTP_PORT}" "${serve_dir}/s"

    stop_stale_seal_server
    python3 -m http.server "$SEAL_HTTP_PORT" --bind "$HOST_IP" \
        --directory "$serve_dir" &>"${serve_dir}/access.log" &
    local server_pid=$!
    trap 'kill '"$server_pid"' 2>/dev/null; rm -rf "$serve_dir"' RETURN EXIT INT TERM

    local waited=0
    while (( waited < 20 )); do
        ss -ltn "src = ${HOST_IP}:${SEAL_HTTP_PORT}" 2>/dev/null | grep -q LISTEN && break
        sleep 0.25; waited=$(( waited + 1 ))
    done
    ss -ltn "src = ${HOST_IP}:${SEAL_HTTP_PORT}" 2>/dev/null | grep -q LISTEN \
        || die "The seal server did not start on ${HOST_IP}:${SEAL_HTTP_PORT}."
    ok "Serving on ${HOST_IP}:${SEAL_HTTP_PORT}"

    echo
    printf '  %sIn a terminal inside the guest, run this one line:%s\n\n' "$c_bold" "$c_reset"
    printf '    curl -sL %s:%s/s | sudo bash\n\n' "$HOST_IP" "$SEAL_HTTP_PORT"
    info "Or have the host type it for you, from another terminal:"
    printf '      %s %s paste --enter '"'"'curl -sL %s:%s/s | sudo bash'"'"'\n\n' \
        "$0" "$VM" "$HOST_IP" "$SEAL_HTTP_PORT"

    local reported
    reported=$(wait_for_guest_user "${serve_dir}/access.log" 900)
    if [[ -n "$reported" && "$reported" != "$GUEST_USER" ]]; then
        warn "The guest account is '${reported}', not '${GUEST_USER}'."
        info "Continuing with '${reported}'. To make that permanent, set"
        info "GUEST_USER=\"${reported}\" in config/omavm.conf, or every later"
        info "command will keep looking for '${GUEST_USER}'."
        GUEST_USER="$reported"
    fi

    if wait_for_ssh 900; then
        ok "Guest sealed and reachable over SSH"
        info "Next: $0 ${BASE_VM} reboot, then stop and freeze"
    else
        die "Timed out waiting for SSH. Check the seal output in the guest."
    fi
}

cmd_freeze() {
    require_base_vm freeze
    domain_running && die "Shut the build guest down first: $0 ${BASE_VM} stop"
    [[ -f "$DISK_IMAGE" ]] || die "No build disk at $DISK_IMAGE"

    stage "Freezing the build disk into the shared base image"
    if [[ -f "$BASE_IMAGE" ]]; then
        warn "A base image already exists and will be replaced."
        warn "Every VM returns to the new base at its next reset."
        read -r -p "  Replace it? [y/N] " reply
        [[ "$reply" =~ ^[Yy] ]] || die "Aborted."
        sudo chmod 0644 "$BASE_IMAGE"
    fi

    info "Compacting. This takes a few minutes for a desktop install."
    sudo qemu-img convert -O qcow2 -c "$DISK_IMAGE" "${BASE_IMAGE}.tmp"
    sudo mv "${BASE_IMAGE}.tmp" "$BASE_IMAGE"
    sudo chmod 0444 "$BASE_IMAGE"
    ok "Base image written: $(sudo du -h "$BASE_IMAGE" | cut -f1)"

    # The build guest has done its job. Keeping it would hold an address and a
    # 60G writable disk for nothing; `refresh` recreates it when needed.
    stage "Removing the build guest"
    domain_exists && $VIRSH undefine --nvram "$VM_DOMAIN" >/dev/null 2>&1
    sudo rm -f "$DISK_IMAGE" "$NVRAM_FILE"
    unregister_vm "$VM"
    ok "Build guest removed, its address released"
    echo
    info "Create a VM from the new base with:  $0 new <name>"
}

cmd_refresh() {
    require_base_vm refresh
    [[ -f "$BASE_IMAGE" ]] || die "No base image to refresh."
    require_network "$VM_NET"
    stage "Booting a writable copy of the base image for updating"
    domain_running && $VIRSH destroy "$VM_DOMAIN" >/dev/null

    sudo rm -f "$DISK_IMAGE"
    info "Copying the base to a writable image."
    sudo qemu-img convert -O qcow2 "$BASE_IMAGE" "$DISK_IMAGE"
    sudo install -m 0600 -o root -g root "$OVMF_VARS_TEMPLATE" "$NVRAM_FILE"
    define_domain
    $VIRSH start "$VM_DOMAIN" >/dev/null
    ok "Base running at ${VM_IP} with internet access"
    info "Update it: $0 ${BASE_VM} ssh, then 'sudo pacman -Syu' and 'omarchy update'."
    info "When done: $0 ${BASE_VM} stop, then $0 ${BASE_VM} freeze"
}

# --------------------------------------------------------------------------
# per-VM commands
# --------------------------------------------------------------------------
cmd_reset() {
    refuse_base_vm
    [[ -f "$BASE_IMAGE" ]] || die "No base image at $BASE_IMAGE.
    Build one first:  $0 ${BASE_VM} build --iso /path/to/omarchy.iso"

    stage "Resetting ${VM} to the shared base image"
    if domain_running; then
        # Nothing in the overlay is worth preserving, so this is a hard stop
        # rather than a graceful shutdown. That is the point of the command.
        $VIRSH destroy "$VM_DOMAIN" >/dev/null
        ok "Running guest destroyed"
    fi

    sudo rm -f "$DISK_IMAGE"
    sudo qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMAGE" "$DISK_IMAGE" >/dev/null
    ok "Fresh overlay created over the shared base"

    # Resetting the disk alone is not a clean reset. UEFI variables live in a
    # separate file, so boot entries and anything else written to NVRAM would
    # survive.
    sudo install -m 0600 -o root -g root "$OVMF_VARS_TEMPLATE" "$NVRAM_FILE"
    ok "UEFI variables restored from the firmware template"

    define_domain
    info "Start it with: $0 ${VM} start --gui"
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

    [[ -f "$DISK_IMAGE" ]] || die "No disk for ${VM}. Run: $0 ${VM} reset"
    stage "Starting ${VM}"
    require_network "$VM_NET"
    start_proxy

    if domain_running; then
        ok "Already running"
    else
        define_domain
        $VIRSH start "$VM_DOMAIN" >/dev/null
        ok "Started at ${VM_IP} on ${VM_NET} (profile: ${PROFILE})"
    fi
    (( attach )) && cmd_gui
    info "SSH in with: $0 ${VM} ssh"
}

cmd_stop() {
    local force=0
    [[ "${1:-}" == "--force" ]] && force=1
    domain_running || { ok "${VM} is not running"; return; }
    stage "Stopping ${VM}"
    if (( force )); then
        $VIRSH destroy "$VM_DOMAIN" >/dev/null
        ok "Powered off"
    else
        $VIRSH shutdown "$VM_DOMAIN" >/dev/null
        local waited=0
        while domain_running && (( waited < 60 )); do sleep 2; waited=$((waited + 2)); done
        if domain_running; then
            warn "${VM} ignored the shutdown request. Use --force to power it off."
        else
            ok "Shut down cleanly"
        fi
    fi
}

# ACPI goes through the hypervisor, so this works even when sudo in the guest
# would prompt and when the guest agent is not running.
cmd_reboot() {
    domain_running || die "${VM} is not running."
    stage "Rebooting ${VM}"
    $VIRSH reboot "$VM_DOMAIN" >/dev/null || die "Reboot request failed."
    ok "ACPI reboot requested"
    info "Session services such as spice-vdagent and ydotoold start at the next login."
    wait_for_ssh 120 && ok "Guest is back" || warn "SSH did not come back within 120s."
}

cmd_gui() {
    domain_running || die "${VM} is not running."
    command -v virt-viewer &>/dev/null || die "virt-viewer is not installed."
    stage "Attaching a display to ${VM}"
    # --attach is required: with GL enabled the SPICE server has no network
    # listener, so the client gets the socket through libvirt.
    virt-viewer --connect qemu:///system --attach "$VM_DOMAIN" &>/dev/null &
    disown
    ok "virt-viewer launched"
    info "Your pointer enters the guest while this window is focused."
}

cmd_ssh() {
    domain_running || die "${VM} is not running. Run: $0 ${VM} start"
    [[ "${1:-}" == "--" ]] && shift
    # Allocate a terminal only when stdout is one. Without it sudo in the guest
    # has nowhere to prompt; with it unconditionally, a piped command such as
    # `ssh -- omarchy-ui shot -` would have its binary output mangled.
    local -a tty_flag=()
    [[ -t 1 ]] && tty_flag=(-t)
    exec ssh "${tty_flag[@]}" -i "$SSH_KEY" $SSH_OPTS "${GUEST_USER}@${VM_IP}" "$@"
}

# Sixel-capable terminals include ";4" in their Primary Device Attributes
# reply. Guessing from $TERM is not reliable, and drawing sixel at a terminal
# that cannot render it fills the screen with rubbish.
terminal_supports_sixel() {
    [[ -t 1 ]] || return 1
    command -v img2sixel &>/dev/null || return 1
    local reply saved
    exec 3<>/dev/tty 2>/dev/null || return 1
    saved=$(stty -g <&3 2>/dev/null) || { exec 3>&- 3<&-; return 1; }
    stty raw -echo <&3 2>/dev/null
    printf '\e[c' >&3
    IFS= read -r -t 1 -d 'c' reply <&3 2>/dev/null
    stty "$saved" <&3 2>/dev/null
    exec 3>&- 3<&-
    [[ "$reply" == *";4"* ]]
}

cmd_watch() {
    domain_running || die "${VM} is not running."
    local interval=2 mode=auto
    while (( $# )); do
        case "$1" in
            --inline) mode=inline ;;
            --no-inline) mode=file ;;
            *) interval="$1" ;;
        esac
        shift
    done
    local inline=0
    case "$mode" in
        inline) inline=1 ;;
        auto)   terminal_supports_sixel && inline=1 ;;
    esac

    local frame
    frame=$(mktemp -t "omavm-${VM}.XXXXXX.png")
    # A handler that only tidies up does not stop anything: bash runs it and
    # carries on round the loop. It has to exit as well.
    watch_cleanup() { rm -f "$frame" "${frame}.new"; printf '\n'; }
    trap 'watch_cleanup' EXIT
    trap 'watch_cleanup; exit 130' INT
    trap 'watch_cleanup; exit 143' TERM

    stage "Watching ${VM}, a frame every ${interval}s. Ctrl-C to stop."
    info "Your pointer never enters the guest, so the agent keeps the cursor."
    (( inline )) || info "Each frame is written to ${frame}"
    echo

    local width="${OMAVM_WATCH_WIDTH:-900}"
    while true; do
        if guest_frame > "${frame}.new" 2>/dev/null && [[ -s "${frame}.new" ]]; then
            mv "${frame}.new" "$frame"
            if (( inline )); then
                printf '\e[H\e[2J'
                img2sixel -w "$width" "$frame" 2>/dev/null
                printf '\n  %s  %s   Ctrl-C to stop\n' "$(date +%H:%M:%S)" "$VM"
            else
                printf '\r  %s  %s  ' "$(date +%H:%M:%S)" "$frame"
            fi
        else
            printf '\r  %s  no frame. Check: %s %s ssh -- omarchy-ui doctor  ' \
                "$(date +%H:%M:%S)" "$0" "$VM"
        fi
        sleep "$interval"
    done
}

cmd_screenshot() {
    domain_running || die "${VM} is not running."
    local out="${1:-${VM}-$(date +%Y%m%d-%H%M%S).png}"
    guest_frame > "$out" || die "Capture failed. Check: $0 ${VM} ssh -- omarchy-ui doctor"
    [[ -s "$out" ]] || { rm -f "$out"; die "Capture produced an empty file."; }
    ok "Wrote $out ($(du -h "$out" | cut -f1))"
}

# SPICE clipboard sharing does not work with a Hyprland guest: the packaged
# spice-vdagent is an X11 agent and syncs the XWayland clipboard rather than
# the Wayland one. This route goes over SSH and involves SPICE not at all, so
# it works headless with no viewer attached.
cmd_clip() {
    domain_running || die "${VM} is not running."
    case "${1:-pull}" in
        pull)
            command -v wl-copy &>/dev/null || die "wl-copy is not installed on the host."
            local content
            content=$(guest_exec "${OMAVM_UI:-omarchy-ui} clip-get") \
                || die "Could not read the guest clipboard."
            printf '%s' "$content" | wl-copy
            ok "${VM} clipboard copied to the host ($(printf '%s' "$content" | wc -c) bytes)"
            ;;
        push)
            command -v wl-paste &>/dev/null || die "wl-paste is not installed on the host."
            wl-paste --no-newline | guest_exec "${OMAVM_UI:-omarchy-ui} clip-set" \
                || die "Could not set the guest clipboard."
            ok "Host clipboard copied to ${VM}"
            ;;
        *) die "usage: $0 ${VM} clip [pull|push]" ;;
    esac
}

cmd_sync_ui() {
    domain_running || die "${VM} is not running."
    guest_exec true 2>/dev/null || die "${VM} is not reachable over SSH."
    local src="${REPO_DIR}/guest/skills/omarchy-ui" want got
    want=$(sha256sum "${src}/scripts/omarchy-ui" | cut -c1-12)

    stage "Installing the agent tooling into ${VM}"
    scp -q -i "$SSH_KEY" $SSH_OPTS "${src}/scripts/omarchy-ui" "${src}/SKILL.md" \
        "${GUEST_USER}@${VM_IP}:/tmp/" || die "Could not copy the files into the guest."
    info "The guest will ask for the sudo password for ${GUEST_USER}."
    ssh -t -i "$SSH_KEY" $SSH_OPTS "${GUEST_USER}@${VM_IP}" '
        set -e
        sudo install -m 0755 /tmp/omarchy-ui /usr/local/bin/omarchy-ui
        mkdir -p ~/.claude/skills/omarchy-ui
        install -m 0644 /tmp/SKILL.md ~/.claude/skills/omarchy-ui/SKILL.md
        rm -f /tmp/omarchy-ui /tmp/SKILL.md
    ' || die "Installation in the guest failed."

    got=$(guest_exec omarchy-ui build 2>/dev/null || echo none)
    [[ "$got" == "$want" ]] || die "Guest reports build '${got}', repository has '${want}'."
    ok "${VM} is running build ${got}, matching this repository"
    warn "This lasts until the next reset. Re-seal the base to make it permanent."
}

cmd_status() {
    stage "Status of ${VM}"
    printf '  %-20s %s\n' "profile" "$PROFILE"
    local dstate
    dstate=$($VIRSH domstate "$VM_DOMAIN" 2>/dev/null | head -1 || true)
    printf '  %-20s %s\n' "domain" "${dstate:-undefined}"
    printf '  %-20s %s on %s\n' "address" "$VM_IP" "$VM_NET"
    if [[ -n "$SHARE_DIR" ]]; then
        printf '  %-20s %s -> %s%s\n' "file share" "$SHARE_DIR" "$SHARE_MOUNT" \
            "$([[ "$SHARE_READONLY" == "yes" ]] && echo ' (read-only)')"
    else
        printf '  %-20s %s\n' "file share" "disabled"
    fi
    printf '  %-20s %s MB, %s vCPU\n' "sizing" "$VM_MEM_MB" "$VM_VCPUS"
    if [[ -f "$DISK_IMAGE" ]]; then
        printf '  %-20s %s at %s\n' "disk" \
            "$(sudo du -h "$DISK_IMAGE" 2>/dev/null | cut -f1 2>/dev/null || echo '?')" \
            "$(basename "$DISK_IMAGE")"
    else
        printf '  %-20s %s\n' "disk" "missing, run reset"
    fi
}

# --------------------------------------------------------------------------
# typing into a guest that has no agent yet
#
# SPICE clipboard sharing needs spice-vdagent running inside the guest, so it
# cannot work during an install. qemu can inject keystrokes at the virtual
# keyboard, below anything the guest is running, so this works from the
# firmware screen onwards.
#
# Assumes the layout named by KEYBOARD_LAYOUT. Letters and digits are safe on
# any layout; symbols are not.
# --------------------------------------------------------------------------
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
        *) die "Unknown KEYBOARD_LAYOUT '${KEYBOARD_LAYOUT}'. Supported: us, gb." ;;
    esac
}

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

    domain_running || die "${VM} is not running."
    apply_keyboard_layout

    if [[ -z "$text" ]]; then
        if [[ ! -t 0 ]]; then
            text=$(cat)
        elif command -v wl-paste &>/dev/null; then
            text=$(wl-paste --no-newline 2>/dev/null) || die "Could not read the clipboard."
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
        if [[ -z "$codes" ]]; then skipped=$((skipped + 1)); continue; fi
        batch+=("send-key $VM_DOMAIN --holdtime 20 $codes")
    done
    (( press_enter )) && batch+=("send-key $VM_DOMAIN --holdtime 20 KEY_ENTER")
    (( ${#batch[@]} )) || die "Nothing in that text can be typed on that layout."

    if (( dry )); then printf '%s\n' "${batch[@]}"; return; fi

    stage "Typing ${#batch[@]} keystrokes into ${VM}"
    info "Click into the guest window first, so the keys land where you want them."
    local output
    output=$(printf '%s\n' "${batch[@]}" | $VIRSH 2>&1)
    if grep -q '^error:' <<<"$output"; then
        grep '^error:' <<<"$output" | head -3 | sed 's/^/    /'
        die "Some keystrokes were rejected."
    fi
    ok "Sent"
    (( skipped )) && warn "$skipped character(s) skipped: not typeable on ${KEYBOARD_LAYOUT}."
    info "If the punctuation came out wrong, the guest layout is not '${KEYBOARD_LAYOUT}'."
    return 0
}

# --------------------------------------------------------------------------
# commands that act on the set
# --------------------------------------------------------------------------
cmd_new() {
    local name="${1:-}"
    [[ -n "$name" ]] || die "usage: $0 new <name>"
    validate_vm_name "$name"
    [[ "$name" != "$BASE_VM" ]] \
        || die "'${BASE_VM}' is reserved for the build guest. Create it with:
        $0 ${BASE_VM} init"
    vm_registered "$name" && die "A VM named '${name}' already exists."
    [[ -f "$BASE_IMAGE" ]] || die "No base image at $BASE_IMAGE.
    Build one first:  $0 ${BASE_VM} build --iso /path/to/omarchy.iso"

    require_network "$VM_NET"
    stage "Creating ${name}"
    local ip
    ip=$(register_vm "$name")
    ok "Reserved ${ip} on ${VM_NET}"

    resolve_vm "$name"
    sudo qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMAGE" "$DISK_IMAGE" >/dev/null
    sudo install -m 0600 -o root -g root "$OVMF_VARS_TEMPLATE" "$NVRAM_FILE"
    define_domain
    ok "Overlay created over the shared base"
    echo
    info "Start it with:  $0 ${name} start"
    [[ -n "$SHARE_ROOT" ]] && info "Share files by creating: ${SHARE_ROOT}/${name}"
}

cmd_list() {
    require_network "$VM_NET" >/dev/null 2>&1 || true
    local rows
    rows=$(registry)
    if [[ -z "$rows" ]]; then
        echo "No VMs yet. Build the base, then create one:"
        echo "  $0 ${BASE_VM} init"
        echo "  $0 ${BASE_VM} build --iso /path/to/omarchy.iso"
        return
    fi
    printf '  %-20s %-16s %-12s %s\n' NAME ADDRESS STATE DISK
    local name ip state disk
    while IFS=$'\t' read -r name ip; do
        # domstate writes a multi-line error for an undefined domain, which
        # would break the table.
        state=$($VIRSH domstate "omarchy-${name}" 2>/dev/null | head -1 || true)
        [[ -n "$state" ]] || state="undefined"
        if [[ "$name" == "$BASE_VM" ]]; then
            disk="${IMAGE_DIR}/base-build.qcow2"
        else
            disk="${IMAGE_DIR}/${name}-overlay.qcow2"
        fi
        printf '  %-20s %-16s %-12s %s\n' "$name" "$ip" "$state" \
            "$(sudo du -h "$disk" 2>/dev/null | cut -f1 2>/dev/null || echo '-')"
    done <<<"$rows"
    echo
    if [[ -f "$BASE_IMAGE" ]]; then
        printf '  shared base: %s, sealed %s\n' \
            "$(sudo du -h "$BASE_IMAGE" 2>/dev/null | cut -f1 2>/dev/null || echo '?')" \
            "$(sudo stat -c %y "$BASE_IMAGE" 2>/dev/null | cut -d' ' -f1 2>/dev/null || echo '?')"
    else
        printf '  shared base: missing\n'
    fi
}

cmd_rm() {
    local name="${1:-}"
    [[ -n "$name" ]] || die "usage: $0 rm <name>"
    validate_vm_name "$name"
    vm_registered "$name" || die "No VM named '${name}'."

    resolve_vm "$name"
    stage "Removing ${name}"
    printf '  This destroys %s at %s and deletes its disk.\n' "$VM_DOMAIN" "$VM_IP"
    read -r -p "  Type the VM name to confirm: " reply
    [[ "$reply" == "$name" ]] || die "Aborted."

    domain_running && $VIRSH destroy "$VM_DOMAIN" >/dev/null
    domain_exists && $VIRSH undefine --nvram "$VM_DOMAIN" >/dev/null 2>&1
    sudo rm -f "$DISK_IMAGE" "$NVRAM_FILE"
    unregister_vm "$name"
    ssh-keygen -R "$VM_IP" -f "${HOME}/.ssh/known_hosts_omavm" &>/dev/null || true
    ok "Removed ${name} and released ${VM_IP}"
}

cmd_logs() {
    [[ "$PROFILE" == "sandbox" ]] || die "The proxy only runs in the sandbox profile."
    stage "Proxy audit log"
    info "ALLOW and DENY lines show every destination a guest asked for."
    sudo tail -f "$PROXY_LOG"
}

usage() {
    awk 'NR>=3 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
}

# --------------------------------------------------------------------------
main() {
    case "${1:-}" in
        ""|-h|--help|help) usage; exit 0 ;;
    esac
    require_libvirt_access

    # Commands that act on the set take no VM name.
    case "$1" in
        list) shift; cmd_list "$@"; return ;;
        new)  shift; cmd_new  "$@"; return ;;
        rm)   shift; cmd_rm   "$@"; return ;;
        logs) shift; cmd_logs "$@"; return ;;
    esac

    local vm="$1"; shift
    local cmd="${1:-status}"; shift || true

    case "$cmd" in
        init|build|rebuild|seal|freeze|refresh|start|stop|reboot|reset|ssh|gui| \
        watch|screenshot|clip|paste|status)
            resolve_vm "$vm"
            "cmd_${cmd}" "$@"
            ;;
        sync-ui)
            resolve_vm "$vm"
            cmd_sync_ui "$@"
            ;;
        *)
            die "Unknown command '${cmd}' for VM '${vm}'.
    Run '$0 --help' for the list."
            ;;
    esac
}

main "$@"
