#!/usr/bin/env python3
"""Runs inside the build container. Builds the ISO's baked archinstall
config from the shared bootstrap/ template, adding forced password expiry.
That's only appropriate here because the ISO's credentials are a public,
temporary placeholder (see iso/README.md) - the manual bootstrap/ flow
(detect-disk-and-install.sh) uses a real password the user sets themselves
and does NOT force-expire it.
"""
import json

SRC = "/repo/bootstrap/user_configuration.template.json"
DEST = "/tmp/profile/airootfs/root/archproject-bootstrap/user_configuration.json"

with open(SRC) as f:
    config = json.load(f)

config["custom_commands"].append(
    "chage -d 0 archuser\n"
    "chage -d 0 root\n"
    "echo '[archproject] forced password change armed for archuser and root'"
)

with open(DEST, "w") as f:
    json.dump(config, f, indent=2)

print(f"Wrote {DEST}")
