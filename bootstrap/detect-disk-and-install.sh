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

# The disk layout in the template is GPT with an ESP at /boot and no BIOS
# boot partition, so GRUB can only install in UEFI mode. Checked up front:
# otherwise this fails ~20 minutes in, at grub-install, with an obscure error.
if [ ! -d /sys/firmware/efi ]; then
  echo "This layout is GPT + ESP with no BIOS boot partition, so it requires" >&2
  echo "UEFI firmware - but this machine booted in legacy BIOS mode. Set the" >&2
  echo "VM/system firmware to UEFI and boot the installer again." >&2
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

# The installed archinstall's Unit enum has no "Percent" - the root
# partition's size must be an absolute value, computed from the real disk
# size minus the boot partition (1025 MiB) and a small safety margin for
# GPT's backup header/alignment.
DISK_BYTES=$(blockdev --getsize64 "$TARGET_DISK")
DISK_MIB=$(( DISK_BYTES / 1048576 ))
ROOT_SIZE_MIB=$(( DISK_MIB - 1025 - 4 ))

if [ "$ROOT_SIZE_MIB" -lt 1024 ]; then
  echo "Disk too small (${DISK_MIB} MiB) for this partition layout." >&2
  exit 1
fi

sed -e "s#__DISK_DEVICE__#${TARGET_DISK}#" \
    -e "s/\"__ROOT_SIZE_MIB__\"/${ROOT_SIZE_MIB}/" \
    "$TEMPLATE" > "$OUT_CONFIG"

archinstall --config "$OUT_CONFIG" --creds "$CREDS" --silent

# Deliberately NOT ejecting from in here. archiso's releng profile doesn't
# use copytoram: the live system reads from the disc for its entire life,
# so `eject` either fails ("device is busy") or succeeds at the SCSI level
# and yanks the root filesystem out from under this script - after which
# even `reboot` can't be exec'd. A human disconnecting the ISO host-side
# is reliable and can't break the running system, so ask instead.
echo ""
echo "==================================================================="
echo " INSTALL COMPLETE"
echo "==================================================================="
echo ""
echo " Disconnect the installer ISO NOW, before rebooting - otherwise the"
echo " firmware will likely boot back into the live medium instead of the"
echo " disk just installed to."
echo ""
echo "   VMware:       VM > Removable Devices > CD/DVD > Disconnect"
echo "                 (also untick 'Connect at power on' in VM settings)"
echo "   VirtualBox:   Devices > Optical Drives > Remove disk from drive"
echo "   virt-manager: detach the CDROM device"
echo ""
printf " Once the ISO is disconnected, press Enter to reboot... "
read -r _ || true
echo ""
echo "Rebooting..."
reboot
