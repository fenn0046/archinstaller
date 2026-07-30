# Builds a custom Arch ISO with the archproject unattended installer baked
# in. archiso (mkarchiso) needs real Arch package tooling that doesn't exist
# on Windows, so this runs it inside a privileged archlinux container via
# the Podman machine already set up on this box - no WSL Arch distro needed.
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

$machineState = (podman machine list --format json | ConvertFrom-Json)
if (-not ($machineState | Where-Object { $_.Running })) {
    Write-Output "Starting podman machine..."
    podman machine start
}

$containerScript = @'
set -euo pipefail
pacman -Sy --noconfirm --needed archiso python archlinux-keyring

cp -r /usr/share/archiso/configs/releng /tmp/profile
cp -r /repo/iso/overlay/airootfs/. /tmp/profile/airootfs/
cat /repo/iso/overlay-packages.x86_64 >> /tmp/profile/packages.x86_64

sed -i 's/iso_name="archlinux"/iso_name="archproject"/' /tmp/profile/profiledef.sh
cat >> /tmp/profile/profiledef.sh <<'PERM_EOF'
file_permissions+=( ["/root/archproject-bootstrap/auto-install.sh"]="0:0:755" )
PERM_EOF

python3 /repo/iso/generate-config.py

mkarchiso -v -w /tmp/work -o /repo/iso/out /tmp/profile
'@

podman run --rm --privileged `
    -v "${RepoRoot}:/repo" `
    -w /repo `
    archlinux:latest bash -c $containerScript

if ($LASTEXITCODE -ne 0) {
    Write-Error "Build failed (exit $LASTEXITCODE) - see output above."
    exit $LASTEXITCODE
}

Write-Output "Done. ISO written to $OutDir"
