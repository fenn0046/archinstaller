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

# The disk layout in user_configuration.json is GPT with an ESP at /boot and
# no BIOS boot partition, so GRUB can only install in UEFI mode. Checked up
# front: otherwise this fails ~20 minutes in, at grub-install, with nobody
# watching and an obscure error.
if [ ! -d /sys/firmware/efi ]; then
  echo "[archproject] This layout is GPT + ESP with no BIOS boot partition, so it" >&2
  echo "[archproject] requires UEFI firmware - but this machine booted in legacy" >&2
  echo "[archproject] BIOS mode. Set the VM firmware to UEFI and boot again." >&2
  exit 1
fi

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

# The installed archinstall's Unit enum has no "Percent" - the root
# partition's size must be an absolute value, computed from the real disk
# size minus the boot partition (1025 MiB) and a small safety margin for
# GPT's backup header/alignment.
DISK_BYTES=$(blockdev --getsize64 "$TARGET_DISK")
DISK_MIB=$(( DISK_BYTES / 1048576 ))
ROOT_SIZE_MIB=$(( DISK_MIB - 1025 - 4 ))

if [ "$ROOT_SIZE_MIB" -lt 1024 ]; then
  echo "[archproject] disk too small (${DISK_MIB} MiB) for this partition layout." >&2
  exit 1
fi

sed -e "s#__DISK_DEVICE__#${TARGET_DISK}#" \
    -e "s/\"__ROOT_SIZE_MIB__\"/${ROOT_SIZE_MIB}/" \
    "$TEMPLATE" > "$OUT_CONFIG"

archinstall --config "$OUT_CONFIG" --creds "$CREDS" --silent

echo "[archproject] install complete, rebooting in 5 seconds..."
sleep 5
reboot
