#!/usr/bin/env bash
#
# verify-isolation.sh — assert that the sandbox is still a sandbox.
#
# Host-side checks always run. Guest-side checks run when the VM is up and
# reachable over SSH; use --host-only to skip them.
#
# Run this after anything that could move the firewall or the network under
# you: a ufw reload, a libvirt or incus upgrade, a kernel update, or any manual
# edit to the network definitions. It is the check that OPERATIONS.md refers to.
#
# Exit status is 0 only when every check passes.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config/omavm.conf
source "${REPO_DIR}/config/omavm.conf"

VIRSH="virsh --connect qemu:///system"

HOST_ONLY=0
[[ "${1:-}" == "--host-only" ]] && HOST_ONLY=1

# Several checks read root-owned files. Prompt once here rather than repeatedly
# part way through the run.
sudo -v || { echo "This check needs sudo to read the ruleset and the proxy log." >&2; exit 2; }

PASSED=0
FAILED=0

c_reset=$'\033[0m'; c_blue=$'\033[1;34m'
c_green=$'\033[1;32m'; c_red=$'\033[1;31m'; c_grey=$'\033[0;90m'

stage() { printf '\n%s== %s%s\n' "$c_blue" "$1" "$c_reset"; }
pass()  { printf '  %sPASS%s %s\n' "$c_green" "$c_reset" "$1"; PASSED=$((PASSED + 1)); }
fail()  { printf '  %sFAIL%s %s\n' "$c_red" "$c_reset" "$1"; FAILED=$((FAILED + 1));
          [[ -n "${2:-}" ]] && printf '       %s%s%s\n' "$c_grey" "$2" "$c_reset"; }
skip()  { printf '  %sSKIP%s %s\n' "$c_grey" "$c_reset" "$1"; }

guest() {
    ssh -i "$SSH_KEY" $SSH_OPTS -o BatchMode=yes "${GUEST_USER}@${GUEST_IP}" "$@" 2>/dev/null
}

# --------------------------------------------------------------------------
stage "Host: network definition"

if $VIRSH net-dumpxml "$SANDBOX_NET" 2>/dev/null | grep -q '<forward'; then
    fail "$SANDBOX_NET has a <forward> element" \
         "An isolated network must have none. Redefine from libvirt/agent-sandbox-net.xml."
else
    pass "$SANDBOX_NET is isolated, no <forward> element"
fi

if $VIRSH net-dumpxml "$SANDBOX_NET" 2>/dev/null | grep -q "<dns enable='no'"; then
    pass "DNS is disabled on $SANDBOX_NET"
else
    fail "DNS is enabled on $SANDBOX_NET" \
         "A reachable resolver lets an agent tunnel data out in query names."
fi

build_state=$($VIRSH net-info "$BUILD_NET" 2>/dev/null | awk '/Active/{print $2}')
if [[ "$build_state" == "yes" ]]; then
    fail "$BUILD_NET is running" \
         "This network has NAT to the internet. Close it: ./manage-agent-vm.sh close-build"
else
    pass "$BUILD_NET is stopped"
fi

# --------------------------------------------------------------------------
stage "Host: packet filter"

if sudo nft list ruleset 2>/dev/null | grep -E 'masquerade|snat' | grep -q "$SANDBOX_BRIDGE"; then
    fail "A masquerade or SNAT rule references $SANDBOX_BRIDGE" \
         "$(sudo nft list ruleset 2>/dev/null | grep -E 'masquerade|snat' | grep "$SANDBOX_BRIDGE" | head -2)"
else
    pass "No masquerade or SNAT rule for $SANDBOX_BRIDGE"
fi

if command -v ufw &>/dev/null && sudo ufw status 2>/dev/null | head -1 | grep -q active; then
    pass "ufw is active"
    fwd=$(grep -E '^DEFAULT_FORWARD_POLICY' /etc/default/ufw 2>/dev/null | cut -d'"' -f2)
    if [[ "$fwd" == "DROP" ]]; then
        pass "ufw default forward policy is DROP"
    else
        fail "ufw default forward policy is '${fwd:-unset}'" "DROP is the safe value."
    fi
else
    fail "ufw is not active" "Host services are exposed to the guest on the bridge."
fi

# --------------------------------------------------------------------------
stage "Host: proxy"

if systemctl is-active --quiet omavm-agent-proxy; then
    pass "omavm-agent-proxy is running"
    listeners=$(ss -ltnH "sport = :${PROXY_PORT} or sport = :${GATEWAY_PORT}" 2>/dev/null | awk '{print $4}')
    if [[ -z "$listeners" ]]; then
        fail "Proxy is running but not listening on ${PROXY_PORT}/${GATEWAY_PORT}"
    elif echo "$listeners" | grep -qvE "^${HOST_IP}:"; then
        fail "Proxy is listening beyond the sandbox bridge" "$listeners"
    else
        pass "Proxy listens only on ${HOST_IP}"
    fi
else
    skip "omavm-agent-proxy is not running"
fi

perms=$(sudo stat -c '%a' /etc/omavm/credentials.env 2>/dev/null)
if [[ -z "$perms" ]]; then
    skip "No /etc/omavm/credentials.env yet"
elif [[ "$perms" =~ ^0?6[04]0$ ]]; then
    pass "credentials.env permissions are $perms"
else
    fail "credentials.env permissions are $perms" "Expected 640. API keys are readable too widely."
fi

# --------------------------------------------------------------------------
stage "Host: images"

if [[ -f "$BASE_IMAGE" ]]; then
    mode=$(sudo stat -c '%a' "$BASE_IMAGE")
    if [[ "$mode" == "444" ]]; then
        pass "Base image is read-only (444)"
    else
        fail "Base image mode is $mode, not 444" \
             "A writable base means resets do not return to a known state."
    fi
    if [[ -f "$OVERLAY_IMAGE" ]]; then
        backing=$(sudo qemu-img info --output=json "$OVERLAY_IMAGE" 2>/dev/null \
                  | grep -oP '(?<="backing-filename": ")[^"]+')
        if [[ "$backing" == "$BASE_IMAGE" ]]; then
            pass "Overlay is backed by the base image"
        else
            fail "Overlay backing file is '${backing:-none}'" "Expected $BASE_IMAGE"
        fi
    else
        skip "No overlay yet"
    fi
else
    skip "No base image yet"
fi

# --------------------------------------------------------------------------
if (( HOST_ONLY )); then
    stage "Guest checks skipped (--host-only)"
elif ! guest true; then
    stage "Guest checks skipped"
    skip "Guest is not reachable at ${GUEST_IP}. Start it with ./manage-agent-vm.sh start"
else

stage "Guest: escape attempts (each of these must fail inside the guest)"

if guest "timeout 5 bash -c 'echo > /dev/tcp/1.1.1.1/443'"; then
    fail "Guest opened a direct TCP connection to 1.1.1.1:443" "Egress is NOT blocked."
else
    pass "Direct TCP to a public address is blocked"
fi

if guest "timeout 5 bash -c 'echo > /dev/tcp/8.8.8.8/53'"; then
    fail "Guest reached 8.8.8.8:53" "Egress is NOT blocked."
else
    pass "Direct DNS to a public resolver is blocked"
fi

if guest "getent hosts example.com"; then
    fail "Guest resolved example.com" "A working resolver is an exfiltration channel."
else
    pass "Name resolution fails in the guest"
fi

lan_gw=$(ip -4 route show default | awk '{print $3; exit}')
if [[ -n "$lan_gw" ]]; then
    if guest "timeout 5 bash -c 'echo > /dev/tcp/${lan_gw}/80'"; then
        fail "Guest reached the host's LAN router at ${lan_gw}" \
             "The guest can attack your local network."
    else
        pass "Host LAN (${lan_gw}) is unreachable from the guest"
    fi
fi

if guest "timeout 5 bash -c 'echo > /dev/tcp/${HOST_IP}/22'"; then
    fail "Guest reached the host's SSH port" "ufw should block everything but the proxy ports."
else
    pass "Host SSH is unreachable from the guest"
fi

stage "Guest: proxy behaviour"

# A denied CONNECT gives curl no HTTP response to report: it exits 7 with a
# status of 000. The authoritative signal is the DENY line the proxy writes, so
# these checks drive traffic from the guest and then read the audit log.
probe_denied() {
    local target="$1" marker="$2" description="$3"
    local before after
    before=$(sudo cat "$PROXY_LOG" 2>/dev/null | wc -l)
    guest "timeout 15 curl -s -o /dev/null -x http://${HOST_IP}:${PROXY_PORT} ${target} || true" >/dev/null
    after=$(sudo tail -n +"$((before + 1))" "$PROXY_LOG" 2>/dev/null)
    if grep -q "DENY.*${marker}" <<<"$after"; then
        pass "$description"
    else
        fail "$description" "No matching DENY line appeared in $PROXY_LOG"
    fi
}

if systemctl is-active --quiet omavm-agent-proxy; then
    if ! sudo test -r "$PROXY_LOG"; then
        skip "Cannot read $PROXY_LOG, so proxy behaviour was not tested"
    else
        probe_denied "https://this-host-is-not-allowlisted.example/" "not-in-allowlist" \
            "Proxy refuses a host that is not on the allowlist"

        # An allowlist entry naming a private address would otherwise turn the
        # proxy into a route onto the host's own LAN.
        probe_denied "https://192.168.1.1/" "non-global-address\|not-in-allowlist" \
            "Proxy refuses to reach a private address"

        # Positive control: if you have allowlisted anything, it must still work.
        allowed=$(sudo grep -vE '^\s*(#|$)' /etc/omavm/allowlist.conf 2>/dev/null \
                  | awk '{print $1}' | grep -v '^\*' | head -1)
        if [[ -n "$allowed" ]]; then
            if guest "timeout 20 curl -s -o /dev/null -x http://${HOST_IP}:${PROXY_PORT} https://${allowed}/"; then
                pass "Proxy still reaches the allowlisted host ${allowed}"
            else
                fail "Proxy could not reach the allowlisted host ${allowed}" \
                     "The allowlist may be right but the host unreachable. Check the log."
            fi
        else
            skip "Allowlist is empty, so there was no positive control to run"
        fi
    fi
else
    skip "Proxy is not running, so its behaviour was not tested"
fi

fi

# --------------------------------------------------------------------------
stage "Result"
printf '  %d passed, %d failed\n' "$PASSED" "$FAILED"
if (( FAILED )); then
    printf '  %sThe sandbox is not intact. Do not run untrusted agents in it.%s\n' "$c_red" "$c_reset"
    printf '  See OPERATIONS.md, "Isolation verification failed".\n'
    exit 1
fi
printf '  %sSandbox intact.%s\n' "$c_green" "$c_reset"
