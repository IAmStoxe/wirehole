#!/usr/bin/env bash
#
# WireHole - check your own stack and find problems.
#
# Run this script on your server at any time. It looks at your running
# stack and tells you what works, what does not, and what to do next.
# The script only reads. It changes nothing.
#
# HOW TO USE THIS SCRIPT:
#   ./scripts/wirehole-doctor.sh          # Check everything.
#   ./scripts/wirehole-doctor.sh --phone  # Also show how to test from a
#                                         # phone on your Wi-Fi.
#   ./scripts/wirehole-doctor.sh --help
#
# Run it again after you connect a phone. The script then shows the
# handshake time of that phone, which proves the connection works.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

PHONE=0
for arg in "$@"; do
    case "$arg" in
        --phone) PHONE=1 ;;
        -h | --help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Error: unknown option '$arg'. Use --help." >&2
            exit 1
            ;;
    esac
done

PROBLEMS=0
WARNINGS=0

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok() { printf '  [ OK ]   %s\n' "$*"; }
warn() {
    printf '  [ WARN ] %s\n' "$*"
    WARNINGS=$((WARNINGS + 1))
}
bad() {
    printf '  [ BAD ]  %s\n' "$*"
    PROBLEMS=$((PROBLEMS + 1))
}
fix() { printf '           -> %s\n' "$*"; }

# Read a value from the file .env without running the file.
env_get() {
    local key="$1" def="${2:-}"
    local v
    v="$(grep -E "^${key}=" .env 2> /dev/null | tail -1 | cut -d= -f2- | tr -d '"'"'"'')"
    echo "${v:-$def}"
}

# ---------------------------------------------------------------------------
say "1. The basics"
# ---------------------------------------------------------------------------

if docker info > /dev/null 2>&1; then
    ok "Docker is running."
else
    bad "Docker does not answer."
    fix "Start it with: sudo systemctl start docker"
    echo
    echo "Nothing else can be checked. Fix this first."
    exit 1
fi

if [[ -f .env ]]; then
    ok "The file .env exists."
    perms="$(stat -c '%a' .env 2> /dev/null)"
    if [[ $perms == "600" ]]; then
        ok "The file .env is private (permission $perms)."
    else
        warn "The file .env has permission $perms. Other users can read your passwords."
        fix "Run: chmod 600 .env"
    fi
else
    bad "The file .env does not exist."
    fix "Run: ./scripts/generate-secrets.sh"
    exit 1
fi

VPN_HOST="$(env_get VPN_HOST)"
VPN_PORT="$(env_get VPN_PORT 51820)"
UNBOUND_IP="$(env_get UNBOUND_IPV4_ADDRESS 10.2.0.200)"
PROFILE="$(env_get COMPOSE_PROFILES wg-easy)"
BIND="$(env_get WEB_BIND_ADDRESS 127.0.0.1)"
PIHOLE_PORT="$(env_get PIHOLE_WEB_PORT 8080)"
UI_PORT="$(env_get WG_EASY_UI_PORT 51821)"

for v in VPN_HOST PIHOLE_PASSWORD WG_EASY_PASSWORD; do
    if [[ -z "$(env_get $v)" ]]; then
        bad "$v has no value in the file .env."
        fix "Open .env and set it, or run ./scripts/generate-secrets.sh"
    fi
done
[[ $PROBLEMS -eq 0 ]] && ok "The necessary values are set."

# ---------------------------------------------------------------------------
say "2. The containers"
# ---------------------------------------------------------------------------

running="$(docker compose ps --services --filter status=running 2> /dev/null)"
if [[ -z $running ]]; then
    bad "No container is running."
    fix "Start the stack with: docker compose up -d"
    exit 1
fi

for svc in unbound pihole; do
    if grep -q "^${svc}$" <<< "$running"; then
        ok "The service '$svc' runs."
    else
        bad "The service '$svc' does not run."
        fix "Look at the log: docker compose logs $svc"
    fi
done

VPN_SVC=""
if grep -q '^wg-easy$' <<< "$running"; then
    VPN_SVC="wg-easy"
elif grep -q '^wireguard$' <<< "$running"; then
    VPN_SVC="wireguard"
fi

if [[ -n $VPN_SVC ]]; then
    ok "The VPN service '$VPN_SVC' runs."
else
    bad "No VPN service runs. The profile in .env is '$PROFILE'."
    fix "Start it with: docker compose up -d"
fi

unhealthy="$(docker ps --filter health=unhealthy --format '{{.Names}}' | grep -E '^wirehole-(pihole|unbound|wg-easy|wireguard)$' || true)"
if [[ -n $unhealthy ]]; then
    bad "These containers report unhealthy: $unhealthy"
    fix "Look at the log: docker compose logs $unhealthy"
fi

restarting="$(docker ps --filter status=restarting --format '{{.Names}}' | grep -E '^wirehole-(pihole|unbound|wg-easy|wireguard)$' || true)"
if [[ -n $restarting ]]; then
    bad "These containers restart again and again: $restarting"
    fix "Look at the log: docker compose logs $restarting"
fi

# ---------------------------------------------------------------------------
say "3. The DNS chain"
# ---------------------------------------------------------------------------

PIHOLE_C="$(docker compose ps -q pihole 2> /dev/null | head -1)"
if [[ -n $PIHOLE_C ]]; then
    r="$(docker exec "$PIHOLE_C" dig +short +time=5 example.com @127.0.0.1 2> /dev/null | head -1)"
    if [[ $r =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        ok "Pi-hole resolves names ($r)."
    else
        bad "Pi-hole does not resolve names."
        fix "Look at the log: docker compose logs pihole"
    fi

    r="$(docker exec "$PIHOLE_C" dig +short +time=8 wikipedia.org @"$UNBOUND_IP" 2> /dev/null | head -1)"
    if [[ -n $r ]]; then
        ok "Unbound resolves names by recursion ($r)."
    else
        bad "Unbound does not answer."
        fix "Look at the log: docker compose logs unbound"
        fix "A common cause is IPv6. See the file unbound/custom.conf.d/pi-hole.conf"
    fi

    if docker exec "$PIHOLE_C" dig +dnssec +time=8 cloudflare.com @"$UNBOUND_IP" 2> /dev/null | grep -q '^;; flags.* ad'; then
        ok "DNSSEC validation works."
    else
        warn "Unbound did not set the 'ad' flag. DNSSEC may not work."
    fi

    r="$(docker exec "$PIHOLE_C" dig +short +time=5 doubleclick.net @127.0.0.1 2> /dev/null | head -1)"
    if [[ $r == "0.0.0.0" ]]; then
        ok "Advertisement blocking works."
    else
        warn "Pi-hole did not block a test domain (got '$r')."
        fix "Update the block lists in the Pi-hole web interface."
    fi
fi

# ---------------------------------------------------------------------------
say "4. The network and the ports"
# ---------------------------------------------------------------------------

if ss -lun 2> /dev/null | grep -q ":${VPN_PORT}\b" || ss -lun 2> /dev/null | grep -q ":${VPN_PORT} "; then
    ok "The VPN port ${VPN_PORT}/udp is open on this server."
else
    warn "This server does not appear to listen on ${VPN_PORT}/udp."
fi

if docker compose ps --format '{{.Ports}}' 2> /dev/null | grep -qE '0\.0\.0\.0:53|:::53'; then
    bad "Port 53 is published to every address. This is an open DNS resolver."
    fix "Remove the port 53 lines from docker-compose.yml."
else
    ok "Port 53 is not published. Good."
fi

if [[ $BIND == "0.0.0.0" ]]; then
    warn "WEB_BIND_ADDRESS is 0.0.0.0. Both web panels are on your network with no encryption."
    fix "Set WEB_BIND_ADDRESS=127.0.0.1 and use an SSH tunnel. Read SECURITY.md."
else
    ok "The web panels are private (bound to $BIND)."
fi

code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://127.0.0.1:${PIHOLE_PORT}/admin/" 2> /dev/null)"
if [[ $code -ge 200 && $code -lt 500 ]]; then
    ok "The Pi-hole panel answers (HTTP $code)."
else
    warn "The Pi-hole panel did not answer on port ${PIHOLE_PORT}."
fi

if [[ $VPN_SVC == "wg-easy" ]]; then
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://127.0.0.1:${UI_PORT}/" 2> /dev/null)"
    if [[ $code -ge 200 && $code -lt 500 ]]; then
        ok "The VPN panel answers (HTTP $code)."
    else
        warn "The VPN panel did not answer on port ${UI_PORT}."
    fi

    # wg-easy reads the port one time, at the first start. A later change
    # of VPN_PORT moves the published port but not the listen port, and
    # the VPN stops with no error. Compare the two.
    wgc="$(docker compose ps -q wg-easy 2> /dev/null | head -1)"
    if [[ -n $wgc ]]; then
        listen="$(docker exec "$wgc" wg show wg0 listen-port 2> /dev/null)"
        if [[ -n $listen && $listen != "$VPN_PORT" ]]; then
            bad "The server listens on port $listen, but VPN_PORT is $VPN_PORT."
            fix "wg-easy reads the port only at the first start."
            fix "Change the port in the VPN web interface, or set VPN_PORT=$listen."
        elif [[ -n $listen ]]; then
            ok "The VPN listen port matches VPN_PORT ($listen)."
        fi
    fi
fi

if command -v ufw > /dev/null 2>&1 && ufw status 2> /dev/null | grep -q "Status: active"; then
    if ufw status 2> /dev/null | grep -q "${VPN_PORT}/udp"; then
        ok "The firewall allows ${VPN_PORT}/udp."
    else
        bad "The firewall is active and does not allow ${VPN_PORT}/udp."
        fix "Run: sudo ufw allow ${VPN_PORT}/udp"
    fi
fi

# ---------------------------------------------------------------------------
say "5. How your devices find you"
# ---------------------------------------------------------------------------

PUBLIC_IP="$(curl -fsS --max-time 8 https://api.ipify.org 2> /dev/null)"
LAN_IP="$(hostname -I 2> /dev/null | awk '{print $1}')"

echo "  Your VPN_HOST is:      $VPN_HOST"
[[ -n $PUBLIC_IP ]] && echo "  Your public address:   $PUBLIC_IP"
[[ -n $LAN_IP ]] && echo "  This server on the LAN: $LAN_IP"
echo

if [[ $VPN_HOST =~ ^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|127\.) ]]; then
    warn "VPN_HOST is a local address. Devices outside your home cannot use it."
    fix "Set VPN_HOST to your public address or to a dynamic DNS name."
elif [[ -n $PUBLIC_IP && $VPN_HOST == "$PUBLIC_IP" ]]; then
    ok "VPN_HOST matches your current public address."
elif [[ $VPN_HOST =~ ^[0-9.]+$ && -n $PUBLIC_IP && $VPN_HOST != "$PUBLIC_IP" ]]; then
    bad "VPN_HOST ($VPN_HOST) is not your current public address ($PUBLIC_IP)."
    fix "Your address changed. Use a dynamic DNS name. Read the README."
    fix "Then change the address in the VPN web interface, not only in .env."
else
    ok "VPN_HOST is a name. Make sure it points at $PUBLIC_IP."
fi

if [[ -n $PUBLIC_IP && $PUBLIC_IP =~ ^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\. ]]; then
    bad "Your provider uses CGNAT. Port forwarding cannot work."
    fix "Ask your provider for a public IP address, or use a rented server."
fi

# ---------------------------------------------------------------------------
say "6. Connected devices"
# ---------------------------------------------------------------------------

VPN_C=""
[[ -n $VPN_SVC ]] && VPN_C="$(docker compose ps -q "$VPN_SVC" 2> /dev/null | head -1)"
if [[ -n $VPN_C ]]; then
    peers="$(docker exec "$VPN_C" wg show all latest-handshakes 2> /dev/null)"
    if [[ -z $peers ]]; then
        warn "The VPN has no devices yet."
        fix "Add one. Read the section 'Add a VPN client' in the README."
    else
        now="$(date +%s)"
        connected=0
        total=0
        while read -r _iface key hs; do
            [[ -z ${hs:-} ]] && continue
            total=$((total + 1))
            short="${key:0:12}..."
            if [[ $hs -eq 0 ]]; then
                echo "  device $short: never connected"
            else
                ago=$((now - hs))
                if [[ $ago -lt 300 ]]; then
                    connected=$((connected + 1))
                    echo "  device $short: connected ${ago}s ago"
                else
                    echo "  device $short: last seen ${ago}s ago"
                fi
            fi
        done <<< "$peers"
        echo
        if [[ $connected -gt 0 ]]; then
            ok "$connected of $total devices are connected right now."
        else
            warn "No device has connected in the last 5 minutes."
            fix "Turn the VPN on, wait 10 seconds, and run this script again."
        fi
    fi
fi

# ---------------------------------------------------------------------------
if [[ $PHONE -eq 1 ]]; then
    say "7. Test with a phone on the same Wi-Fi"

    cat << EOF
  You can test the VPN from your phone before you set up your router.
  This proves that the server works. It does not test the internet path.

  1. Put your phone on the same Wi-Fi as this server.

  2. Add a device in the VPN panel and load it into the WireGuard app.

  3. In the WireGuard app on your phone, open the device and change the
     endpoint address to the local address of this server:

         ${LAN_IP:-<the address from hostname -I>}:${VPN_PORT}

     Keep the port. Change only the address before the colon.

  4. Turn the VPN on in the app.

  5. Run this script again on the server:

         ./scripts/wirehole-doctor.sh

     Section 6 must show your phone as connected a few seconds ago.

  6. On the phone, open a website with many advertisements. They should
     be gone. Then open https://dnsleaktest.com and run the standard
     test. It must show only your own server.

  7. Change the endpoint back to ${VPN_HOST}:${VPN_PORT} when you finish,
     so the device also works away from home.

  If the phone does not connect on the same Wi-Fi, the problem is on this
  server: the firewall, or the service. If it connects here but not from
  mobile data, the problem is your router or your provider.
EOF
fi

# ---------------------------------------------------------------------------
say "Result"
# ---------------------------------------------------------------------------

echo "  Problems: $PROBLEMS"
echo "  Warnings: $WARNINGS"
echo

if [[ $PROBLEMS -eq 0 && $WARNINGS -eq 0 ]]; then
    printf '\033[1mEverything looks good.\033[0m\n'
elif [[ $PROBLEMS -eq 0 ]]; then
    printf '\033[1mThe stack works. Read the warnings above.\033[0m\n'
else
    printf '\033[1mThere are problems. Each one has a suggested fix above.\033[0m\n'
    exit 1
fi
