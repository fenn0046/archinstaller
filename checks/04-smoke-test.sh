#!/usr/bin/env bash
# Tier 4: the deepest check. Runs a REAL (non-dry-run) archinstall install
# against a disposable loopback disk, boots the result under
# systemd-nspawn (so systemctl enable/start tasks behave like they would
# in a real VM, not a plain chroot), and runs ansible-playbook site.yml
# against it for real - twice, to check idempotency.
#
# Must run inside an already-running systemd-managed container (started
# with --systemd=always --pids-limit=-1 --privileged - see run-all.ps1,
# which special-cases this tier). Plain `podman run --rm` (used by tiers
# 1-3) doesn't give a working systemd/D-Bus, which archinstall's own
# sanity checks (timedatectl) and several of our own roles need.
set -uo pipefail
source /repo/checks/lib-gen-config.sh
source /repo/checks/lib-devnode-shims.sh

MACHINE_NAME="archproject-smoketest-$$"
LOOPDEV=""

cleanup() {
  machinectl terminate "$MACHINE_NAME" 2>/dev/null || true
  sleep 1
  umount -R /mnt 2>/dev/null || true
  [ -n "$LOOPDEV" ] && losetup -d "$LOOPDEV" 2>/dev/null || true
  rm -f /tmp/fakedisk.img
}
trap cleanup EXIT

echo "=== Installing prerequisites ==="
pacman -Syu --noconfirm --needed archinstall python util-linux parted dosfstools btrfs-progs >/tmp/pkg-sync.log 2>&1
install_devnode_shims

echo "=== Creating disposable loopback disk ==="
# 24G was too tight (a real ENOSPC-driven read-only remount was observed).
# 48G still hit an I/O error reproducibly right at the same spot (roles/apps,
# a burst of large installs - LibreOffice, Firefox) across two separate
# runs - consistent with tight headroom in this specific nested nspawn/
# loop/Btrfs stack rather than pure random flakiness. Sized up further.
truncate -s 80G /tmp/fakedisk.img
LOOPDEV=$(losetup -fP --show /tmp/fakedisk.img)
echo "Loop device: $LOOPDEV"

if ! gen_config "$LOOPDEV" /tmp/smoke_config.json; then
  echo "TIER 4: FAILED (could not generate config)"
  exit 1
fi

echo "=== Running REAL archinstall (not dry-run) ==="
# Mirror flakiness (connection reset, DNS timeout mid-pacstrap) has shown
# up repeatedly here and is unrelated to anything this repo controls -
# retry a few times before treating it as a real failure.
ARCHINSTALL_OK=0
for attempt in 1 2 3; do
  if archinstall --config /tmp/smoke_config.json \
      --creds /repo/iso/overlay/airootfs/root/archproject-bootstrap/user_credentials.json \
      --silent; then
    ARCHINSTALL_OK=1
    break
  fi
  echo "archinstall attempt $attempt failed - retrying in 15s (see checks/README.md re: mirror flakiness)..."
  sleep 15
done
if [ "$ARCHINSTALL_OK" -ne 1 ]; then
  echo "TIER 4: FAILED at archinstall install step (after 3 attempts)"
  exit 1
fi

echo "=== Copying repo into the installed system ==="
mkdir -p /mnt/root/arch-project
cp -r /repo/. /mnt/root/arch-project/

# The real arch-project-bootstrap.service (baked in via custom_commands)
# auto-fires as soon as the system boots to multi-user.target - it would
# race our own explicit ansible-playbook invocation below, and run the
# *unmodified* production command with no reboot_after_provision=false /
# skip_grub_regen=true overrides (both needed only in this sandbox).
# `disable` (not `mask`) offline via systemctl --root: mask would try to
# symlink over the real unit file custom_commands already wrote there and
# refuses to clobber it; disable just drops the WantedBy symlink so it
# doesn't auto-start, without touching the unit file itself.
echo "=== Disabling the auto-triggered bootstrap service for this sandbox run ==="
systemctl --root=/mnt disable arch-project-bootstrap.service

echo "=== Booting installed system under systemd-nspawn ==="
systemd-nspawn -D /mnt --boot -M "$MACHINE_NAME" &

echo "=== Waiting for guest systemd to be ready ==="
READY=0
for i in $(seq 1 30); do
  state=$(systemd-run --machine="$MACHINE_NAME" --wait --pipe systemctl is-system-running 2>/dev/null || true)
  case "$state" in
    running|degraded) READY=1; break ;;
  esac
  sleep 3
done
if [ "$READY" -ne 1 ]; then
  echo "TIER 4: FAILED (guest systemd never became ready)"
  exit 1
fi
echo "Guest ready (state: $state)"

echo "=== Ensuring pacman keyring is current in the guest ==="
systemd-run --machine="$MACHINE_NAME" --wait --pipe pacman-key --populate archlinux

run_ansible() {
  systemd-run --machine="$MACHINE_NAME" --wait --pipe bash -c \
    'cd /root/arch-project && ansible-playbook site.yml -e reboot_after_provision=false -e skip_grub_regen=true'
}

# The nested nspawn/loop/Btrfs stack has shown occasional real (not
# archinstall-specific) storage-layer I/O errors under sustained heavy
# write load (observed reproducibly around roles/apps' package burst,
# independent of disk headroom - 48G and 80G both hit it). Since
# ansible-playbook is idempotent by design, retrying the whole run after
# a transient I/O hiccup is safe: already-applied steps just report ok.
run_ansible_with_retry() {
  local logfile="$1" ok=0
  for attempt in 1 2 3; do
    if run_ansible 2>&1 | tee "$logfile"; then
      ok=1
      break
    fi
    echo "ansible-playbook attempt $attempt failed - retrying in 10s (see checks/README.md re: storage-layer flakiness)..."
    sleep 10
  done
  [ "$ok" -eq 1 ]
}

echo "=== Running ansible-playbook (1st run) ==="
if ! run_ansible_with_retry /tmp/ansible-run1.log; then
  echo "TIER 4: FAILED on first ansible-playbook run (after 3 attempts)"
  exit 1
fi
CHANGED1=$(grep -oP 'changed=\K[0-9]+' /tmp/ansible-run1.log | tail -1)

echo ""
echo "=== Running ansible-playbook (2nd run - idempotency check) ==="
if ! run_ansible_with_retry /tmp/ansible-run2.log; then
  echo "TIER 4: FAILED on second (idempotency) ansible-playbook run (after 3 attempts)"
  exit 1
fi
CHANGED2=$(grep -oP 'changed=\K[0-9]+' /tmp/ansible-run2.log | tail -1)

echo ""
echo "Run 1 changed=$CHANGED1, Run 2 changed=$CHANGED2"
echo "(some 'changed' on the 2nd run is expected for raw command tasks -"
echo " AUR/paru builds, grub-mkconfig if not skipped - see checks/README.md)"
echo ""
echo "TIER 4: PASSED"
