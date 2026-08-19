#!/usr/bin/env bash
#
# WireHole - move an old installation to the new layout.
#
# Run this script one time if you used WireHole before the 2026 rewrite.
# The old layout had the directories "config", "db", "etc-pihole", and
# "etc-dnsmasq.d", the container "wireguard-ui", and the variable
# WEBPASSWORD in the file ".env".
#
# The script does these steps:
#   1. It stops and removes the old containers.
#   2. It copies your WireGuard keys to the new location. Your devices
#      keep working. Nobody has to set up a device again.
#   3. It copies your Pi-hole data to the new location. Your block lists,
#      your local DNS records, and your statistics survive.
#   4. It writes a new ".env" from your old settings, and it keeps the old
#      file as ".env.v1.backup".
#
# The script copies. It deletes nothing. Your old directories stay where
# they are until you remove them yourself.
#
# HOW TO USE THIS SCRIPT:
#   ./scripts/migrate-from-v1.sh          # Do the migration.
#   ./scripts/migrate-from-v1.sh --help
#
# After the script, start the stack with: docker compose up -d

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

for arg in "${@:-}"; do
    case "$arg" in
        -h | --help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        "") ;;
        *)
            echo "Error: unknown option '$arg'. Use --help." >&2
            exit 1
            ;;
    esac
done

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok() { printf '  [ OK ]   %s\n' "$*"; }
warn() { printf '  [ NOTE ] %s\n' "$*"; }

# Read a value from the old .env file.
old_get() {
    local key="$1"
    grep -E "^${key}=" .env 2> /dev/null | tail -1 | cut -d= -f2- | tr -d '"'"'"''
}

# Write a value into the new .env file.
new_set() {
    VALUE="$2" awk -v key="$1" '
        BEGIN { FS = "=" }
        $1 == key && substr($0, 1, 1) != "#" { print key "=" ENVIRON["VALUE"]; next }
        { print }
    ' .env > .env.tmp && mv .env.tmp .env
}

# ---------------------------------------------------------------------------
say "1. Look for an old installation"
# ---------------------------------------------------------------------------

OLD=0
[[ -d config ]] && OLD=1
[[ -d etc-pihole ]] && OLD=1
grep -qE '^WEBPASSWORD=' .env 2> /dev/null && OLD=1

if [[ $OLD -eq 0 ]]; then
    echo "This directory has no old WireHole installation."
    echo "Nothing to do. Set up a new stack with: ./scripts/generate-secrets.sh"
    exit 0
fi
ok "Found an old installation."

if [[ -d data/wireguard || -d data/pihole ]]; then
    echo "ERROR: The directory 'data' already has content." >&2
    echo "The script does not write over it. Move it away first." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
say "2. Stop the old containers"
# ---------------------------------------------------------------------------

# The old stack used these fixed names. The new stack uses new names, so
# Docker Compose does not remove the old containers by itself. They keep
# running, and the old WireGuard container keeps the VPN port open.
for c in wireguard-ui wireguard pihole unbound; do
    if docker ps -a --format '{{.Names}}' 2> /dev/null | grep -qx "$c"; then
        docker rm -f "$c" > /dev/null 2>&1 && ok "Removed the old container '$c'."
    fi
done

# ---------------------------------------------------------------------------
say "3. Copy your data to the new layout"
# ---------------------------------------------------------------------------

mkdir -p data

if [[ -d config ]]; then
    # This directory holds the server keys and the peer configurations.
    # The copy keeps every key, so every device keeps working.
    sudo cp -a config data/wireguard 2> /dev/null || cp -a config data/wireguard
    ok "Copied the WireGuard keys and peers to data/wireguard."
fi

if [[ -d etc-pihole ]]; then
    sudo cp -a etc-pihole data/pihole 2> /dev/null || cp -a etc-pihole data/pihole
    ok "Copied the Pi-hole data to data/pihole."
fi

if [[ -d etc-dnsmasq.d ]] && ls etc-dnsmasq.d/*.conf > /dev/null 2>&1; then
    warn "You have custom files in etc-dnsmasq.d. Pi-hole v6 does not read"
    warn "that directory. Move the settings to FTLCONF_misc_dnsmasq_lines,"
    warn "or ask in the issues page. The files stay where they are."
fi

if [[ -d db ]]; then
    warn "The directory 'db' belonged to wireguard-ui. The project removed"
    warn "wireguard-ui, because it had no release since January 2024. The"
    warn "new web interface is wg-easy. Your peers still work without it."
fi

# ---------------------------------------------------------------------------
say "4. Write the new .env from your old settings"
# ---------------------------------------------------------------------------

OLD_WEBPASSWORD="$(old_get WEBPASSWORD)"
OLD_TZ="$(old_get TIMEZONE)"
OLD_PORT="$(old_get WIREGUARD_SERVER_PORT)"
OLD_PEERS="$(old_get WIREGUARD_PEERS)"
OLD_PUID="$(old_get PUID)"
OLD_PGID="$(old_get PGID)"

cp .env .env.v1.backup
chmod 600 .env.v1.backup
ok "Kept your old settings as .env.v1.backup."

cp .env.example .env
chmod 600 .env

# The old stack ran the linuxserver WireGuard service. Keep that profile,
# so your existing keys and peers continue to work. You can change to the
# wg-easy web interface later. Read the file UPGRADING.md.
new_set COMPOSE_PROFILES "wireguard"

[[ -n $OLD_TZ ]] && new_set TZ "$OLD_TZ"
[[ -n $OLD_PORT ]] && new_set VPN_PORT "$OLD_PORT"
[[ -n $OLD_PEERS ]] && new_set WIREGUARD_PEERS "$OLD_PEERS"
[[ -n $OLD_PUID ]] && new_set PUID "$OLD_PUID"
[[ -n $OLD_PGID ]] && new_set PGID "$OLD_PGID"

if [[ -n $OLD_WEBPASSWORD ]]; then
    new_set PIHOLE_PASSWORD "$OLD_WEBPASSWORD"
    ok "Kept your Pi-hole password."
else
    if command -v openssl > /dev/null 2>&1; then
        NEWPW="$(openssl rand -base64 24 | tr -d '\n/+=' | cut -c1-32)"
    else
        NEWPW="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)"
    fi
    new_set PIHOLE_PASSWORD "$NEWPW"
    warn "Your old WEBPASSWORD was empty. The new password is: $NEWPW"
fi

# The new stack needs a password for the wg-easy panel, also when the
# panel does not run. Docker Compose reads every service in the file.
if command -v openssl > /dev/null 2>&1; then
    WGPW="$(openssl rand -base64 24 | tr -d '\n/+=' | cut -c1-32)"
else
    WGPW="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)"
fi
new_set WG_EASY_PASSWORD "$WGPW"

# Find the public address from an existing peer file. The devices already
# connect to this address, so it is the right value.
VPN_HOST_VALUE=""
for f in data/wireguard/peer*/peer*.conf config/peer*/peer*.conf; do
    [[ -f $f ]] || continue
    VPN_HOST_VALUE="$(sudo grep -E '^Endpoint' "$f" 2> /dev/null | head -1 | sed -E 's/^Endpoint *= *//; s/:[0-9]+$//')" \
        || VPN_HOST_VALUE="$(grep -E '^Endpoint' "$f" 2> /dev/null | head -1 | sed -E 's/^Endpoint *= *//; s/:[0-9]+$//')"
    [[ -n $VPN_HOST_VALUE ]] && break
done

if [[ -n $VPN_HOST_VALUE ]]; then
    new_set VPN_HOST "$VPN_HOST_VALUE"
    ok "Found your public address in a peer file: $VPN_HOST_VALUE"
else
    PUB="$(curl -fsS --max-time 10 https://api.ipify.org 2> /dev/null || true)"
    if [[ -n $PUB ]]; then
        new_set VPN_HOST "$PUB"
        warn "No peer file found. The script used your public address: $PUB"
    else
        warn "Set VPN_HOST in the file .env yourself before you start."
    fi
fi

# ---------------------------------------------------------------------------
say "5. Check the result"
# ---------------------------------------------------------------------------

if docker compose config --quiet 2> /dev/null; then
    ok "The new configuration is valid."
else
    warn "docker compose config reports a problem. Open .env and check it."
fi

say "Done. Start the stack with: docker compose up -d"
echo
echo "Your devices keep their existing configurations. Nothing changes"
echo "for them. Your old directories (config, etc-pihole, db) stay as a"
echo "backup. Remove them when the new stack works:"
echo "  sudo rm -rf config etc-pihole etc-dnsmasq.d db .env.v1.backup"
echo
echo "Read UPGRADING.md for the full explanation, and for the way to the"
echo "wg-easy web interface."
