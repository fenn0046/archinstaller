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

# --- Safety: never silently re-wipe an existing install -------------------
# Learned the destructive way. With the ISO still attached, the firmware
# boots this live medium again, .automated_script.sh fires unconditionally
# on tty1, and this script would happily wipe a perfectly good fresh
# install a second time. That happened, and the half-finished second wipe
# left the disk unrecoverable - the whole install had to be redone.
#
# So: if the target already carries a bootloader at the UEFI fallback path
# we install to, treat it as an existing install and refuse. Set
# ARCHPROJECT_FORCE_WIPE=1 to deliberately override.
looks_already_installed() {
  local disk="$1" part1 tmpmnt rc=1
  part1=$(lsblk -pnro NAME "$disk" 2>/dev/null | sed -n '2p')
  [ -n "$part1" ] || return 1
  [ "$(lsblk -dnro FSTYPE "$part1" 2>/dev/null)" = "vfat" ] || return 1
  tmpmnt=$(mktemp -d)
  if mount -o ro "$part1" "$tmpmnt" 2>/dev/null; then
    [ -f "$tmpmnt/EFI/BOOT/BOOTX64.EFI" ] && rc=0
    umount "$tmpmnt" 2>/dev/null || true
  fi
  rmdir "$tmpmnt" 2>/dev/null || true
  return $rc
}

if [ "${ARCHPROJECT_FORCE_WIPE:-0}" != "1" ] && looks_already_installed "$TARGET_DISK"; then
  echo "" >&2
  echo "===================================================================" >&2
  echo " REFUSING TO WIPE - $TARGET_DISK ALREADY HAS AN INSTALL" >&2
  echo "===================================================================" >&2
  echo "" >&2
  echo " Found a bootloader at EFI/BOOT/BOOTX64.EFI on $TARGET_DISK, so this" >&2
  echo " disk was almost certainly installed to already - most likely by a" >&2
  echo " previous run of this very ISO." >&2
  echo "" >&2
  echo " You are seeing this because the machine booted the installer ISO" >&2
  echo " again instead of the installed disk. Fix that, don't re-install:" >&2
  echo "   1. Power off." >&2
  echo "   2. Disconnect the ISO from the VM's optical drive." >&2
  echo "   3. Power on - it should boot the installed system." >&2
  echo "" >&2
  echo " To deliberately wipe and reinstall anyway, run:" >&2
  echo "   ARCHPROJECT_FORCE_WIPE=1 /root/archproject-bootstrap/auto-install.sh" >&2
  echo "" >&2
  exit 1
fi

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

# Deliberately NOT ejecting from in here, despite the obvious appeal.
# archiso's releng profile does not use copytoram: this live system reads
# from the disc for its entire life. So `eject` either fails outright
# ("device is busy", because the kernel holds the squashfs open) or, worse,
# succeeds at the SCSI level and pulls the root filesystem out from under
# the running script - after which even `reboot` can't be exec'd, and the
# install just sits there having apparently done nothing. That is exactly
# what an earlier version of this script did.
#
# A human disconnecting the ISO host-side is reliable, instant, and can't
# break the running system. So: stop and ask.
echo ""
echo "==================================================================="
echo " INSTALL COMPLETE"
echo "==================================================================="
echo ""
echo " Disconnect the installer ISO NOW, before rebooting - otherwise the"
echo " firmware will boot straight back into this live medium instead of"
echo " the disk that was just installed to."
echo ""
echo "   VMware:       VM > Removable Devices > CD/DVD > Disconnect"
echo "                 (also untick 'Connect at power on' in VM settings)"
echo "   VirtualBox:   Devices > Optical Drives > Remove disk from drive"
echo "   virt-manager: detach the CDROM device"
echo ""
echo " (This can't be done reliably from inside here: the live system is"
echo "  running FROM that disc, so the kernel holds it busy.)"
echo ""
echo " If you reboot with the ISO still attached, nothing is destroyed -"
echo " this installer now detects the existing install and refuses to wipe"
echo " it - but you'll just land back here instead of in your new system."
echo ""
printf " Once the ISO is disconnected, press Enter to reboot... "
read -r _ || true
echo ""
echo "[archproject] rebooting..."
reboot
