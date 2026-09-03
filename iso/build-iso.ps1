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

# The actual build steps live in iso/container-build.sh, invoked below by
# path - NOT embedded here as a string handed to `bash -c`. Windows
# PowerShell corrupts double-quote characters when it re-serializes a
# multi-line string argument for a native process's command line, which
# silently broke both the JSON credentials heredoc (every quote vanished,
# producing invalid JSON) and the iso_name rename sed (also silently a
# no-op) when this used to be inline. A plain file path has no embedded
# quoting for PowerShell to mangle.
$plainPassword | podman run -i --rm --privileged `
    -v "${RepoRoot}:/repo" `
    -w /repo `
    archlinux:latest bash /repo/iso/container-build.sh

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
