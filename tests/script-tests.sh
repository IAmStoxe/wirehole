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

# Keep the three places that name a pinned image version in sync. A mismatch
# gives beginners a command that silently changes the version they tested.
for version_var in PIHOLE_VERSION UNBOUND_VERSION WG_EASY_VERSION WIREGUARD_VERSION; do
    expected="$(awk -F= -v key="$version_var" '$1 == key { print $2 }' "$REPO_DIR/.env.example")"
    [[ -n $expected ]] || {
        echo "ERROR: $version_var has no value in .env.example" >&2
        exit 1
    }
    grep -Fq "\${${version_var}:-${expected}}" "$REPO_DIR/docker-compose.yml" || {
        echo "ERROR: $version_var differs between .env.example and docker-compose.yml" >&2
        exit 1
    }
    grep -Fqx "${version_var}=${expected}" "$REPO_DIR/README.md" || {
        echo "ERROR: $version_var differs between .env.example and README.md" >&2
        exit 1
    }
done

# Every variable read explicitly by Compose must be present in the example
# file. This keeps the example file a complete configuration reference.
while read -r compose_var; do
    grep -q "^${compose_var}=" "$REPO_DIR/.env.example" || {
        echo "ERROR: $compose_var is used by Compose but missing from .env.example" >&2
        exit 1
    }
done < <(grep -oE '\$\{[A-Z][A-Z0-9_]*' "$REPO_DIR/docker-compose.yml" \
    | sed 's/^${//' | sort -u)

echo "OK: setup and configuration documentation regressions passed."
