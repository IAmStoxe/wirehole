#!/usr/bin/env bash
# Fast regression tests for the setup scripts. These tests use an isolated
# directory and do not need Docker or network access.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_DIR"' EXIT

PROJECT_DIR="$TEST_DIR/project"
FAKE_BIN="$TEST_DIR/bin"
mkdir -p "$PROJECT_DIR/scripts" "$FAKE_BIN"
cp "$REPO_DIR/.env.example" "$PROJECT_DIR/"
cp "$REPO_DIR/scripts/generate-secrets.sh" "$PROJECT_DIR/scripts/"

# Give the child a minimal PATH without openssl. curl points to true so the
# test cannot use the network; an empty VPN_HOST is valid at this stage.
for command_name in bash dirname cp awk mv od tr id chmod; do
    command_path="$(command -v "$command_name")"
    ln -s "$command_path" "$FAKE_BIN/$command_name"
done
ln -s "$(command -v true)" "$FAKE_BIN/curl"

PATH="$FAKE_BIN" "$PROJECT_DIR/scripts/generate-secrets.sh" > "$TEST_DIR/output.log" 2>&1

pihole_password="$(awk -F= '$1 == "PIHOLE_PASSWORD" { print $2 }' "$PROJECT_DIR/.env")"
wg_easy_password="$(awk -F= '$1 == "WG_EASY_PASSWORD" { print $2 }' "$PROJECT_DIR/.env")"

[[ $pihole_password =~ ^[0-9a-f]{32}$ ]] || {
    echo "ERROR: the no-openssl Pi-hole password is invalid" >&2
    exit 1
}
[[ $wg_easy_password =~ ^[0-9a-f]{32}$ ]] || {
    echo "ERROR: the no-openssl wg-easy password is invalid" >&2
    exit 1
}
[[ $(stat -c '%a' "$PROJECT_DIR/.env") == 600 ]] || {
    echo "ERROR: generate-secrets.sh did not make .env private" >&2
    exit 1
}

if PATH="$FAKE_BIN" "$PROJECT_DIR/scripts/generate-secrets.sh" > /dev/null 2>&1; then
    echo "ERROR: generate-secrets.sh replaced an existing .env without --force" >&2
    exit 1
fi

echo "OK: setup script regressions passed."
