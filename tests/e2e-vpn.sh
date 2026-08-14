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
#   ./tests/e2e-vpn.sh --help
#
# The script gives exit code 0 when all tests pass.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEEP=0
PROFILES="wg-easy wireguard"
WORK_DIR=""
PROJECT=""
CLIENTS=()

TEST_VPN_PORT=51900
TEST_SUBNET="10.99.0.0/24"
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
        --profile)
            shift
            PROFILES="${1:-}"
            [[ -z $PROFILES ]] && {
                echo "Error: --profile needs a value." >&2
                exit 1
            }
            ;;
        -h | --help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'
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

teardown() {
    # The option --keep stops all clean up, so a failure can be examined.
    [[ $KEEP -eq 1 ]] && return 0
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

cleanup() {
    local code=$?
    if [[ $KEEP -eq 1 && -n $WORK_DIR ]]; then
        say "The option --keep is active. The test keeps these items:"
        echo "  Directory: $WORK_DIR"
        echo "  Clients:   ${CLIENTS[*]:-none}"
        echo "  Remove them with:"
        echo "    docker rm -f ${CLIENTS[*]:-}"
        echo "    (cd $WORK_DIR && docker compose -p $PROJECT --profile wg-easy --profile wireguard down -v)"
        echo "    sudo rm -rf $WORK_DIR"
        return $code
    fi
    teardown
    return $code
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Build a stack in a temporary directory.
# ---------------------------------------------------------------------------
start_stack() {
    local profile="$1" peers="${2:-}"

    WORK_DIR="$(mktemp -d)"
    PROJECT="wirehole-e2e-$$-${profile}"
    cp "$REPO_DIR/docker-compose.yml" "$WORK_DIR/"
    cp -r "$REPO_DIR/unbound" "$WORK_DIR/"
    cp "$REPO_DIR/.env.example" "$WORK_DIR/.env"

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
    set_var WIREHOLE_SUBNET "$TEST_SUBNET"
    set_var PIHOLE_IPV4_ADDRESS "$TEST_PIHOLE_IP"
    set_var UNBOUND_IPV4_ADDRESS "$TEST_UNBOUND_IP"
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
    local label="$1" conf="$2" server_vpn_ip="$3"
    local name="wirehole-e2e-client-$$-$(tr -dc 'a-z0-9' <<< "$label" | head -c 12)"
    CLIENTS+=("$name")

    head2 "Client '$label'"

    # The client reaches the server through the Docker gateway. This is the
    # same path that a phone on your Wi-Fi uses to reach the server.
    local gateway
    gateway="$(docker network inspect bridge -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2> /dev/null)"
    [[ -z $gateway ]] && gateway="172.17.0.1"
    conf="$(sed -E "s|^ *Endpoint *=.*|Endpoint = ${gateway}:${TEST_VPN_PORT}|" <<< "$conf")"

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
    r="$(docker exec "$name" dig +short +time=8 example.com @"$TEST_PIHOLE_IP" 2> /dev/null | head -1)"
    if [[ $r =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        ok "$label: resolves names through Pi-hole ($r)"
    else
        bad "$label: cannot use Pi-hole through the tunnel"
    fi

    r="$(docker exec "$name" dig +short +time=8 doubleclick.net @"$TEST_PIHOLE_IP" 2> /dev/null | head -1)"
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
test_dns_chain() {
    head2 "The DNS chain on the server"
    local c r
    c="$(cd "$WORK_DIR" && docker compose -p "$PROJECT" ps -q pihole | head -1)"

    r="$(docker exec "$c" dig +short +time=8 example.com @127.0.0.1 2> /dev/null | head -1)"
    [[ $r =~ ^[0-9]+\. ]] && ok "Pi-hole resolves a name ($r)" || bad "Pi-hole does not resolve a name"

    r="$(docker exec "$c" dig +short +time=8 wikipedia.org @"$TEST_UNBOUND_IP" 2> /dev/null | head -1)"
    [[ -n $r ]] && ok "Unbound resolves by recursion ($r)" || bad "Unbound does not answer"

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

    # The server holds the first address of the client network.
    local server_ip
    server_ip="$(awk '{print $3}' <<< "$ids" | head -1 | awk -F. '{print $1"."$2"."$3".1"}')"

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
        connect_and_test_client "$cname" "$conf" "$server_ip"
    done <<< "$ids"

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
