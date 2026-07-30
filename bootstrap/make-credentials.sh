#!/usr/bin/env bash
# Generates bootstrap/user_credentials.json interactively instead of
# hand-pasting `openssl passwd -6` output into JSON. Run this on the live
# ISO before detect-disk-and-install.sh. Never commit the resulting file.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$SCRIPT_DIR/user_credentials.json"

prompt_password() {
  local label="$1" pass1 pass2
  read -rsp "Password for $label: " pass1; echo >&2
  read -rsp "Confirm password for $label: " pass2; echo >&2
  if [ "$pass1" != "$pass2" ]; then
    echo "Passwords did not match for $label." >&2
    exit 1
  fi
  printf '%s' "$pass1"
}

USER_PASS="$(prompt_password archuser)"
ROOT_PASS="$(prompt_password root)"

# -stdin keeps the password out of argv/process listing.
USER_HASH="$(printf '%s' "$USER_PASS" | openssl passwd -6 -stdin)"
ROOT_HASH="$(printf '%s' "$ROOT_PASS" | openssl passwd -6 -stdin)"

cat > "$OUT" <<EOF
{
  "users": [
    {
      "sudo": true,
      "username": "archuser",
      "enc_password": "$USER_HASH"
    }
  ],
  "root_enc_password": "$ROOT_HASH"
}
EOF

chmod 600 "$OUT"
echo "Wrote $OUT"
