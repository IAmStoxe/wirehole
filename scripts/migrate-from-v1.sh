#!/usr/bin/env bash
#
# WireHole - move an old installation to the new layout.
#
# Run this script one time if you used WireHole before the 2026 rewrite.
# The old layout had the directories "config", "db", "etc-pihole", and
# "etc-dnsmasq.d", the container "wireguard-ui", and the variable
# WEBPASSWORD in the file ".env".
#
# The script validates the old installation and the new Compose file before it
# stops anything. It then copies the WireGuard and Pi-hole data, preserves the
# active WireGuard keys and endpoint, and writes the new .env file.
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
            sed -n '2,/^$/ { s/^# \{0,1\}//; p; }' "$0"
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
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

TEMP_ENV=""
TEMP_DIR=""
MIGRATION_FINISHED=0
STOPPED_CONTAINERS=()

cleanup() {
    local status=$?

    if [[ $MIGRATION_FINISHED -eq 0 && ${#STOPPED_CONTAINERS[@]} -gt 0 ]]; then
        warn "The migration did not finish. Restarting the old containers."
        for container in "${STOPPED_CONTAINERS[@]}"; do
            if docker start "$container" > /dev/null 2>&1; then
                ok "Restarted '$container'."
            else
                warn "Could not restart '$container'. Start it manually."
            fi
        done
    fi

    [[ -z $TEMP_ENV ]] || rm -f -- "$TEMP_ENV" "${TEMP_ENV}.tmp"
    [[ -z $TEMP_DIR ]] || rm -rf -- "$TEMP_DIR"
    exit "$status"
}
trap cleanup EXIT

# Read a value from the old .env file. Missing optional values are empty.
old_get() {
    local key="$1"
    awk -v key="$key" '
        index($0, key "=") == 1 {
            value = substr($0, length(key) + 2)
            if (value ~ /^".*"$/ || value ~ /^'\''.*'\''$/) {
                value = substr(value, 2, length(value) - 2)
            }
            found = value
        }
        END { print found }
    ' .env
}

# Read the exact right-hand side so a quoted password keeps its dotenv
# escaping when it moves to the new variable name.
old_get_raw() {
    local key="$1"
    awk -v key="$key" '
        index($0, key "=") == 1 {
            found = substr($0, length(key) + 2)
        }
        END { print found }
    ' .env
}

# Write a value into a specified .env file.
new_set() {
    local file="$1"
    local key="$2"
    local value="$3"

    VALUE="$value" awk -v key="$key" '
        BEGIN { FS = "=" }
        $1 == key && substr($0, 1, 1) != "#" {
            print key "=" ENVIRON["VALUE"]
            found = 1
            next
        }
        { print }
        END { if (!found) print key "=" ENVIRON["VALUE"] }
    ' "$file" > "${file}.tmp"
    mv "${file}.tmp" "$file"
}

make_password() {
    if command -v openssl > /dev/null 2>&1; then
        openssl rand -hex 16
    else
        od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
    fi
}

container_exists() {
    docker ps -a --format '{{.Names}}' | grep -Fqx "$1"
}

container_runs() {
    [[ $(docker inspect --format '{{.State.Running}}' "$1" 2> /dev/null) == true ]]
}

# Fixed container names are shared across every checkout. Do not stop a
# container belonging to some other installation on the host.
check_container_owner() {
    local container="$1"
    local expected_source="$2"
    local source

    container_exists "$container" || return 0
    source="$(docker inspect --format '{{range .Mounts}}{{println .Source}}{{end}}' "$container")"
    if ! grep -Fqx "$(realpath "$expected_source")" <<< "$source"; then
        die "container '$container' does not use '$expected_source'; refusing to change it"
    fi
}

copy_directory() {
    local source="$1"
    local destination="$2"

    if cp -a "$source" "$destination" 2> /dev/null; then
        return
    fi

    # The destination passed to this function was proven absent during
    # preflight. Remove only that fresh partial copy before retrying as root.
    if ! rm -rf -- "$destination"; then
        command -v sudo > /dev/null 2>&1 \
            || die "cannot clear the incomplete '$destination' copy and sudo is unavailable"
        sudo rm -rf -- "$destination"
    fi
    command -v sudo > /dev/null 2>&1 \
        || die "cannot read '$source' and sudo is unavailable"
    sudo cp -a "$source" "$destination"
}

read_endpoint() {
    local file="$1"
    local endpoint

    if [[ -r $file ]]; then
        endpoint="$(grep -m1 -E '^[[:space:]]*Endpoint[[:space:]]*=' "$file" 2> /dev/null \
            | sed -E 's/^[^=]*=[[:space:]]*//' || true)"
    elif [[ -x $(command -v sudo || true) ]]; then
        endpoint="$(sudo grep -m1 -E '^[[:space:]]*Endpoint[[:space:]]*=' "$file" 2> /dev/null \
            | sed -E 's/^[^=]*=[[:space:]]*//' || true)"
    fi
    printf '%s\n' "$endpoint"
}

# ---------------------------------------------------------------------------
say "1. Validate the old installation"
# ---------------------------------------------------------------------------

[[ -f .env ]] || die "the old .env file is missing"
[[ -f .env.example ]] || die ".env.example is missing; update this checkout first"
[[ -f docker-compose.yml ]] || die "docker-compose.yml is missing"

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

[[ ! -e data/wireguard && ! -e data/pihole ]] \
    || die "data/wireguard or data/pihole already exists; refusing to overwrite it"

docker info > /dev/null 2>&1 || die "Docker is not running or is not accessible"
docker compose version > /dev/null 2>&1 || die "Docker Compose v2 is required"

check_container_owner wireguard "$PWD/config"
check_container_owner wireguard-ui "$PWD/db"
check_container_owner pihole "$PWD/etc-pihole"
check_container_owner unbound "$PWD/unbound"

OLD_WEBPASSWORD="$(old_get WEBPASSWORD)"
OLD_WEBPASSWORD_RAW="$(old_get_raw WEBPASSWORD)"
OLD_TZ="$(old_get TIMEZONE)"
OLD_IGNORED_PORT="$(old_get WIREGUARD_SERVER_PORT)"
OLD_IGNORED_PEERS="$(old_get WIREGUARD_PEERS)"
OLD_PUID="$(old_get PUID)"
OLD_PGID="$(old_get PGID)"
OLD_UI_HOST="$(old_get WGUI_ENDPOINT_ADDRESS)"

TEMP_DIR="$(mktemp -d)"
ACTIVE_CONFIG=""
for candidate in config/wg_confs/wg0.conf config/wg0.conf; do
    if [[ -f $candidate ]]; then
        ACTIVE_CONFIG="$candidate"
        break
    fi
done

# Some wireguard-ui installations kept the active configuration in the
# container rather than the host directory. Extract it while the old container
# still exists, before anything is stopped.
if [[ -z $ACTIVE_CONFIG ]] && container_exists wireguard-ui; then
    for candidate in /etc/wireguard/wg0.conf /config/wg_confs/wg0.conf /config/wg0.conf; do
        if docker cp "wireguard-ui:${candidate}" "$TEMP_DIR/wg0.conf" > /dev/null 2>&1 \
            && grep -q '^\[Interface\]' "$TEMP_DIR/wg0.conf"; then
            ACTIVE_CONFIG="$TEMP_DIR/wg0.conf"
            ok "Recovered the active WireGuard configuration from wireguard-ui."
            break
        fi
    done
fi
[[ -n $ACTIVE_CONFIG ]] || die "no active wg0.conf was found; stopping now to avoid changing your keys"

ENDPOINT=""
ENDPOINT_CANDIDATE=""
while IFS= read -r -d '' peer_file; do
    ENDPOINT_CANDIDATE="$(read_endpoint "$peer_file")"
    # Ignore LinuxServer's template value ${SERVERURL}:${SERVERPORT} and any
    # other incomplete entry. Only an endpoint with a numeric port describes
    # what an existing client actually uses.
    if [[ $ENDPOINT_CANDIDATE =~ ^\[[^]]+\]:[0-9]+$ \
        || $ENDPOINT_CANDIDATE =~ ^[^:]+:[0-9]+$ ]]; then
        ENDPOINT="$ENDPOINT_CANDIDATE"
        break
    fi
done < <(find config -type f -name '*.conf' -print0 2> /dev/null || true)

ENDPOINT_HOST=""
ENDPOINT_PORT=""
if [[ $ENDPOINT =~ ^\[(.*)\]:([0-9]+)$ ]]; then
    ENDPOINT_HOST="${BASH_REMATCH[1]}"
    ENDPOINT_PORT="${BASH_REMATCH[2]}"
elif [[ $ENDPOINT =~ ^(.+):([0-9]+)$ ]]; then
    ENDPOINT_HOST="${BASH_REMATCH[1]}"
    ENDPOINT_PORT="${BASH_REMATCH[2]}"
fi

PUBLISHED_PORT=""
if container_exists wireguard; then
    PUBLISHED_PORT="$(docker port wireguard 51820/udp 2> /dev/null \
        | sed -nE '1{s/.*:([0-9]+)$/\1/p;}' || true)"
fi
VPN_PORT_VALUE="${PUBLISHED_PORT:-${ENDPOINT_PORT:-51820}}"
VPN_HOST_VALUE="${ENDPOINT_HOST:-$OLD_UI_HOST}"

if [[ -z $VPN_HOST_VALUE ]]; then
    VPN_HOST_VALUE="$(curl -fsS --max-time 10 https://api.ipify.org 2> /dev/null || true)"
fi
[[ -n $VPN_HOST_VALUE ]] || die "could not determine VPN_HOST from a peer, wireguard-ui, or the public IP"

if [[ -n $OLD_IGNORED_PORT && $OLD_IGNORED_PORT != "$VPN_PORT_VALUE" ]]; then
    warn "The old WIREGUARD_SERVER_PORT=$OLD_IGNORED_PORT was not used by the old Compose file."
    warn "Keeping the active endpoint port $VPN_PORT_VALUE instead."
fi
if [[ -n $OLD_IGNORED_PEERS ]]; then
    warn "The old WIREGUARD_PEERS value was not used by the old Compose file."
    warn "Keeping the existing peer configurations and keys instead."
fi

TEMP_ENV="$(mktemp "${PWD}/.env.migration.XXXXXX")"
cp .env.example "$TEMP_ENV"
chmod 600 "$TEMP_ENV"
new_set "$TEMP_ENV" COMPOSE_PROFILES wireguard
new_set "$TEMP_ENV" WIREGUARD_PEERS ""
new_set "$TEMP_ENV" VPN_HOST "$VPN_HOST_VALUE"
new_set "$TEMP_ENV" VPN_PORT "$VPN_PORT_VALUE"
[[ -z $OLD_TZ ]] || new_set "$TEMP_ENV" TZ "$OLD_TZ"
[[ -z $OLD_PUID ]] || new_set "$TEMP_ENV" PUID "$OLD_PUID"
[[ -z $OLD_PGID ]] || new_set "$TEMP_ENV" PGID "$OLD_PGID"

if [[ -n $OLD_WEBPASSWORD ]]; then
    new_set "$TEMP_ENV" PIHOLE_PASSWORD "$OLD_WEBPASSWORD_RAW"
    ok "Kept the Pi-hole password."
else
    NEW_PIHOLE_PASSWORD="$(make_password)"
    new_set "$TEMP_ENV" PIHOLE_PASSWORD "$NEW_PIHOLE_PASSWORD"
    warn "The old WEBPASSWORD was empty. The new Pi-hole password is: $NEW_PIHOLE_PASSWORD"
fi
new_set "$TEMP_ENV" WG_EASY_PASSWORD "$(make_password)"

docker compose --env-file "$TEMP_ENV" config --quiet \
    || die "the generated configuration is invalid; the old stack is unchanged"
ok "The new configuration is valid."

# ---------------------------------------------------------------------------
say "2. Stop the old containers"
# ---------------------------------------------------------------------------

for container in wireguard-ui wireguard pihole unbound; do
    if container_exists "$container" && container_runs "$container"; then
        docker stop "$container" > /dev/null
        STOPPED_CONTAINERS+=("$container")
        ok "Stopped '$container'."
    fi
done

# ---------------------------------------------------------------------------
say "3. Copy the data to the new layout"
# ---------------------------------------------------------------------------

mkdir -p data
if [[ -d config ]]; then
    copy_directory config data/wireguard
else
    mkdir -p data/wireguard/wg_confs
    cp "$ACTIVE_CONFIG" data/wireguard/wg_confs/wg0.conf
fi

# Ensure a configuration extracted from wireguard-ui is present in the copy.
if [[ $ACTIVE_CONFIG == "$TEMP_DIR/wg0.conf" ]]; then
    mkdir -p data/wireguard/wg_confs
    cp "$ACTIVE_CONFIG" data/wireguard/wg_confs/wg0.conf
fi
ok "Copied the WireGuard configuration without changing its keys."

if [[ -d etc-pihole ]]; then
    copy_directory etc-pihole data/pihole
    ok "Copied the Pi-hole data."
fi

if [[ -d etc-dnsmasq.d ]] && find etc-dnsmasq.d -maxdepth 1 -name '*.conf' -print -quit \
    | grep -q .; then
    warn "Custom etc-dnsmasq.d files need manual conversion for Pi-hole v6."
    warn "The old files remain untouched. See UPGRADING.md."
fi

if [[ -d db ]]; then
    warn "The old wireguard-ui database is not used by wg-easy."
    warn "The existing peer configurations continue to work."
fi

# ---------------------------------------------------------------------------
say "4. Install the new settings"
# ---------------------------------------------------------------------------

cp .env .env.v1.backup
chmod 600 .env.v1.backup
mv "$TEMP_ENV" .env
TEMP_ENV=""
chmod 600 .env

docker compose config --quiet || die "the installed Compose configuration is invalid"
ok "Installed the new .env and kept the old one as .env.v1.backup."
ok "VPN endpoint: ${VPN_HOST_VALUE}:${VPN_PORT_VALUE}"

# Remove the stopped legacy containers only after every file operation and
# validation has succeeded. The copied data and old directories stay intact.
for container in wireguard-ui wireguard pihole unbound; do
    if container_exists "$container"; then
        if docker rm "$container" > /dev/null; then
            ok "Removed the old container '$container'."
        else
            warn "Could not remove '$container'. It remains stopped and can be removed later."
        fi
    fi
done

STOPPED_CONTAINERS=()
MIGRATION_FINISHED=1

say "Done. Start the stack with: docker compose up -d"
echo
echo "The LinuxServer profile will load the existing wg0.conf directly."
echo "Its keys, peers, addresses, and client configurations are unchanged."
echo "Run ./scripts/wirehole-doctor.sh, then test one device before removing"
echo "the old config, etc-pihole, etc-dnsmasq.d, or db directories."
echo
echo "Read UPGRADING.md before switching an existing installation to wg-easy."
