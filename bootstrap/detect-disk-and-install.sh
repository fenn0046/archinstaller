#!/usr/bin/env bash
# Run this from the Arch live ISO environment. Detects the target disk,
# patches it into the archinstall config template, and launches an
# unattended install. See bootstrap/README.md for the full flow.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/user_configuration.template.json"
CREDS="$SCRIPT_DIR/user_credentials.json"
OUT_CONFIG="/tmp/user_configuration.json"

if [ ! -f "$CREDS" ]; then
  echo "Missing $CREDS" >&2
  echo "Copy user_credentials.sample.json to user_credentials.json and fill in" >&2
  echo "real password hashes first (see bootstrap/README.md)." >&2
  exit 1
fi

mapfile -t CANDIDATES < <(lsblk -dpno NAME,TYPE | awk '$2=="disk"{print $1}')

TARGET_DISK="${1:-}"

if [ -z "$TARGET_DISK" ]; then
  if [ "${#CANDIDATES[@]}" -eq 1 ]; then
    TARGET_DISK="${CANDIDATES[0]}"
    echo "Auto-detected single disk: $TARGET_DISK"
  else
    echo "More than one disk found - refusing to guess which one to wipe:" >&2
    printf '  %s\n' "${CANDIDATES[@]}" >&2
    echo "Re-run as: $0 /dev/sdX" >&2
    exit 1
  fi
fi

echo "About to WIPE and install to: $TARGET_DISK"
lsblk "$TARGET_DISK"
read -rp "This is destructive. Type the device path again to confirm (${TARGET_DISK}): " CONFIRM
if [ "$CONFIRM" != "$TARGET_DISK" ]; then
  echo "Confirmation did not match, aborting." >&2
  exit 1
fi

sed "s#__DISK_DEVICE__#${TARGET_DISK}#" "$TEMPLATE" > "$OUT_CONFIG"

archinstall --config "$OUT_CONFIG" --creds "$CREDS" --silent
