# Builds a custom Arch ISO with the archproject unattended installer baked
# in. archiso (mkarchiso) needs real Arch package tooling that doesn't exist
# on Windows, so this runs it inside a privileged archlinux container via
# the Podman machine already set up on this box - no WSL Arch distro needed.
#
# This prompts once for the password archuser/root will have on the installed
# system, hashes it inside the container, and bakes the hash into the ISO.
# That keeps the *install* zero-keystroke (nothing is asked on the VM) while
# keeping a real secret out of this public repo - the repo used to ship a
# hash of a publicly-known placeholder password instead.
#
# Note: deliberately no $ErrorActionPreference = "Stop" here. Native tools
# (podman, mkarchiso) write routine progress/warnings to stderr; PowerShell
# would otherwise wrap that as a terminating NativeCommandError even on
# success. Real failures are caught via explicit $LASTEXITCODE checks below.

$RepoRoot = (Resolve-Path "$PSScriptRoot\..").Path
$OutDir = Join-Path $PSScriptRoot "out"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# Fail fast (before a 10-15 min container build) if a prior ISO is still
# open elsewhere - most commonly a VM still attached to it as a CD-ROM.
Get-ChildItem -Path $OutDir -Filter "*.iso" -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        Remove-Item -Path $_.FullName -Force -ErrorAction Stop
    } catch {
        Write-Error "Cannot remove existing $($_.FullName) - it's likely still open (e.g. attached to a running VM). Detach/power off the VM using it and try again."
        exit 1
    }
}

# Prompt before the (slow) build rather than after, so a typo costs seconds.
Write-Output "This password will be set for both 'archuser' and 'root' on the installed system."
$secure1 = Read-Host "Password" -AsSecureString
$secure2 = Read-Host "Confirm password" -AsSecureString

$bstr1 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure1)
$bstr2 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure2)
try {
    $plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr1)
    $confirmPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr2)
} finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr1)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr2)
}

if ($plainPassword -ne $confirmPassword) {
    Write-Error "Passwords did not match."
    exit 1
}
if ([string]::IsNullOrWhiteSpace($plainPassword)) {
    Write-Error "Password cannot be empty."
    exit 1
}

$machineState = (podman machine list --format json | ConvertFrom-Json)
if (-not ($machineState | Where-Object { $_.Running })) {
    Write-Output "Starting podman machine..."
    podman machine start
}

$containerScript = @'
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
'@

$plainPassword | podman run -i --rm --privileged `
    -v "${RepoRoot}:/repo" `
    -w /repo `
    archlinux:latest bash -c $containerScript

$buildExit = $LASTEXITCODE
Remove-Variable plainPassword, confirmPassword -ErrorAction SilentlyContinue

if ($buildExit -ne 0) {
    Write-Error "Build failed (exit $buildExit) - see output above."
    exit $buildExit
}

Write-Output ""
Write-Output "Done. ISO written to $OutDir"
Write-Output "NOTE: this ISO now contains a real password hash for your system."
Write-Output "Treat it as a secret - don't upload or share the .iso file."
