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
print("")
print("TIER 1b: PASSED")
PY
