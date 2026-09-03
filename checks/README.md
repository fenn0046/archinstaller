# Pre-flight checks

**Run `checks/run-all.ps1` before every VM test, not just once.** Arch
package names drift over time regardless of what changed in this repo, so
even an unrelated change is worth a quick re-check.

```powershell
.\checks\run-all.ps1              # all four tiers (~15-20 min, dominated by Tier 4)
.\checks\run-all.ps1 -SkipTier4   # tiers 1-3 only (~2 min) - use while iterating
```

Every tier runs inside a Podman container (`archlinux:latest`, using the
same machine `iso/build-iso.ps1` uses) - nothing installs anything on the
host, and nothing here can touch a real disk.

## What each tier catches

Each of these maps to a real bug found the hard way, via an actual failed
VM boot, before this system existed:

| Tier | What it does | What it would have caught |
|---|---|---|
| 1. Syntax & lint | `ansible-playbook --syntax-check`, `--list-tasks`, `ansible-lint` | Broken YAML/Jinja, unresolvable role/task references, deprecated modules (e.g. the `ansible_mounts` deprecation warning) |
| 2. Package names | Every package referenced anywhere in the repo, checked against **live current** Arch repos | `xf86-video-vmware` and `nvidia`/`nvidia-dkms` being removed from the repos entirely |
| 3. archinstall dry-run | Real `archinstall --dry-run` against a disposable loopback disk | `sector_size: null`, missing `dev_path`, `Unit.Percent` not existing - all schema mismatches between the official upstream sample and what's actually packaged |
| 4. Full smoke test | Real (non-dry-run) `archinstall` install to a loopback disk, then boots that install under `systemd-nspawn` and runs `ansible-playbook site.yml` for real, twice (idempotency check) | The `snapper create-config` vs. pre-mounted `@.snapshots` conflict - the one category nothing else here can see, since it only shows up once real filesystem operations happen. Also catches most task-logic and idempotency bugs. |

## Honest limitations

Tier 4 gets very close to a real VM boot (real partitioning, real Btrfs
subvolumes, real package installs, a real systemd instance via
`systemd-nspawn --boot` so `systemctl enable/start` tasks behave like they
would in a VM) but it cannot validate:

- Actual UEFI firmware boot / GRUB installing to a real ESP and being
  bootable
- Real GPU driver loading against actual (or virtual) hardware
- SDDM actually reaching a visible login screen

Those still need a real VM boot. Tier 4 is built to catch the large
majority of what's failed so far before spending the time on that boot -
not to replace it entirely.

**Tier 4 also has a real, confirmed reliability ceiling worth knowing
about**, found through extensive testing while building this: the nested
virtualization stack it runs on (WSL2 -> Podman -> a loopback file ->
Btrfs -> systemd-nspawn) reproducibly hits a genuine storage-layer I/O
error (`[Errno 5] Input/output error` reading `/bin/sh`) around
`roles/apps`' package-install burst - the point where cumulative writes
since the start of the run (base + LTS kernel + KDE + AUR build tools +
apps) are largest. This was tested against 24G, 48G, and 80G disks (ruled
out disk space), after a full container/image prune (ruled out leaked
state), and after a full `podman machine` restart (ruled out transient
daemon state) - the same failure recurred at the same task boundary every
time. This looks like a real limit of this specific 4-layer-deep storage
nesting under sustained heavy write volume, not a bug in this repo's
config, and not something more retries or disk headroom fixes.

Two real bugs *were* found and fixed this way, so Tier 4 is not just
theoretical value: a race in `roles/base` where the pacman keyring's trust
database wasn't guaranteed current before the first install (now fixed
with an explicit `pacman-key --populate`), and a runaway recursion bug in
`checks/lib-devnode-shims.sh` itself (a shimmed command's own internal
`blkid` call resolved back through the shim instead of the real binary,
each layer re-triggering the next) that looked identical to environment
flakiness until traced down. `checks/04-smoke-test.sh` retries both the
archinstall step and each ansible-playbook run a few times regardless,
since transient network/mirror hiccups (a real, separate, and genuinely
recoverable issue) are common and ansible-playbook is idempotent, so
retrying after any hiccup is safe.

**Practical takeaway**: Tier 4 reliably validates everything through
`roles/desktop` and into `roles/apps` (proven correct, repeatedly, in this
environment). Getting further (`gaming`, `dotfiles`, `experimental`,
`finalize`) in this specific nested setup may require the real target
environment (an actual VM) rather than this container-based simulation -
Tiers 1-3 plus Tier 4's partial run still catch the overwhelming majority
of what's failed so far, and a Tier 4 failure at this specific storage
ceiling isn't a signal the code itself is broken.

## Validating the checks themselves

Don't just trust a new check because it was written carefully - prove it
catches what it claims to. E.g. to confirm Tier 4 actually would have
caught the snapper bug: temporarily re-add `{"name": "@.snapshots",
"mountpoint": "/.snapshots"}` to a scratch copy of
`bootstrap/user_configuration.template.json`, point Tier 4's script at
the scratch copy, and confirm it fails with the same
`snapper: subvolume already exists` error seen on the real VM. Then
confirm it passes clean against the real (fixed) template.
