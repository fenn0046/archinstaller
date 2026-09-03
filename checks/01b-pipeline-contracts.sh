#!/usr/bin/env bash
# Tier 1b: static assertions about the seam between the baked installer and
# the Ansible playbook - the one region Tier 4 structurally cannot check,
# because 04-smoke-test.sh deliberately disables the first-boot service and
# passes reboot_after_provision=false to stop it racing its own invocation.
#
# Two real blockers lived in exactly that gap and survived every other tier:
#
#   1. roles/finalize used ansible.builtin.reboot, which hard-refuses to run
#      over a local connection ("would reboot the control node") - and this
#      playbook always runs locally on the target. The last task of every
#      run failed, unconditionally.
#   2. The first-boot service's "don't run again" step was a `systemctl
#      disable` placed AFTER ansible-playbook - but the playbook's job is to
#      trigger a reboot that kills the script before it gets there. Success
#      meant re-provisioning and rebooting on every subsequent boot, forever.
#
# Both are cheap to assert statically, so they're asserted here rather than
# left to a 20-minute VM boot to discover.
set -uo pipefail

pacman -Syu --noconfirm --needed python-yaml >/tmp/pkg-sync.log 2>&1

python3 - <<'PY'
import json
import pathlib
import sys
import yaml

REPO = pathlib.Path("/repo")
MARKER = "/var/lib/arch-project/provisioned"
failures = []


def check(ok, message):
    if not ok:
        failures.append(message)


# --- 1. The shared archinstall config template is valid JSON -------------
template_path = REPO / "bootstrap/user_configuration.template.json"
template_text = template_path.read_text()
try:
    template = json.loads(template_text)
except json.JSONDecodeError as exc:
    print(f"FAIL: {template_path} is not valid JSON: {exc}")
    print("\nTIER 1b: FAILED")
    sys.exit(1)

custom = template["custom_commands"][0]

# --- 2. The first-boot unit refuses to re-run once provisioning is done ---
check(
    f"ConditionPathExists=!{MARKER}" in custom,
    f"The first-boot systemd unit in custom_commands[0] is missing\n"
    f"        ConditionPathExists=!{MARKER}\n"
    f"        Without it, a successful run reboots before the script's trailing\n"
    f"        `systemctl disable` can execute, so the service re-provisions and\n"
    f"        reboots on every boot, forever.",
)

# --- 3. ...and something actually creates that marker --------------------
finalize_path = REPO / "roles/finalize/tasks/main.yml"
finalize_tasks = yaml.safe_load(finalize_path.read_text()) or []
writes_marker = any(
    isinstance(t, dict)
    and isinstance(t.get("copy"), dict)
    and t["copy"].get("dest") == MARKER
    for t in finalize_tasks
)
check(
    writes_marker,
    f"{finalize_path.relative_to(REPO)} never writes {MARKER}.\n"
    f"        The systemd ConditionPathExists guard above depends on it, so the\n"
    f"        two halves must stay in sync or the guard silently never fires.",
)

# --- 4. Nothing uses the reboot module over a local connection -----------
inventory = (REPO / "inventory/hosts.ini").read_text()
if "ansible_connection=local" in inventory:
    for path in sorted(REPO.glob("roles/*/tasks/*.yml")) + sorted(
        REPO.glob("roles/*/handlers/*.yml")
    ):
        tasks = yaml.safe_load(path.read_text()) or []
        if not isinstance(tasks, list):
            continue
        for task in tasks:
            if not isinstance(task, dict):
                continue
            if "reboot" in task or "ansible.builtin.reboot" in task:
                check(
                    False,
                    f"{path.relative_to(REPO)} uses the `reboot` module, but the\n"
                    f"        inventory is ansible_connection=local. ansible-core's\n"
                    f"        reboot action plugin hard-fails on local connections\n"
                    f"        ('would reboot the control node'). Use a fire-and-forget\n"
                    f"        `shell: sleep 5 && systemctl reboot` with async/poll: 0.",
                )

# --- 5. Placeholders and their substituting consumers stay in sync -------
for placeholder in ("__DISK_DEVICE__", '"__ROOT_SIZE_MIB__"'):
    check(
        placeholder in template_text,
        f"{template_path.relative_to(REPO)} no longer contains {placeholder}.",
    )

consumers = [
    "bootstrap/detect-disk-and-install.sh",
    "iso/overlay/airootfs/root/archproject-bootstrap/auto-install.sh",
    "checks/lib-gen-config.sh",
]
for consumer in consumers:
    text = (REPO / consumer).read_text()
    for placeholder in ("__DISK_DEVICE__", "__ROOT_SIZE_MIB__"):
        check(
            placeholder in text,
            f"{consumer} no longer substitutes {placeholder}. All three\n"
            f"        consumers must substitute both, or one flow silently ships a\n"
            f"        config with an unreplaced placeholder in it.",
        )

# --- 6. Both installer scripts eject the boot media before their reboot --
# Found on a real VM boot: with the ISO still attached as a virtual
# optical drive, most firmware boot orders put the CD-ROM ahead of the
# hard disk, so the post-archinstall reboot went straight back into the
# live medium instead of the disk just installed - which then re-ran the
# zero-confirmation installer against the same disk a second time. Fixed
# by ejecting the optical drive right before each script's own reboot;
# guarded here so a future edit to either script can't silently drop it.
for installer in (
    "bootstrap/detect-disk-and-install.sh",
    "iso/overlay/airootfs/root/archproject-bootstrap/auto-install.sh",
):
    text = (REPO / installer).read_text()
    eject_pos = text.find("eject ")
    reboot_pos = text.rfind("\nreboot")
    check(
        eject_pos != -1 and reboot_pos != -1 and eject_pos < reboot_pos,
        f"{installer} doesn't eject the boot media before its final "
        f"reboot.\n"
        f"        Without it, a VM with the ISO still attached as a virtual\n"
        f"        optical drive will likely boot back into this live medium\n"
        f"        instead of the just-installed disk, and re-run the\n"
        f"        zero-confirmation installer against it a second time.",
    )

# --- 7. The ESP partition carries the flag GRUB's UEFI path actually needs
# Found on a real VM boot, past every other tier: archinstall's
# _add_grub_bootloader() needs get_efi_partition(), which filters on
# PartitionFlag.ESP specifically - a distinct flag from PartitionFlag.BOOT,
# not an alias of it (confirmed against archinstall/lib/models/device.py:
# is_efi() checks ESP, is_boot() checks BOOT, and get_boot_partition() is a
# SEPARATE query used only for --boot-directory). A partition can satisfy
# is_boot() (so archinstall happily partitions, formats, and mounts it at
# /boot) while still failing is_efi(), and the failure only surfaces at
# grub-install time: 'ValueError: Could not detect efi partition'. Neither
# Tier 3 (archinstall --dry-run stops before bootloader install) nor Tier 4
# (nspawn has no real UEFI, so skip_grub_regen bypasses this entirely) can
# see this - it took an actual VM boot to find. Guarded here so the two
# flags can never silently drift apart again.
for mod in template.get("disk_config", {}).get("device_modifications", []):
    for part in mod.get("partitions", []):
        if part.get("mountpoint") == "/boot":
            flags = part.get("flags", [])
            check(
                "esp" in flags,
                f"{template_path.relative_to(REPO)}: the /boot partition's "
                f"flags are {flags!r}, missing 'esp'.\n"
                f"        archinstall's GRUB UEFI path needs get_efi_partition(),\n"
                f"        which requires PartitionFlag.ESP specifically -\n"
                f"        'boot' alone satisfies is_boot() (so partitioning and\n"
                f"        mounting succeed) but not is_efi(), and grub-install\n"
                f"        then fails with 'Could not detect efi partition'.",
            )
            check(
                "boot" in flags,
                f"{template_path.relative_to(REPO)}: the /boot partition's "
                f"flags are {flags!r}, missing 'boot'.\n"
                f"        Needed for get_boot_partition() (--boot-directory).",
            )

# --- Report -------------------------------------------------------------
if failures:
    for f in failures:
        print(f"FAIL: {f}")
    print("")
    print("TIER 1b: FAILED")
    sys.exit(1)

print("All pipeline contracts hold:")
print(f"  - first-boot unit guarded by ConditionPathExists=!{MARKER}")
print(f"  - roles/finalize writes {MARKER}")
print("  - no reboot module used with a local connection")
print("  - disk placeholders in sync across all 3 consumers")
print("  - both installer scripts eject boot media before rebooting")
print("  - /boot partition carries both 'boot' and 'esp' flags")
print("")
print("TIER 1b: PASSED")
PY
