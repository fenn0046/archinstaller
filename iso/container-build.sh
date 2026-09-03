#!/usr/bin/env bash
# Runs inside the ephemeral build container, invoked by build-iso.ps1 as
# `bash /repo/iso/container-build.sh` (a real file path, not an inline
# string).
#
# This used to be a multi-line string embedded directly in build-iso.ps1
# and handed to `podman run ... bash -c $containerScript`. That silently
# corrupted every literal double-quote character in the script: Windows
# PowerShell re-serializes a string argument into a single Win32 command
# line before handing it to a native process, and its quoting logic drops
# embedded `"` characters in exactly this kind of multi-line, quote-heavy
# argument. Two real breakages resulted, both invisible until inspected
# byte-by-byte:
#   - the JSON credentials heredoc lost every quote (`{ "sudo": true, ... }`
#     became `{ sudo: true, ... }`) - invalid JSON, so archinstall's --creds
#     parser would fail on the actual VM, silently defeating the entire
#     point of a zero-touch install
#   - the `sed 's/iso_name="archlinux"/.../"'` rename also lost its quotes
#     and became a no-op, which is also why the ISO this repo built before
#     today was always named archlinux-*.iso instead of archproject-*.iso
# A real file path has none of this - podman only ever receives one plain
# argument with no embedded quoting for PowerShell to mangle.
set -euo pipefail

# Read the password from stdin, never argv - argv is visible to any other
# process via ps. Done first, before anything else can consume stdin.
read -r ARCHPROJECT_PASSWORD
# PowerShell terminates piped stdin with CRLF; a surviving \r would silently
# become part of the password and lock you out of the installed system.
ARCHPROJECT_PASSWORD="${ARCHPROJECT_PASSWORD%$'\r'}"

# -Syu, not -Sy --needed: the archlinux:latest base image's own packages
# (glibc etc.) can lag behind what freshly-pulled packages actually need,
# causing GLIBC version mismatches otherwise.
pacman -Syu --noconfirm --needed archiso python archlinux-keyring openssl

cp -r /usr/share/archiso/configs/releng /tmp/profile
cp -r /repo/iso/overlay/airootfs/. /tmp/profile/airootfs/
cat /repo/iso/overlay-packages.x86_64 >> /tmp/profile/packages.x86_64

# Generated into the build profile only - never written back into /repo.
CREDS_DIR=/tmp/profile/airootfs/root/archproject-bootstrap
mkdir -p "$CREDS_DIR"
HASH=$(printf '%s' "$ARCHPROJECT_PASSWORD" | openssl passwd -6 -stdin)
unset ARCHPROJECT_PASSWORD
cat > "$CREDS_DIR/user_credentials.json" <<CREDS_EOF
{
  "users": [
    { "sudo": true, "username": "archuser", "enc_password": "$HASH" }
  ],
  "root_enc_password": "$HASH"
}
CREDS_EOF
chmod 600 "$CREDS_DIR/user_credentials.json"

sed -i 's/iso_name="archlinux"/iso_name="archproject"/' /tmp/profile/profiledef.sh
cat >> /tmp/profile/profiledef.sh <<'PERM_EOF'
file_permissions+=( ["/root/archproject-bootstrap/auto-install.sh"]="0:0:755" )
file_permissions+=( ["/root/archproject-bootstrap/user_credentials.json"]="0:0:600" )
PERM_EOF

python3 /repo/iso/generate-config.py

mkarchiso -v -w /tmp/work -o /repo/iso/out /tmp/profile
