#!/usr/bin/env python3
"""Runs inside the build container. Builds the ISO's baked archinstall
config from the shared bootstrap/ template.

Forced password expiry (archuser/root) is only appropriate for this ISO's
public, temporary placeholder credentials (see iso/README.md) - the manual
bootstrap/ flow (detect-disk-and-install.sh) uses a real password the user
sets themselves and must NOT force-expire it.

That expiry has to happen at the END of the Ansible run (roles/finalize),
not at archinstall install time: several roles use become_user: archuser
(aur/gaming/experimental), and the first-boot service itself does
`sudo -u archuser git clone`. Expiring the password any earlier makes sudo
refuse those non-interactively (PAM account-phase rejection applies
regardless of who invoked sudo) - the whole pipeline silently died on this
before Ansible ever ran a single task. So instead of injecting chage here,
this just adds -e force_password_expiry=true to the first-boot service's
existing ansible-playbook invocation, and roles/finalize handles the chage
itself once everything else has already run successfully.
"""
import json

SRC = "/repo/bootstrap/user_configuration.template.json"
DEST = "/tmp/profile/airootfs/root/archproject-bootstrap/user_configuration.json"

with open(SRC) as f:
    config = json.load(f)

marker = "ansible-playbook site.yml\n"
replacement = "ansible-playbook site.yml -e force_password_expiry=true\n"
if marker not in config["custom_commands"][0]:
    raise RuntimeError("Expected ansible-playbook invocation not found in bootstrap script - template changed?")
config["custom_commands"][0] = config["custom_commands"][0].replace(marker, replacement)

with open(DEST, "w") as f:
    json.dump(config, f, indent=2)

print(f"Wrote {DEST}")
