#!/usr/bin/env bash
#
# WireHole - make the file ".env" with strong passwords.
#
# This script does these steps:
#   1. It copies the file ".env.example" to the file ".env".
#   2. It writes a new random password for each password variable.
#   3. It finds your public IP address and writes it to VPN_HOST.
#
# The script never replaces an existing file ".env". Delete the file first,
# or use the option "--force".
#
# HOW TO USE THIS SCRIPT:
#   ./scripts/generate-secrets.sh
#   ./scripts/generate-secrets.sh --force

set -euo pipefail

# Go to the main directory of the project. The script works from any place.
cd "$(dirname "${BASH_SOURCE[0]}")/.."

FORCE=0
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        -h | --help)
            sed -n '2,/^$/ { s/^# \{0,1\}//; p; }' "$0"
            exit 0
            ;;
        *)
            echo "Error: unknown option '$arg'. Use --help." >&2
            exit 1
            ;;
    esac
done

if [[ ! -f .env.example ]]; then
    echo "Error: the file '.env.example' does not exist." >&2
    echo "Run this script in the WireHole directory." >&2
    exit 1
fi

if [[ -f .env && $FORCE -eq 0 ]]; then
    echo "Error: the file '.env' already exists." >&2
    echo "This script does not replace your passwords." >&2
    echo "Use the option '--force' to replace the file." >&2
    exit 1
fi

# Make a random password. The password has 32 characters.
# The script uses openssl. If openssl is absent, the script reads
# the random device of the kernel.
make_password() {
    if command -v openssl > /dev/null 2>&1; then
        openssl rand -hex 16
    else
        # Read a finite amount first. An endless "tr | head" pipeline fails
        # with SIGPIPE because this script uses "set -o pipefail".
        od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
    fi
}

# Write a value to a variable in the file ".env".
# The function does not use the shell to build the command. A password
# with a special character cannot damage the file.
set_var() {
    local key="$1" value="$2"
    VALUE="$value" awk -v key="$key" '
        BEGIN { FS = "=" }
        $1 == key && substr($0, 1, 1) != "#" {
            print key "=" ENVIRON["VALUE"]
            found = 1
            next
        }
        { print }
    ' .env > .env.tmp && mv .env.tmp .env
}

# SECURITY: Make every new file private before any password lands in one.
umask 077

cp .env.example .env

PIHOLE_PW="$(make_password)"
WG_PW="$(make_password)"

set_var PIHOLE_PASSWORD "$PIHOLE_PW"
set_var WG_EASY_PASSWORD "$WG_PW"

# Find the public IP address. The user can change this value later.
echo "The script looks for your public IP address..."
PUBLIC_IP="$(curl -fsS --max-time 10 https://api.ipify.org 2> /dev/null || true)"

if [[ -n $PUBLIC_IP ]]; then
    set_var VPN_HOST "$PUBLIC_IP"
    echo "The script found the address $PUBLIC_IP."
else
    echo "WARNING: The script did not find your public IP address."
    echo "         Open the file '.env' and set VPN_HOST." >&2
fi

# Write the user ID and the group ID of the current user.
set_var PUID "$(id -u)"
set_var PGID "$(id -g)"

# SECURITY: Permit read access for the owner only. The file holds passwords.
# This command must be the last change to the file. The function set_var
# makes a new file, and a new file has the default permissions.
chmod 600 .env

echo
echo "The script made the file '.env'."
echo
echo "  Pi-hole password:    $PIHOLE_PW"
echo "  VPN web password:    $WG_PW"
echo
echo "Write these passwords in your password manager now."
echo "You can also read them again in the file '.env'."
echo
echo "NEXT STEPS:"
echo "  1. Check the value of VPN_HOST in the file '.env'."
echo "  2. Start the stack:  docker compose up -d"
