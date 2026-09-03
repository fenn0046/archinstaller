#!/usr/bin/env bash
# Tier 3: exercises the ENTIRE archinstall config-parsing path (disk
# layout with the real subvolume list, auth, bootloader, network, profile,
# audio, swap, custom_commands) against the real installed archinstall,
# using a disposable loopback disk - zero risk, catches schema drift like
# sector_size/dev_path/Percent before it ever reaches a VM.
set -uo pipefail
source /repo/checks/lib-gen-config.sh

# -Syu, not -Sy --needed: see checks/01 for why.
pacman -Syu --noconfirm --needed archinstall python util-linux >/tmp/pkg-sync.log 2>&1

truncate -s 20G /tmp/fakedisk.img
LOOPDEV=$(losetup -fP --show /tmp/fakedisk.img)
echo "Loop device: $LOOPDEV"

cleanup() {
  losetup -d "$LOOPDEV" 2>/dev/null || true
  rm -f /tmp/fakedisk.img
}
trap cleanup EXIT

if ! gen_config "$LOOPDEV" /tmp/test_config.json; then
  echo "TIER 3: FAILED (could not generate config)"
  exit 1
fi

echo "=== disk_config btrfs subvolume list ==="
python3 -c "
import json
d = json.load(open('/tmp/test_config.json'))
print(d['disk_config']['device_modifications'][0]['partitions'][1]['btrfs'])
"

echo ""
echo "=== Running archinstall --dry-run ==="
archinstall --config /tmp/test_config.json \
  --creds /repo/iso/overlay/airootfs/root/archproject-bootstrap/user_credentials.json \
  --silent --dry-run
RC=$?

echo ""
if [ "$RC" -ne 0 ]; then
  echo "TIER 3: FAILED"
  exit 1
fi
echo "TIER 3: PASSED"
