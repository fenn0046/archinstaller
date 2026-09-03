# arch-project

Ansible automation that takes a fresh, minimal Arch install and turns it into
a fully working KDE Plasma desktop - hedging between a stable, always-boots
base and cutting-edge/experimental packages that are okay to break.

## Design

- **Stable core, cutting-edge edges.** Core system (kernel, GPU driver,
  desktop, everyday apps) is installed from official repos and expected to
  just work. Anything experimental lives behind `enable_experimental` and is
  installed from the AUR, kept separate so breakage stays contained.
- **Two independent safety nets, not one:**
  - `linux-lts` is always installed alongside the default `linux` kernel
    (`roles/base`), so a bad kernel/module update still leaves a bootable
    entry in GRUB.
  - If the root filesystem is Btrfs, `snapper` + `snap-pac` + `grub-btrfs`
    (`roles/snapshots`) take an automatic snapshot before/after every pacman
    transaction, and add "boot into snapshot" entries to GRUB. This is the
    real rollback mechanism - set up a Btrfs root subvolume when you partition
    the disk (in `archinstall` or manually) to get this for free.
- **Hardware-agnostic.** GPU vendor isn't hardcoded - `roles/gpu` detects it
  via `lspci` at run time and branches for AMD/Intel/Nvidia/virtio(QEMU)/
  VMware/VirtualBox. Run the same playbook unmodified on a VM now and real
  hardware later.

## Fully unattended install (disk -> finished desktop, zero prompts)

Two flavors, same underlying `archinstall` config and first-boot Ansible
handoff:

- [`bootstrap/README.md`](bootstrap/README.md) - boot the official Arch ISO,
  clone this repo, run one script. Has a typed confirmation before the disk
  gets wiped. Use this when you're supervising the install.
- [`iso/README.md`](iso/README.md) - a custom-built ISO with everything baked
  in, including credentials. Boot it and walk away - genuinely zero input,
  including no confirmation before the disk is wiped. Use this only on a
  machine/VM you specifically intend to wipe.

Either way, the machine partitions itself (Btrfs + subvolumes), installs the
base OS unattended via `archinstall`'s JSON config mode, reboots, and
automatically clones + runs this Ansible playbook on first boot with no
further input. This is the intended way to (re)build the machine from
scratch, including on a fresh VM after a snapshot revert.

## Prerequisites (if running this repo manually instead)

1. Base Arch install (e.g. via `archinstall`), with:
   - **Btrfs root** if you want the snapshot rollback safety net (recommended).
   - Networking already up.
   - A sudo-capable user named `archuser` (or update `aur_build_user` in
     `group_vars/all.yml` to match whatever account you actually created).
2. Inside the installed system:
   ```
   pacman -S --needed ansible git
   ```
3. Clone this repo and review `group_vars/all.yml` (desktop, package lists,
   dotfiles repo URL if any, experimental toggle).

## AUR / sudoers note

AUR packages (`roles/aur`, `roles/experimental`, `roles/gaming`) are built via
`makepkg`/`paru` as `aur_build_user` (hardcoded to `archuser` in
`group_vars/all.yml` rather than auto-detected, since the unattended
first-boot service runs `ansible-playbook` directly as root with no invoking
sudo user to detect), because `makepkg` refuses to run as root.

`makepkg`/`paru` themselves need to escalate from that account back up to
root internally (to actually install the package) - `roles/aur` grants
`aur_build_user` passwordless sudo for exactly this, automatically, on every
run. `roles/finalize` revokes it again once provisioning finishes, unless
`keep_passwordless_sudo: true` is set in `group_vars/all.yml`. No manual
sudoers setup needed for either flow.

## Before testing on a VM

Run `checks/run-all.ps1` first, every time - not just once. It's a layered
validation pipeline (syntax/lint, live package-name check, a real
`archinstall --dry-run`, and a full smoke test that actually partitions a
disposable loopback disk and runs this playbook for real, twice) that runs
entirely inside a container in a couple minutes to ~20 minutes depending on
how much of it you run, and exists specifically because most of the bugs
found while building this were things a VM boot cycle is a slow, expensive
way to discover. See [`checks/README.md`](checks/README.md) for what each
tier catches and why.

## Running it manually

```
ansible-playbook site.yml --ask-become-pass
```

## Structure

```
checks/                # pre-flight validation pipeline - run before every VM test
bootstrap/             # supervised unattended install: archinstall config + disk-detect script
iso/                   # fully baked, zero-input custom ISO build (Podman-based)
site.yml               # main playbook, role order
group_vars/all.yml     # all tunables: desktop choice, package lists, toggles
roles/
  base/                # packages, NetworkManager, reflector, LTS kernel
  snapshots/           # snapper + grub-btrfs (skips gracefully if not Btrfs)
  gpu/                 # lspci-based driver detection/install
  aur/                 # paru bootstrap
  desktop/             # KDE Plasma + SDDM
  apps/                # everyday applications
  gaming/              # Steam/gamemode/mangohud + multilib repo enablement
  dotfiles/            # optional chezmoi-managed dotfiles
  experimental/        # opt-in AUR sandbox packages
```

## Extending

- Add packages to the relevant list in `group_vars/all.yml`.
- Add new experimental/fun things to `experimental_packages` and flip
  `enable_experimental: true` - this is the intended sandbox for things that
  might break.
- Point `dotfiles_repo` at a chezmoi-managed dotfiles repo to have configs
  applied automatically on deploy.
