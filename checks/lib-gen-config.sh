#!/usr/bin/env bash
# Shared by checks/03-archinstall-dryrun.sh and checks/04-smoke-test.sh.
# Mirrors the disk-size computation and placeholder substitution in
# bootstrap/detect-disk-and-install.sh and
# iso/overlay/airootfs/root/archproject-bootstrap/auto-install.sh - if that
# logic ever changes there, update it here too so the checks keep testing
# what actually runs.
gen_config() {
  local disk="$1" out="$2"
  local disk_bytes disk_mib root_size_mib
  disk_bytes=$(blockdev --getsize64 "$disk")
  disk_mib=$(( disk_bytes / 1048576 ))
  root_size_mib=$(( disk_mib - 1025 - 4 ))
  if [ "$root_size_mib" -lt 1024 ]; then
    echo "Disk too small (${disk_mib} MiB) for this partition layout." >&2
    return 1
  fi
  sed -e "s#__DISK_DEVICE__#${disk}#" \
      -e "s/\"__ROOT_SIZE_MIB__\"/${root_size_mib}/" \
      /repo/bootstrap/user_configuration.template.json > "$out"
}
