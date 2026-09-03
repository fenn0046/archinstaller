#!/usr/bin/env bash
# Tier 1: fast static checks. Catches YAML/Jinja syntax errors, broken
# role/task resolution, and (via ansible-lint) deprecated-module or
# undefined-variable classes of issue - the kind of thing that would
# otherwise only surface as a runtime warning or failure deep into a run.
set -uo pipefail

# -Syu (full upgrade), not just -Sy --needed: the archlinux:latest base
# image's own packages (glibc etc.) can lag behind what a freshly-pulled
# package like python3.14 actually needs, causing GLIBC version mismatches.
pacman -Syu --noconfirm --needed ansible ansible-lint >/tmp/pkg-sync.log 2>&1

cd /repo
FAIL=0

echo "=== ansible-playbook --syntax-check ==="
ansible-playbook site.yml --syntax-check
[ $? -eq 0 ] || FAIL=1

echo ""
echo "=== ansible-playbook --list-tasks ==="
ansible-playbook site.yml --list-tasks
[ $? -eq 0 ] || FAIL=1

echo ""
echo "=== ansible-lint (informational - findings shown, not a hard failure) ==="
ansible-lint site.yml || true

echo ""
if [ "$FAIL" -ne 0 ]; then
  echo "TIER 1: FAILED"
  exit 1
fi
echo "TIER 1: PASSED"
