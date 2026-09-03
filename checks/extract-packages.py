#!/usr/bin/env python3
"""Extracts every package name referenced anywhere in the repo, split by
how it's installed:
- pacman_packages: every `name:` value on a `pacman:` task across all
  roles, plus the group_vars list variables those tasks reference by
  Jinja (since this script doesn't render Jinja, the raw lists are pulled
  in directly too).
- aur_packages: group_vars' experimental_packages, installed via the AUR
  helper command rather than the pacman module - may live in the AUR only.

Uses a real YAML parser instead of regex, since the ad-hoc regex used
mid-session missed some list formats.
"""
import glob
import sys
import yaml

REPO = "/repo"


def normalize_names(name_field):
    if isinstance(name_field, str):
        return [name_field]
    if isinstance(name_field, list):
        return [n for n in name_field if isinstance(n, str)]
    return []


def main():
    pacman_packages = set()

    for path in sorted(glob.glob(f"{REPO}/roles/*/tasks/*.yml")):
        with open(path) as f:
            tasks = yaml.safe_load(f) or []
        if not isinstance(tasks, list):
            continue
        for task in tasks:
            if not isinstance(task, dict):
                continue
            pacman_task = task.get("pacman")
            if isinstance(pacman_task, dict):
                pacman_packages.update(normalize_names(pacman_task.get("name")))

    with open(f"{REPO}/group_vars/all.yml") as f:
        group_vars = yaml.safe_load(f) or {}

    aur_packages = set(group_vars.get("experimental_packages", []))

    for key in ("base_packages", "desktop_packages_kde", "everyday_apps", "gaming_packages"):
        pacman_packages.update(group_vars.get(key, []))

    # Drop unresolved Jinja templates - can't check these directly.
    pacman_packages = {p for p in pacman_packages if isinstance(p, str) and "{{" not in p}
    aur_packages = {p for p in aur_packages if isinstance(p, str) and "{{" not in p}

    # Quoted, for `eval "$(...)"` in the calling shell script - unquoted
    # output gets parsed as a command line, not a variable assignment.
    print('PACMAN_PACKAGES="' + " ".join(sorted(pacman_packages)) + '"')
    print('AUR_PACKAGES="' + " ".join(sorted(aur_packages)) + '"')


if __name__ == "__main__":
    main()
