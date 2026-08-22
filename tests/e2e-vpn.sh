#!/usr/bin/env bash
#
# WireHole - end to end test of the VPN.
#
# This test answers the question that matters: does a real device connect
# and get working, filtered internet?
#
# The test starts a complete stack, makes client configurations the same way
# a user makes them, and then connects real WireGuard clients. Each client is
# a container that behaves like a phone. The test then checks the traffic of
# each client.
#
# The test covers both VPN back ends, because both ship in this project:
#   wg-easy   - makes the clients through the web API, like a user does.
#   wireguard - makes the clients from the variable WIREGUARD_PEERS.
#
# The test makes more than one client for each back end. A stack that
# connects the first device and fails on the second is a common fault, so
# the test looks for it.
#
# The test is safe to run at any time. It uses a temporary directory, its own
# Docker network, and its own ports. It never touches your stack, your file
# ".env", or your directory "./data".
#
# HOW TO USE THIS SCRIPT:
#   ./tests/e2e-vpn.sh                     # Test both back ends.
#   ./tests/e2e-vpn.sh --profile wg-easy   # Test one back end.
#   ./tests/e2e-vpn.sh --keep              # Keep everything after a failure.
#   ./tests/e2e-vpn.sh --remote Devin@192.168.1.120
#                                          # Also connect from another
#                                          # computer on your network. This
#                                          # is the most realistic test.
#   ./tests/e2e-vpn.sh --help
#
# The script gives exit code 0 when all tests pass.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEEP=0
REMOTE=""
PROFILES="wg-easy wireguard"
WORK_DIR=""
PROJECT=""
CLIENTS=()
HOST_CLIENT=""
HOST_INTERFACE=""

TEST_VPN_PORT=51900
TEST_SUBNET="10.99.0.0/24"
TEST_WG_EASY_SUBNET="10.97.0.0/24"
TEST_PIHOLE_IP="10.99.0.100"
TEST_UNBOUND_IP="10.99.0.200"
TEST_UI_PORT=18081
TEST_PIHOLE_PORT=18080
TEST_PASSWORD="e2e-test-password-1234"

PASS=0
FAIL=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep) KEEP=1 ;;
        --remote)
            shift
            REMOTE="${1:-}"
            [[ -z $REMOTE ]] && {
                echo "Error: --remote needs a value like user@192.168.1.120." >&2
                exit 1
            }
            ;;
        --profile)
            shift
            PROFILES="${1:-}"
            [[ -z $PROFILES ]] && {
                echo "Error: --profile needs a value." >&2
                exit 1
            }
            ;;
        -h | --help)
            sed -n '2,/^$/ { s/^# \{0,1\}//; p; }' "$0"
            exit 0
            ;;
        *)
            echo "Error: unknown option '$1'. Use --help." >&2
            exit 1
            ;;
    esac
    shift
done

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
head2() { printf '\n  \033[1m%s\033[0m\n' "$*"; }
ok() {
    printf '    [ PASS ] %s\n' "$*"
    PASS=$((PASS + 1))
}
bad() {
    printf '    [ FAIL ] %s\n' "$*"
    FAIL=$((FAIL + 1))
}
info() { printf '    ....... %s\n' "$*"; }

REMOTE_ACTIVE=""

host_cleanup() {
    [[ -z ${HOST_INTERFACE:-} ]] && return 0

    if [[ -n ${HOST_CLIENT:-} ]] && docker inspect "$HOST_CLIENT" > /dev/null 2>&1; then
        docker exec "$HOST_CLIENT" wg-quick down "$HOST_INTERFACE" > /dev/null 2>&1 || true
        docker exec "$HOST_CLIENT" ip link del "$HOST_INTERFACE" > /dev/null 2>&1 || true
        docker rm -f "$HOST_CLIENT" > /dev/null 2>&1 || true
    fi

    # A killed host-network container can leave the interface in the host
    # namespace. Make a final best-effort removal, including after Ctrl-C.
    if ip link show "$HOST_INTERFACE" > /dev/null 2>&1; then
        ip link del "$HOST_INTERFACE" > /dev/null 2>&1 \
            || sudo -n ip link del "$HOST_INTERFACE" > /dev/null 2>&1 \
            || true
    fi
    HOST_CLIENT=""
    HOST_INTERFACE=""
}

teardown() {
    # The option --keep stops all clean up, so a failure can be examined.
    [[ $KEEP -eq 1 ]] && return 0
    host_cleanup
    for c in "${CLIENTS[@]:-}"; do
        [[ -n $c ]] && docker rm -f "$c" > /dev/null 2>&1
    done
    CLIENTS=()
    if [[ -n $WORK_DIR && -d $WORK_DIR ]]; then
        (cd "$WORK_DIR" && docker compose -p "$PROJECT" --profile wireguard --profile wg-easy down -v > /dev/null 2>&1)
        sudo rm -rf "$WORK_DIR" > /dev/null 2>&1 || rm -rf "$WORK_DIR" > /dev/null 2>&1
    fi
    WORK_DIR=""
}

# The trap below calls this function. Old shellcheck versions use the
# code SC2317 for this case, new versions use SC2329. Disable both.
# shellcheck disable=SC2317,SC2329
cleanup() {
    local code=$?
    # A private key on another machine must never stay behind, also not
    # with --keep and also not after Ctrl-C.
    if [[ -n ${REMOTE_ACTIVE:-} ]] && declare -f remote_cleanup > /dev/null; then
        remote_cleanup
    fi
    # Never keep a host-network interface because it can change the routing
    # of the developer's computer.
    host_cleanup
    if [[ $KEEP -eq 1 && -n $WORK_DIR ]]; then
        say "The option --keep is active. The test keeps these items:"
        echo "  Directory: $WORK_DIR"
        echo "  Clients:   ${CLIENTS[*]:-none}"
        echo "  Remove them with:"
        echo "    docker rm -f ${CLIENTS[*]:-}"
        echo "    (cd $WORK_DIR && docker compose -p $PROJECT --profile wg-easy --profile wireguard down -v)"
        echo "    sudo rm -rf $WORK_DIR"
        return "$code"
    fi
    teardown
    return "$code"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Build a stack in a temporary directory.
# ---------------------------------------------------------------------------
start_stack() {
    local profile="$1" peers="${2:-}"
    local stack_subnet="${3:-$TEST_SUBNET}"
    local stack_pihole_ip="${4:-$TEST_PIHOLE_IP}"
    local stack_unbound_ip="${5:-$TEST_UNBOUND_IP}"

    WORK_DIR="$(mktemp -d)"
    PROJECT="wirehole-e2e-$$-${profile}"
    cp "$REPO_DIR/docker-compose.yml" "$WORK_DIR/"
    cp -r "$REPO_DIR/unbound" "$WORK_DIR/"
    cp "$REPO_DIR/.env.example" "$WORK_DIR/"
    cp "$WORK_DIR/.env.example" "$WORK_DIR/.env"

    # The compose file gives the network and the containers fixed names.
    # A test with those names would join the network of a live stack and
    # collide with its containers. Remove them from the copy. Docker
    # Compose then makes unique names from the project name, and the test
    # can run on a machine with a running stack.
    sed -i '/^    name: wirehole$/d; /container_name:/d' "$WORK_DIR/docker-compose.yml"

    set_var() {
        VALUE="$2" awk -v key="$1" '
            BEGIN { FS = "=" }
            $1 == key && substr($0, 1, 1) != "#" { print key "=" ENVIRON["VALUE"]; next }
            { print }
        ' "$WORK_DIR/.env" > "$WORK_DIR/.env.tmp" && mv "$WORK_DIR/.env.tmp" "$WORK_DIR/.env"
    }

    set_var COMPOSE_PROFILES "$profile"
    set_var VPN_HOST "127.0.0.1"
    set_var VPN_PORT "$TEST_VPN_PORT"
    set_var PIHOLE_PASSWORD "$TEST_PASSWORD"
    set_var WG_EASY_PASSWORD "$TEST_PASSWORD"
    set_var WIREHOLE_SUBNET "$stack_subnet"
    set_var VPN_SUBNET "$TEST_WG_EASY_SUBNET"
    set_var PIHOLE_IPV4_ADDRESS "$stack_pihole_ip"
    set_var UNBOUND_IPV4_ADDRESS "$stack_unbound_ip"
    set_var WIREGUARD_INTERNAL_SUBNET "10.98.13.0"
    set_var PIHOLE_WEB_PORT "$TEST_PIHOLE_PORT"
    set_var WG_EASY_UI_PORT "$TEST_UI_PORT"
    set_var WEB_BIND_ADDRESS "127.0.0.1"
    [[ -n $peers ]] && set_var WIREGUARD_PEERS "$peers"

    (cd "$WORK_DIR" && docker compose -p "$PROJECT" up -d --wait --wait-timeout 240) > /tmp/e2e-up.log 2>&1
}

# ---------------------------------------------------------------------------
# Connect one real WireGuard client and test its traffic.
#   $1 = a name for the report
#   $2 = the client configuration
#   $3 = the address of the server inside the tunnel
# ---------------------------------------------------------------------------
connect_and_test_client() {
    local label="$1" conf="$2" server_vpn_ip="$3" endpoint="${4:-}"
    local dns_ip="${5:-$TEST_PIHOLE_IP}"
    local suffix name
    suffix="$(tr -dc 'a-z0-9' <<< "$label" | head -c 12)"
    name="wirehole-e2e-client-$$-${suffix}"
    CLIENTS+=("$name")

    head2 "Client '$label'"

    # By default the client reaches the server through the Docker gateway.
    # The caller can give another address, such as the address of this
    # server on the local network.
    if [[ -z $endpoint ]]; then
        endpoint="$(docker network inspect bridge -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2> /dev/null)"
        [[ -z $endpoint ]] && endpoint="172.17.0.1"
    fi
    info "$label: connects to ${endpoint}:${TEST_VPN_PORT}"
    conf="$(sed -E "s|^ *Endpoint *=.*|Endpoint = ${endpoint}:${TEST_VPN_PORT}|" <<< "$conf")"

    docker rm -f "$name" > /dev/null 2>&1
    # The client runs with full rights, like a real phone that controls its
    # own network settings. The WireHole services never need this.
    docker run -d --name "$name" --privileged \
        --sysctl net.ipv4.conf.all.src_valid_mark=1 \
        -v /lib/modules:/lib/modules:ro \
        --entrypoint sleep alpine:3.20 infinity > /dev/null 2>&1

    if ! docker exec "$name" apk add --no-cache \
        wireguard-tools iproute2 iptables ip6tables bind-tools curl > /dev/null 2>&1; then
        bad "$label: could not install the client tools"
        return 1
    fi

    docker exec -i "$name" sh -c 'cat > /etc/wireguard/wg0.conf' <<< "$conf"
    # wg-quick would need resolvconf for the DNS line. The test asks the DNS
    # server directly instead, which is a stronger check.
    docker exec "$name" sh -c 'sed -i "/^ *DNS *=/d" /etc/wireguard/wg0.conf'

    if docker exec "$name" wg-quick up wg0 > /tmp/e2e-wgup.log 2>&1; then
        ok "$label: the VPN interface started"
    else
        bad "$label: the VPN interface did not start"
        tail -5 /tmp/e2e-wgup.log
        return 1
    fi

    # A handshake proves that both ends agree on the keys and can reach each
    # other. This is the single most important check in this file.
    local handshake=0
    for _ in $(seq 1 15); do
        docker exec "$name" ping -c1 -W2 "$server_vpn_ip" > /dev/null 2>&1
        if [[ "$(docker exec "$name" wg show wg0 latest-handshakes 2> /dev/null | awk '{print $2}')" != "0" ]]; then
            handshake=1
            break
        fi
        sleep 2
    done

    if [[ $handshake -eq 1 ]]; then
        ok "$label: the VPN handshake succeeded"
    else
        bad "$label: no handshake, the client cannot reach the server"
        docker exec "$name" wg show 2>&1 | head -6
        return 1
    fi

    if docker exec "$name" ping -c2 -W3 "$server_vpn_ip" > /dev/null 2>&1; then
        ok "$label: traffic passes through the tunnel"
    else
        bad "$label: no traffic through the tunnel"
    fi

    local r
    r="$(docker exec "$name" dig +short +time=8 example.com @"$dns_ip" 2> /dev/null | head -1)"
    if [[ $r =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        ok "$label: resolves names through Pi-hole ($r)"
    else
        bad "$label: cannot use Pi-hole through the tunnel"
    fi

    r="$(docker exec "$name" dig +short +time=8 doubleclick.net @"$dns_ip" 2> /dev/null | head -1)"
    if [[ $r == "0.0.0.0" ]]; then
        ok "$label: advertisements are blocked"
    else
        bad "$label: an advertisement domain was not blocked (got '$r')"
    fi

    if docker exec "$name" curl -s --max-time 15 https://api.ipify.org > /dev/null 2>&1; then
        ok "$label: reaches the internet through the tunnel"
    else
        info "$label: no internet. Check the egress of this host."
    fi

    docker rm -f "$name" > /dev/null 2>&1
    return 0
}

# ---------------------------------------------------------------------------
# Find the address of this server on the local network. A phone on your
# Wi-Fi uses this address to reach the server.
# ---------------------------------------------------------------------------
lan_address() {
    ip -4 route get 1.1.1.1 2> /dev/null \
        | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}'
}

# ---------------------------------------------------------------------------
# Connect a client from the network of this computer, and not from a Docker
# network. The container shares the network of the host, so the connection
# starts in the same place as a connection from any program on this server.
#
# This test uses a narrow AllowedIPs value on purpose. It routes only the VPN
# networks into the tunnel. A full tunnel would move the default route of
# this computer, and that would interrupt your other work.
# ---------------------------------------------------------------------------
connect_host_client() {
    local conf="$1" server_vpn_ip="$2" endpoint="$3"
    local iface="whe2e0"
    local name="wirehole-e2e-host-$$"

    head2 "A client on the network of this computer"

    if ip link show "$iface" > /dev/null 2>&1; then
        bad "The interface $iface exists already. The test does not touch it."
        return 1
    fi

    conf="$(sed -E "s|^ *Endpoint *=.*|Endpoint = ${endpoint}:${TEST_VPN_PORT}|" <<< "$conf")"
    # Route only the network of the VPN clients into the tunnel.
    # The Docker network of the stack must stay out of this list. This
    # computer already has a direct route to it, and a second route for the
    # same network fails with "File exists".
    conf="$(sed -E "s|^ *AllowedIPs *=.*|AllowedIPs = ${TEST_WG_EASY_SUBNET}, 10.98.13.0/24|" <<< "$conf")"
    conf="$(sed -E "/^ *DNS *=/d" <<< "$conf")"

    CLIENTS+=("$name")
    HOST_CLIENT="$name"
    HOST_INTERFACE="$iface"
    docker run -d --name "$name" --network host --privileged \
        -v /lib/modules:/lib/modules:ro \
        --entrypoint sleep alpine:3.20 infinity > /dev/null 2>&1

    if ! docker exec "$name" apk add --no-cache \
        wireguard-tools iproute2 iptables bind-tools > /dev/null 2>&1; then
        bad "Could not install the client tools."
        host_cleanup
        return 1
    fi

    docker exec -i "$name" sh -c "cat > /etc/wireguard/${iface}.conf" <<< "$conf"

    if docker exec "$name" wg-quick up "$iface" > /tmp/e2e-hostwg.log 2>&1; then
        ok "The interface started on this computer, not in a Docker network"
    else
        bad "The interface did not start on this computer"
        tail -5 /tmp/e2e-hostwg.log
        host_cleanup
        return 1
    fi

    local handshake=0
    for _ in $(seq 1 15); do
        docker exec "$name" ping -c1 -W2 "$server_vpn_ip" > /dev/null 2>&1
        if [[ "$(docker exec "$name" wg show "$iface" latest-handshakes 2> /dev/null | awk '{print $2}')" != "0" ]]; then
            handshake=1
            break
        fi
        sleep 2
    done

    if [[ $handshake -eq 1 ]]; then
        ok "The handshake succeeded from this computer"
    else
        bad "No handshake from this computer"
    fi

    if docker exec "$name" ping -c2 -W3 "$server_vpn_ip" > /dev/null 2>&1; then
        ok "Traffic passes through the tunnel from this computer"
    else
        bad "No traffic through the tunnel from this computer"
    fi

    # This test does not send DNS through the tunnel. This computer already
    # has a direct route to the Docker network of Pi-hole, so a DNS answer
    # would not prove that the tunnel carried it. The client tests above
    # cover DNS through the tunnel.
    info "DNS through the tunnel is covered by the client tests above."

    # Always remove the interface. It lives on this computer, not in a
    # container, so it must not stay behind.
    host_cleanup

    if ip link show "$iface" > /dev/null 2>&1; then
        bad "The interface $iface stayed on this computer. Remove it with: sudo ip link del $iface"
    else
        ok "The test removed the interface from this computer"
    fi
}

# ---------------------------------------------------------------------------
# Connect from another computer on your network, through SSH.
#
# This is the most realistic test in this file. The traffic leaves this
# server, crosses your network, and comes back. No other test does that.
#
# The other computer needs:
#   - An SSH login that works without a password prompt.
#   - The package "wireguard-tools".
#   - The right to run "sudo wg-quick" without a password prompt.
#
# The test uses a narrow AllowedIPs value, so it never moves the default
# route of the other computer.
# ---------------------------------------------------------------------------
connect_remote_client() {
    local target="$1" conf="$2" server_vpn_ip="$3" endpoint="$4"
    local iface="whe2e0"

    head2 "A client on another computer ($target)"

    local ssh_opts=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

    if ! timeout 20 ssh "${ssh_opts[@]}" "$target" true > /dev/null 2>&1; then
        bad "Cannot log in to $target without a password."
        fix_hint "Copy your key first: ssh-copy-id $target"
        return 1
    fi
    ok "SSH to $target works"

    if ! timeout 20 ssh "${ssh_opts[@]}" "$target" 'command -v wg-quick' > /dev/null 2>&1; then
        bad "$target does not have wg-quick."
        fix_hint "Install it there: sudo apt install -y wireguard-tools"
        return 1
    fi
    ok "$target has the WireGuard tools"

    if ! timeout 20 ssh "${ssh_opts[@]}" "$target" 'sudo -n true' > /dev/null 2>&1; then
        bad "$target asks for a password for sudo. The test cannot make an interface."
        return 1
    fi

    # Can the other computer reach the VPN port at all?
    if timeout 20 ssh "${ssh_opts[@]}" "$target" \
        "command -v nc >/dev/null 2>&1 && timeout 3 nc -zu ${endpoint} ${TEST_VPN_PORT}" > /dev/null 2>&1; then
        ok "$target can send UDP to ${endpoint}:${TEST_VPN_PORT}"
    else
        info "Could not confirm the UDP path first. The handshake test decides."
    fi

    conf="$(sed -E "s|^ *Endpoint *=.*|Endpoint = ${endpoint}:${TEST_VPN_PORT}|" <<< "$conf")"
    conf="$(sed -E "s|^ *AllowedIPs *=.*|AllowedIPs = ${TEST_WG_EASY_SUBNET}, 10.98.13.0/24|" <<< "$conf")"
    conf="$(sed -E "/^ *DNS *=/d" <<< "$conf")"

    # Always remove the interface on the other computer, also after a fault
    # or an interrupt. The global clean up calls this too.
    REMOTE_ACTIVE="$target"
    remote_cleanup() {
        [[ -z ${REMOTE_ACTIVE:-} ]] && return 0
        timeout 25 ssh "${ssh_opts[@]}" "$REMOTE_ACTIVE" \
            "sudo wg-quick down /tmp/${iface}.conf >/dev/null 2>&1; sudo ip link del ${iface} >/dev/null 2>&1; rm -f /tmp/${iface}.conf" \
            > /dev/null 2>&1
        REMOTE_ACTIVE=""
    }

    # Write the file with a private permission from the first moment.
    # The file holds a private key.
    # shellcheck disable=SC2029 # ${iface} must expand here, on this side.
    if ! ssh "${ssh_opts[@]}" "$target" "umask 077 && cat > /tmp/${iface}.conf" <<< "$conf"; then
        bad "Could not copy the configuration to $target."
        return 1
    fi

    if timeout 40 ssh "${ssh_opts[@]}" "$target" "sudo wg-quick up /tmp/${iface}.conf" > /tmp/e2e-remote.log 2>&1; then
        ok "The VPN interface started on $target"
    else
        bad "The VPN interface did not start on $target"
        tail -5 /tmp/e2e-remote.log
        remote_cleanup
        return 1
    fi

    local handshake=0
    for _ in $(seq 1 15); do
        timeout 15 ssh "${ssh_opts[@]}" "$target" "ping -c1 -W2 ${server_vpn_ip}" > /dev/null 2>&1
        local hs
        hs="$(timeout 15 ssh "${ssh_opts[@]}" "$target" "sudo wg show ${iface} latest-handshakes 2>/dev/null | awk '{print \$2}'" 2> /dev/null)"
        if [[ -n $hs && $hs != "0" ]]; then
            handshake=1
            break
        fi
        sleep 2
    done

    if [[ $handshake -eq 1 ]]; then
        ok "The handshake succeeded from another computer on your network"
    else
        bad "No handshake from $target. Your network blocks the path, or the port is closed."
    fi

    if timeout 20 ssh "${ssh_opts[@]}" "$target" "ping -c2 -W3 ${server_vpn_ip}" > /dev/null 2>&1; then
        ok "Traffic passes through the tunnel from $target"
    else
        bad "No traffic through the tunnel from $target"
    fi

    remote_cleanup

    if timeout 20 ssh "${ssh_opts[@]}" "$target" "ip link show ${iface}" > /dev/null 2>&1; then
        bad "The interface stayed on $target. Remove it with: sudo ip link del ${iface}"
    else
        ok "The test removed the interface from $target"
    fi
}

fix_hint() { printf '             -> %s\n' "$*"; }

# ---------------------------------------------------------------------------
test_dns_chain() {
    head2 "The DNS chain on the server"
    local c r
    c="$(cd "$WORK_DIR" && docker compose -p "$PROJECT" ps -q pihole | head -1)"

    r="$(docker exec "$c" dig +short +time=8 example.com @127.0.0.1 2> /dev/null | head -1)"
    if [[ $r =~ ^[0-9]+\. ]]; then
        ok "Pi-hole resolves a name ($r)"
    else
        bad "Pi-hole does not resolve a name"
    fi

    r="$(docker exec "$c" dig +short +time=8 wikipedia.org @"$TEST_UNBOUND_IP" 2> /dev/null | head -1)"
    if [[ -n $r ]]; then
        ok "Unbound resolves by recursion ($r)"
    else
        bad "Unbound does not answer"
    fi

    if docker exec "$c" dig +dnssec +time=8 cloudflare.com @"$TEST_UNBOUND_IP" 2> /dev/null | grep -q '^;; flags.* ad'; then
        ok "Unbound validates a signed answer"
    else
        bad "Unbound did not set the 'ad' flag"
    fi

    if docker exec "$c" dig +time=8 dnssec-failed.org @"$TEST_UNBOUND_IP" 2> /dev/null | grep -q 'status: SERVFAIL'; then
        ok "Unbound refuses a bad signature"
    else
        bad "Unbound accepted a bad signature"
    fi
}

# ---------------------------------------------------------------------------
run_wg_easy() {
    say "Back end 'wg-easy' (the default)"

    if ! start_stack wg-easy; then
        bad "The stack did not start"
        tail -20 /tmp/e2e-up.log
        return 1
    fi
    ok "The stack started and reports healthy"

    test_dns_chain

    head2 "Make clients through the web API"
    local jar=/tmp/e2e-cookies-$$.txt
    rm -f "$jar"
    local base="http://127.0.0.1:${TEST_UI_PORT}"

    local code
    code="$(curl -s -c "$jar" -o /tmp/e2e-login.json -w '%{http_code}' --max-time 15 \
        -X POST "$base/api/auth/password" -H 'Content-Type: application/json' \
        -d "{\"username\":\"admin\",\"password\":\"${TEST_PASSWORD}\",\"remember\":false}")"
    if [[ $code == "200" ]]; then
        ok "Signed in to the web API with the password from .env"
    else
        bad "Could not sign in (HTTP $code). The INIT_PASSWORD was not applied."
        head -c 300 /tmp/e2e-login.json
        return 1
    fi

    # Make two clients. A stack that works for one device and fails for the
    # second is a common fault.
    local made=0
    for cname in phone laptop; do
        code="$(curl -s -b "$jar" -o /tmp/e2e-create.json -w '%{http_code}' --max-time 15 \
            -X POST "$base/api/client" -H 'Content-Type: application/json' \
            -d "{\"name\":\"${cname}\",\"expiresAt\":null}")"
        if [[ $code == "200" || $code == "201" ]]; then
            ok "Made the client '$cname' through the API"
            made=$((made + 1))
        else
            bad "Could not make the client '$cname' (HTTP $code)"
            head -c 300 /tmp/e2e-create.json
        fi
    done
    [[ $made -eq 0 ]] && return 1

    local list
    list="$(curl -s -b "$jar" --max-time 15 "$base/api/client")"
    local ids
    ids="$(python3 -c "
import json,sys
try:
    d=json.loads(sys.argv[1])
except Exception:
    sys.exit()
for c in d:
    print(c.get('id',''), c.get('name',''), c.get('ipv4Address',''))
" "$list" 2> /dev/null)"

    if [[ -z $ids ]]; then
        bad "The API returned no clients"
        return 1
    fi
    ok "The API lists $(wc -l <<< "$ids") clients"

    # Use a non-default subnet. This catches a wg-easy v15 initialization
    # requirement: it ignores INIT_IPV4_CIDR unless INIT_IPV6_CIDR is present.
    local expected_prefix="${TEST_WG_EASY_SUBNET%0/24}"
    if awk '{print $3}' <<< "$ids" | grep -qv "^${expected_prefix}"; then
        bad "wg-easy ignored VPN_SUBNET=$TEST_WG_EASY_SUBNET"
    else
        ok "wg-easy assigned every client from $TEST_WG_EASY_SUBNET"
    fi

    # The server holds the first address of the client network.
    local server_ip
    server_ip="$(awk '{print $3}' <<< "$ids" | head -1 | awk -F. '{print $1"."$2"."$3".1"}')"
    if [[ $server_ip == "${expected_prefix}1" ]]; then
        ok "wg-easy listens on the custom VPN address $server_ip"
    else
        bad "wg-easy has the unexpected VPN address '$server_ip'"
    fi

    local first_conf=""
    while read -r id cname _addr; do
        [[ -z $id ]] && continue
        local conf
        conf="$(curl -s -b "$jar" --max-time 15 "$base/api/client/${id}/configuration")"
        if grep -q '\[Interface\]' <<< "$conf"; then
            ok "Downloaded the configuration for '$cname'"
        else
            bad "Could not download the configuration for '$cname'"
            continue
        fi
        if grep -Eq "^Address[[:space:]]*=[[:space:]]*${expected_prefix}[0-9]+/" <<< "$conf"; then
            ok "'$cname' received the custom IPv4 subnet"
        else
            bad "'$cname' did not receive the custom IPv4 subnet"
        fi
        if grep -Eq '^Address[[:space:]]*=.*:' <<< "$conf"; then
            bad "'$cname' received an IPv6 address even though IPv6 is disabled"
        else
            ok "'$cname' received no unusable IPv6 address"
        fi
        if grep -Eq '^AllowedIPs[[:space:]]*=.*::/0' <<< "$conf"; then
            ok "'$cname' sends IPv6 into the tunnel to prevent leaks"
        else
            bad "'$cname' can leak IPv6 outside the tunnel"
        fi
        [[ -z $first_conf ]] && first_conf="$conf"
        connect_and_test_client "$cname" "$conf" "$server_ip"
    done <<< "$ids"

    # A phone on your Wi-Fi does not use the Docker gateway. It uses the
    # address of this server on the local network. Test that path too,
    # because it proves that the published port answers on a real interface.
    local lan
    lan="$(lan_address)"
    if [[ -n $lan && -n $first_conf ]]; then
        head2 "Reach the server on the local network ($lan)"
        code="$(curl -s -b "$jar" -o /tmp/e2e-create.json -w '%{http_code}' --max-time 15 \
            -X POST "$base/api/client" -H 'Content-Type: application/json' \
            -d '{"name":"wifi","expiresAt":null}')"
        local wifi_conf=""
        if [[ $code == "200" || $code == "201" ]]; then
            local wifi_id
            wifi_id="$(curl -s -b "$jar" --max-time 15 "$base/api/client" \
                | python3 -c "
import json,sys
for c in json.load(sys.stdin):
    if c.get('name') == 'wifi':
        print(c.get('id',''))
        break
" 2> /dev/null)"
            [[ -n $wifi_id ]] && wifi_conf="$(curl -s -b "$jar" --max-time 15 "$base/api/client/${wifi_id}/configuration")"
        fi
        if [[ -n $wifi_conf ]]; then
            connect_and_test_client "wifi" "$wifi_conf" "$server_ip" "$lan"
            connect_host_client "$wifi_conf" "$server_ip" "$lan"
            [[ -n $REMOTE ]] && connect_remote_client "$REMOTE" "$wifi_conf" "$server_ip" "$lan"
        else
            info "Could not make the client for the local network test."
        fi
    else
        info "No local network address found. The test skips that check."
    fi

    rm -f "$jar"
    teardown
}

# ---------------------------------------------------------------------------
run_wireguard() {
    say "Back end 'wireguard'"

    if ! start_stack wireguard "phone,laptop"; then
        bad "The stack did not start"
        tail -20 /tmp/e2e-up.log
        return 1
    fi
    ok "The stack started and reports healthy"

    test_dns_chain

    head2 "Read the client configurations from the server"
    local c
    c="$(cd "$WORK_DIR" && docker compose -p "$PROJECT" ps -q wireguard | head -1)"

    for cname in phone laptop; do
        local conf=""
        for _ in $(seq 1 30); do
            conf="$(docker exec "$c" cat "/config/peer_${cname}/peer_${cname}.conf" 2> /dev/null)"
            [[ -n $conf ]] && break
            sleep 2
        done

        if [[ -n $conf ]]; then
            ok "The server wrote the configuration for '$cname'"
        else
            bad "The server did not write the configuration for '$cname'"
            continue
        fi

        if grep -q "^DNS = ${TEST_PIHOLE_IP}" <<< "$conf"; then
            ok "'$cname' uses Pi-hole for DNS"
        else
            bad "'$cname' has the wrong DNS server"
        fi

        connect_and_test_client "$cname" "$conf" "10.98.13.1"
    done

    teardown
}

# ---------------------------------------------------------------------------
# Start a real LinuxServer installation, reshape it into the legacy on-disk
# layout, migrate it, and reconnect with the exact old client configuration.
# This proves that migration does not regenerate the server or peer keys.
# ---------------------------------------------------------------------------
run_migration() {
    say "Migration from the legacy LinuxServer layout"

    # The old Compose file hardcoded this Docker network and Pi-hole address.
    # Use the real legacy topology so the old client DNS setting remains valid
    # after migration to the new defaults.
    if ! start_stack wireguard "legacy" "10.2.0.0/24" "10.2.0.100" "10.2.0.200"; then
        bad "The migration fixture did not start"
        tail -20 /tmp/e2e-up.log
        return 1
    fi

    local container old_conf="" old_public=""
    container="$(cd "$WORK_DIR" && docker compose -p "$PROJECT" ps -q wireguard | head -1)"
    for _ in $(seq 1 30); do
        old_conf="$(docker exec "$container" cat /config/peer_legacy/peer_legacy.conf 2> /dev/null)"
        old_public="$(docker exec "$container" wg show wg0 public-key 2> /dev/null)"
        [[ -n $old_conf && -n $old_public ]] && break
        sleep 2
    done
    if [[ -z $old_conf || -z $old_public ]]; then
        bad "The migration fixture did not generate its keys"
        teardown
        return 1
    fi
    ok "Made a legacy server and client configuration"

    (cd "$WORK_DIR" && docker compose -p "$PROJECT" down) > /dev/null 2>&1
    # Docker creates the bind-mount parent as root on a fresh runner. Use
    # sudo only for this fixture reshaping; the migration itself must handle
    # the legacy ownership in the same way a user's installation does.
    sudo mv "$WORK_DIR/data/wireguard" "$WORK_DIR/config"
    sudo mv "$WORK_DIR/data/pihole" "$WORK_DIR/etc-pihole"
    sudo rmdir "$WORK_DIR/data" 2> /dev/null || true
    mkdir -p "$WORK_DIR/scripts"
    cp "$REPO_DIR/scripts/migrate-from-v1.sh" "$WORK_DIR/scripts/"
    chmod +x "$WORK_DIR/scripts/migrate-from-v1.sh"

    # These two values existed in the old sample .env but were never passed
    # to the old WireGuard container. Deliberately make them wrong: migration
    # must use the active peer endpoint and preserve the existing peer files.
    {
        printf 'WEBPASSWORD=%s\n' "$TEST_PASSWORD"
        printf 'TIMEZONE=Etc/UTC\n'
        printf 'WIREGUARD_SERVER_PORT=52099\n'
        printf 'WIREGUARD_PEERS=99\n'
    } > "$WORK_DIR/.env"

    if (cd "$WORK_DIR" && ./scripts/migrate-from-v1.sh) > /tmp/e2e-migration.log 2>&1; then
        ok "The migration script completed"
    else
        bad "The migration script failed"
        tail -30 /tmp/e2e-migration.log
        teardown
        return 1
    fi

    local migrated_port
    migrated_port="$(awk -F= '$1 == "VPN_PORT" { print $2 }' "$WORK_DIR/.env")"
    if [[ $migrated_port == "$TEST_VPN_PORT" ]]; then
        ok "Migration kept the active endpoint port"
    else
        bad "Migration used port '$migrated_port' instead of the active port '$TEST_VPN_PORT'"
    fi
    if grep -qx 'WIREGUARD_PEERS=' "$WORK_DIR/.env"; then
        ok "Migration selected key-preservation mode"
    else
        bad "Migration could regenerate the existing peer keys"
    fi

    if (cd "$WORK_DIR" && docker compose -p "$PROJECT" up -d --wait --wait-timeout 240) \
        > /tmp/e2e-migrated-up.log 2>&1; then
        ok "The migrated stack started"
    else
        bad "The migrated stack did not start"
        tail -30 /tmp/e2e-migrated-up.log
        teardown
        return 1
    fi

    container="$(cd "$WORK_DIR" && docker compose -p "$PROJECT" ps -q wireguard | head -1)"
    local new_public new_conf
    new_public="$(docker exec "$container" wg show wg0 public-key 2> /dev/null)"
    new_conf="$(docker exec "$container" cat /config/peer_legacy/peer_legacy.conf 2> /dev/null)"
    if [[ $new_public == "$old_public" ]]; then
        ok "Migration preserved the server public key"
    else
        bad "Migration changed the server key"
    fi
    if [[ $new_conf == "$old_conf" ]]; then
        ok "Migration preserved the exact client configuration"
    else
        bad "Migration changed the existing client configuration"
    fi

    connect_and_test_client "migrated-legacy" "$old_conf" "10.98.13.1" "" "10.2.0.100"
    teardown
}

# ---------------------------------------------------------------------------
say "Check this computer"
# ---------------------------------------------------------------------------

if ! docker info > /dev/null 2>&1; then
    echo "ERROR: Docker does not answer. Start Docker and run the test again." >&2
    exit 1
fi
ok "Docker answers"

if lsmod 2> /dev/null | grep -q '^wireguard' || modinfo wireguard > /dev/null 2>&1; then
    ok "The kernel has the WireGuard module"
else
    echo "ERROR: This kernel has no WireGuard module. The test cannot run." >&2
    exit 1
fi

for p in $PROFILES; do
    case "$p" in
        wg-easy) run_wg_easy ;;
        wireguard) run_wireguard ;;
        *)
            echo "Error: unknown profile '$p'." >&2
            exit 1
            ;;
    esac
done

if [[ " $PROFILES " == *" wireguard "* ]]; then
    run_migration
fi

# ---------------------------------------------------------------------------
say "Result"
# ---------------------------------------------------------------------------

echo "  Passed: $PASS"
echo "  Failed: $FAIL"

if [[ $FAIL -eq 0 ]]; then
    printf '\n\033[1mAll tests passed. Real clients connect and get filtered internet.\033[0m\n'
    exit 0
fi
printf '\n\033[1mSome tests failed. Run again with --keep to look at the stack.\033[0m\n'
exit 1
