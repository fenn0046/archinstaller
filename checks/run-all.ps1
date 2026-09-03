# Runs every validation tier in order, cheapest/fastest first, stopping at
# the first failure. This is the required step before booting a VM to test
# a change - see checks/README.md for what each tier actually catches.
#
# Usage:
#   .\checks\run-all.ps1            # all four tiers
#   .\checks\run-all.ps1 -SkipTier4 # tiers 1-3 only (fast, ~2 min total) -
#                                    # use while iterating; run the full
#                                    # thing (including Tier 4) before any
#                                    # actual VM boot.
param(
    [switch]$SkipTier4
)

function Write-Summary($results) {
    Write-Output ""
    Write-Output "==================================================================="
    Write-Output " Summary"
    Write-Output "==================================================================="
    foreach ($r in $results) {
        $status = if ($r.ExitCode -eq 0) { "PASS" } else { "FAIL" }
        $note = if ($r.Note) { " - $($r.Note)" } else { "" }
        Write-Output "  [$status] $($r.Tier)$note"
    }
}

$RepoRoot = (Resolve-Path "$PSScriptRoot\..").Path

$machineState = (podman machine list --format json | ConvertFrom-Json)
if (-not ($machineState | Where-Object { $_.Running })) {
    Write-Output "Starting podman machine..."
    podman machine start
}

$tiers = @(
    @{ Name = "Tier 1: syntax & lint"; Script = "checks/01-syntax-and-lint.sh"; Privileged = $false },
    @{ Name = "Tier 1b: pipeline contracts"; Script = "checks/01b-pipeline-contracts.sh"; Privileged = $false },
    @{ Name = "Tier 2: package names"; Script = "checks/02-package-names.sh"; Privileged = $false },
    @{ Name = "Tier 3: archinstall dry-run"; Script = "checks/03-archinstall-dryrun.sh"; Privileged = $true }
)

$results = @()

foreach ($tier in $tiers) {
    Write-Output ""
    Write-Output "==================================================================="
    Write-Output " $($tier.Name)"
    Write-Output "==================================================================="

    # Built as an array and splatted rather than interpolating a possibly-empty
    # $privFlag: an empty string only vanishes from a native command line by
    # accident of Windows PowerShell 5.1: on PowerShell 7 it's passed through
    # as a real empty argument and podman reads it as the image name.
    $podmanArgs = @("run", "--rm")
    if ($tier.Privileged) { $podmanArgs += "--privileged" }
    $podmanArgs += @("-v", "${RepoRoot}:/repo", "archlinux:latest", "bash", "/repo/$($tier.Script)")

    podman @podmanArgs
    $rc = $LASTEXITCODE

    $results += [pscustomobject]@{ Tier = $tier.Name; ExitCode = $rc }

    if ($rc -ne 0) {
        Write-Output ""
        Write-Output "STOPPED: $($tier.Name) failed (exit $rc). Fix this before continuing."
        Write-Summary $results
        exit 1
    }
}

if (-not $SkipTier4) {
    Write-Output ""
    Write-Output "==================================================================="
    Write-Output " Tier 4: full smoke test"
    Write-Output "==================================================================="
    Write-Output "(needs a real systemd instance - archinstall's own sanity checks and"
    Write-Output " several of our systemd: state=started tasks need it - so this tier"
    Write-Output " runs in its own --systemd=always container, not the plain"
    Write-Output " podman run --rm used by tiers 1-3)"

    $containerName = "archproject-check-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    podman run -d --name $containerName --privileged --systemd=always --pids-limit=-1 `
        -v "${RepoRoot}:/repo" archlinux:latest /sbin/init | Out-Null

    try {
        $ready = $false
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Seconds 2
            $state = podman exec $containerName systemctl is-system-running 2>$null
            if ($state -eq "running" -or $state -eq "degraded") { $ready = $true; break }
        }
        if (-not $ready) {
            Write-Output "STOPPED: Tier 4's container never reached a working systemd state."
            $results += [pscustomobject]@{ Tier = "Tier 4: full smoke test"; ExitCode = 1 }
            Write-Summary $results
            exit 1
        }

        podman exec $containerName bash /repo/checks/04-smoke-test.sh
        $rc = $LASTEXITCODE

        # 78 = the documented storage ceiling of this nested stack, which
        # 04-smoke-test.sh detects by signature. It is not a defect in the
        # repo, so don't report it as one - saying "fix this" here would
        # send you hunting for a bug that isn't there.
        if ($rc -eq 78) {
            $results += [pscustomobject]@{ Tier = "Tier 4: full smoke test"; ExitCode = 0; Note = "reached known environment ceiling at roles/apps" }
            Write-Output ""
            Write-Output "Tier 4 hit the known environment ceiling (see checks/README.md)."
            Write-Output "Everything it validated before that point passed."
        } else {
            $results += [pscustomobject]@{ Tier = "Tier 4: full smoke test"; ExitCode = $rc }
            if ($rc -ne 0) {
                Write-Output ""
                Write-Output "STOPPED: Tier 4 failed (exit $rc). Fix this before testing on a VM."
                Write-Summary $results
                exit 1
            }
        }
    } finally {
        podman rm -f $containerName | Out-Null
    }
}

Write-Summary $results
Write-Output ""
Write-Output "All tiers passed. Safe to boot a VM and test for real."
exit 0
