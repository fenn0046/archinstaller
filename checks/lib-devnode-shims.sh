#!/usr/bin/env bash
# udev doesn't reliably work for loop-device partitions in this nested
# Podman/WSL2 environment - confirmed two separate gaps (neither fixed by
# --network=host, so not a netns/uevent-visibility issue specifically):
#
# 1. The kernel recognizes new loop partitions in /proc/partitions
#    immediately, but nothing turns that into an actual /dev/loopNpM node -
#    udevd running as a background daemon, even started before
#    partitioning, never creates it. A background poller racing archinstall's
#    own wipefs/mkfs calls loses even at a 0.02s interval.
# 2. Even once a node exists (e.g. via manual mknod), `lsblk`'s PARTN/
#    PARTUUID/UUID columns come from udev's device database
#    (/run/udev/data/b<major>:<minor>), not direct blkid probing - `blkid`
#    itself reads PARTUUID fine directly, but lsblk doesn't fall back to
#    that. archinstall's fetch_part_info() requires exactly those lsblk
#    columns and raises DiskError without them.
#
# Fix for both: shim every command archinstall calls directly on a
# partition device path, so each one (a) creates its target node from
# /proc/partitions using the kernel's real major:minor, and (b) refreshes
# a minimal udev db entry from blkid's direct probing - synchronously,
# inline, exactly when needed, no race. Only used by
# checks/04-smoke-test.sh (a REAL archinstall install, unlike Tier 3's
# --dry-run) inside the check container - never touches the real install
# paths (bootstrap/, iso/) or a real disk.
#
# The exact set of commands needing this was discovered incrementally by
# running real installs, not derived up front - wipefs and mkfs.* first,
# then lsblk/blkid/umount once a retried install hit the same class of
# failure (a not-yet-existing node) via a code path that calls them
# directly instead of through an already-shimmed command. If a future
# archinstall version calls something else directly on a partition path,
# the same fix applies: add it to the loop below.
install_devnode_shims() {
  mkdir -p /usr/local/bin /run/udev/data

  cat > /usr/local/bin/_ensure_devnode <<'HELPER_EOF'
#!/usr/bin/env bash
# Usage: _ensure_devnode /dev/loop0pN
dev="$1"
[ -e "$dev" ] || {
  base=$(basename "$dev")
  while read -r major minor blocks name; do
    if [ "$name" = "$base" ]; then
      mknod "$dev" b "$major" "$minor"
    fi
  done < <(tail -n +3 /proc/partitions)
}
[ -e "$dev" ] || exit 0

major_minor=$(stat -c '%t:%T' "$dev" 2>/dev/null)
[ -n "$major_minor" ] || exit 0
maj_dec=$((16#${major_minor%%:*}))
min_dec=$((16#${major_minor##*:}))
dbfile="/run/udev/data/b${maj_dec}:${min_dec}"

partn=$(cat "/sys/class/block/$(basename "$dev")/partition" 2>/dev/null || true)
# Absolute path, not bare `blkid`: blkid is itself one of the shimmed
# commands below (PATH puts /usr/local/bin first), so calling it by name
# here would recurse into the shim, which calls _ensure_devnode again,
# which calls blkid again... unbounded recursion that manifested as
# fork() exhaustion (BlockingIOError/EAGAIN) once blkid was added to the
# shim list, not the sporadic infra flakiness it looked like at first.
partuuid=$(/usr/bin/blkid -s PARTUUID -o value "$dev" 2>/dev/null || true)
fsuuid=$(/usr/bin/blkid -s UUID -o value "$dev" 2>/dev/null || true)
fstype=$(/usr/bin/blkid -s TYPE -o value "$dev" 2>/dev/null || true)
now_usec=$(( $(date +%s%N) / 1000 ))

# Real udev db entries need the I: (initialized-timestamp) header line -
# without it lsblk treats the whole record as not-yet-ready and withholds
# fields even when present. UUID specifically needs the _ENC (percent-
# encoded) property, not just the plain one - lsblk reads that variant,
# not ID_FS_UUID directly (confirmed: ID_FS_TYPE alone worked with just
# the I: line added; UUID stayed null until ID_FS_UUID_ENC was added too).
{
  echo "I:${now_usec}"
  [ -n "$partn" ] && echo "E:ID_PART_ENTRY_NUMBER=${partn}"
  [ -n "$partuuid" ] && echo "E:ID_PART_ENTRY_UUID=${partuuid}"
  if [ -n "$fsuuid" ]; then
    echo "E:ID_FS_UUID=${fsuuid}"
    echo "E:ID_FS_UUID_ENC=${fsuuid}"
  fi
  [ -n "$fstype" ] && echo "E:ID_FS_TYPE=${fstype}"
} > "$dbfile"
HELPER_EOF
  chmod +x /usr/local/bin/_ensure_devnode

  for cmd in wipefs mkfs.fat mkfs.vfat mkfs.btrfs mount lsblk blkid umount; do
    real=$(command -v "$cmd" 2>/dev/null) || continue
    cat > "/usr/local/bin/${cmd}" <<SHIM_EOF
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    /dev/*) /usr/local/bin/_ensure_devnode "\$arg" ;;
  esac
done
${real} "\$@"
rc=\$?
for arg in "\$@"; do
  case "\$arg" in
    /dev/*) /usr/local/bin/_ensure_devnode "\$arg" ;;
  esac
done
exit \$rc
SHIM_EOF
    chmod +x "/usr/local/bin/${cmd}"
  done
}
