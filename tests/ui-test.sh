#!/usr/bin/env bash
#
# WireHole - test the web interfaces in a real browser.
#
# The end to end test proves the VPN. This test proves the pages: the two
# login forms, the Pi-hole dashboard and query log, and the wg-easy client
# workflow from the README. A browser opens the pages, types the passwords,
# clicks the buttons, and checks what appears. A page that throws a
# JavaScript error fails the test.
#
# The test runs against YOUR running stack and reads the passwords from
# your file ".env". It adds one client named "ui-test-<number>" in wg-easy
# and deletes it again at the end.
#
# The browser runs in the official Playwright container, so nothing gets
# installed on this computer.
#
# HOW TO USE THIS SCRIPT:
#   docker compose up -d        # The stack must run.
#   ./tests/ui-test.sh
#   ./tests/ui-test.sh --help

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

PLAYWRIGHT_IMAGE="mcr.microsoft.com/playwright:v1.55.0-noble"
PLAYWRIGHT_PKG="playwright@1.55.0"

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

if [[ ! -f .env ]]; then
    echo "ERROR: The file .env does not exist. Run ./scripts/generate-secrets.sh first." >&2
    exit 1
fi

env_get() {
    grep -E "^${1}=" .env 2> /dev/null | tail -1 | cut -d= -f2- | tr -d '"'"'"''
}

PIHOLE_PASSWORD="$(env_get PIHOLE_PASSWORD)"
WGEASY_PASSWORD="$(env_get WG_EASY_PASSWORD)"
WGEASY_USERNAME="$(env_get WG_EASY_USERNAME)"
PIHOLE_PORT="$(env_get PIHOLE_WEB_PORT)"
UI_PORT="$(env_get WG_EASY_UI_PORT)"

if ! curl -s -o /dev/null --max-time 8 "http://127.0.0.1:${PIHOLE_PORT:-8080}/admin/"; then
    echo "ERROR: Pi-hole does not answer. Start the stack with: docker compose up -d" >&2
    exit 1
fi
if ! curl -s -o /dev/null --max-time 8 "http://127.0.0.1:${UI_PORT:-51821}/"; then
    echo "ERROR: The wg-easy panel does not answer. This test needs the wg-easy profile." >&2
    exit 1
fi

# The container shares the network of the host, so 127.0.0.1 reaches the
# panels. The npm cache lives in the test directory, so the second run
# starts fast.
cleanup_test_clients() {
    # Remove every client the test made, through the API.
    local jar code id
    jar="$(mktemp)"
    code="$(curl -s -c "$jar" -o /dev/null -w '%{http_code}' --max-time 15 \
        -X POST "http://127.0.0.1:${UI_PORT:-51821}/api/auth/password" \
        -H 'Content-Type: application/json' \
        -d "{\"username\":\"${WGEASY_USERNAME:-admin}\",\"password\":\"${WGEASY_PASSWORD}\",\"remember\":false}")"
    if [[ $code == "200" ]]; then
        curl -s -b "$jar" --max-time 15 "http://127.0.0.1:${UI_PORT:-51821}/api/client" \
            | python3 -c 'import json,sys; [print(c["id"]) for c in json.load(sys.stdin) if str(c.get("name","")).startswith("ui-test-")]' 2> /dev/null \
            | while read -r id; do
                curl -s -b "$jar" -o /dev/null --max-time 15 -X DELETE \
                    "http://127.0.0.1:${UI_PORT:-51821}/api/client/${id}"
                echo "Removed the test client ${id}."
            done
    fi
    rm -f "$jar"
}
trap cleanup_test_clients EXIT

docker run --rm --network host \
    -v "$PWD/tests/ui:/work" -w /work \
    -e PIHOLE_URL="http://127.0.0.1:${PIHOLE_PORT:-8080}" \
    -e WGEASY_URL="http://127.0.0.1:${UI_PORT:-51821}" \
    -e PIHOLE_PASSWORD="$PIHOLE_PASSWORD" \
    -e WGEASY_PASSWORD="$WGEASY_PASSWORD" \
    -e WGEASY_USERNAME="${WGEASY_USERNAME:-admin}" \
    -e npm_config_cache=/work/.npm-cache \
    "$PLAYWRIGHT_IMAGE" \
    bash -c "npm i --silent --no-audit --no-fund $PLAYWRIGHT_PKG > /dev/null 2>&1 && node ui-test.mjs"
