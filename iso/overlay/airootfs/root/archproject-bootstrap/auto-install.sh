#!/usr/bin/env bash
# Baked into the custom ISO, run automatically on tty1 login via
# .automated_script.sh - no human present, so no interactive confirmation.
# Only proceeds automatically when exactly one disk is found; otherwise
# drops to a shell rather than guessing which disk to wipe.
set -euo pipefail

exec > >(tee -a /root/archproject-bootstrap/auto-install.log) 2>&1

DIR="/root/archproject-bootstrap"
TEMPLATE="$DIR/user_configuration.json"
CREDS="$DIR/user_credentials.json"
OUT_CONFIG="/tmp/user_configuration.json"

echo "[archproject] waiting for network..."
for i in $(seq 1 30); do
  curl -fsS --max-time 5 https://archlinux.org >/dev/null 2>&1 && break
  sleep 5
done

mapfile -t CANDIDATES < <(lsblk -dpno NAME,TYPE | awk '$2=="disk"{print $1}')

if [ "${#CANDIDATES[@]}" -ne 1 ]; then
  echo "[archproject] expected exactly one disk, found ${#CANDIDATES[@]}:" >&2
  printf '  %s\n' "${CANDIDATES[@]}" >&2
  echo "[archproject] refusing to guess - dropping to a shell. Run archinstall manually." >&2
  exit 1
fi

TARGET_DISK="${CANDIDATES[0]}"
echo "[archproject] auto-installing to $TARGET_DISK (no confirmation - unattended ISO)"

sed "s#__DISK_DEVICE__#${TARGET_DISK}#" "$TEMPLATE" > "$OUT_CONFIG"

archinstall --config "$OUT_CONFIG" --creds "$CREDS" --silent

echo "[archproject] install complete, rebooting in 5 seconds..."
sleep 5
reboot
