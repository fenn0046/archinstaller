#!/usr/bin/env bash
# Tier 2: every package name referenced anywhere in the repo, checked
# against LIVE current Arch repos (fresh pacman -Sy in this container, not
# a stale local cache) - catches renamed/removed packages like
# xf86-video-vmware and nvidia before a VM test does.
set -uo pipefail

# -Syu, not -Sy --needed: see checks/01 for why.
pacman -Syu --noconfirm --needed python-yaml curl >/tmp/pkg-sync.log 2>&1

if ! grep -q '^\[multilib\]' /etc/pacman.conf; then
  cat >> /etc/pacman.conf <<'EOF'
[multilib]
Include = /etc/pacman.d/mirrorlist
EOF
  pacman -Syu --noconfirm >>/tmp/pkg-sync.log 2>&1
fi

eval "$(python3 /repo/checks/extract-packages.py)"

echo "=== Pacman-installed packages ==="
MISSING=""
for pkg in $PACMAN_PACKAGES; do
  if pacman -Si "$pkg" >/dev/null 2>&1; then
    echo "OK: $pkg"
  else
    echo "MISSING: $pkg"
    MISSING="$MISSING $pkg"
  fi
done

echo ""
echo "=== AUR-helper-installed packages (official repos checked first, then AUR) ==="
AUR_MISSING=""
for pkg in $AUR_PACKAGES; do
  if pacman -Si "$pkg" >/dev/null 2>&1; then
    echo "OK (official repo): $pkg"
    continue
  fi
  RESULT=$(curl -fsS "https://aur.archlinux.org/rpc/v5/info/${pkg}" 2>/dev/null)
  COUNT=$(printf '%s' "$RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('resultcount', 0))" 2>/dev/null || echo 0)
  if [ "$COUNT" = "0" ]; then
    echo "MISSING (not in official repos or AUR): $pkg"
    AUR_MISSING="$AUR_MISSING $pkg"
  else
    echo "OK (AUR): $pkg"
  fi
done

echo ""
if [ -n "$MISSING" ] || [ -n "$AUR_MISSING" ]; then
  echo "TIER 2: FAILED - missing:$MISSING$AUR_MISSING"
  exit 1
fi
echo "TIER 2: PASSED"
