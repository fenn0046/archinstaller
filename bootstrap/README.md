# Unattended install (disk -> finished desktop, zero prompts)

This makes the *entire* pipeline hands-off: boot the Arch ISO, run one
command, and the machine partitions itself, installs the base OS, reboots,
and automatically clones+runs the main Ansible playbook on first boot -
no menu selections, no second command to type after reboot.

**This wipes the target disk.** Test on a disposable/snapshotted VM before
ever pointing it at real hardware. **Run `../checks/run-all.ps1` first** -
see [`../checks/README.md`](../checks/README.md) for why.

## How it fits together

1. `user_configuration.template.json` - the archinstall config (verified
   against the *actually installed* archinstall source extracted from a
   real release ISO, not just the upstream GitHub sample - those two have
   drifted from each other): Btrfs root with `@`/`@home`/`@log`/`@pkg`
   subvolumes (deliberately not `@.snapshots` - `snapper create-config`
   needs to create that one itself, see `roles/snapshots`), GRUB,
   NetworkManager, a `Minimal` profile (Ansible owns the desktop, not
   archinstall, so KDE isn't defined in two places), PipeWire audio, zram
   swap. It also embeds a
   `custom_commands` entry that archinstall runs inside the freshly installed
   system before reboot - this writes and enables a **systemd oneshot
   service** (`arch-project-bootstrap.service`) that runs automatically on
   the *first real boot*, before you ever log in.
2. That service runs `bootstrap-installed on first boot`: waits for network,
   clones this repo, runs `ansible-playbook site.yml`, then disables itself
   so it never runs again.
3. `detect-disk-and-install.sh` - run this from the live ISO. It finds the
   target disk (refuses to guess if there's more than one - real hardware
   may have multiple), asks you to type the device path back as confirmation
   (since `--silent` skips archinstall's own confirmation prompt), patches it
   into the template, and launches the unattended install.
4. `make-credentials.sh` - interactively generates `user_credentials.json`
   (gitignored - never commit real password hashes). `user_credentials.sample.json`
   documents the shape of that file but isn't meant to be hand-edited.

**Repo URL is already set** in `user_configuration.template.json`
(`https://github.com/fenn0046/archinstaller.git`) - only revisit that if the
remote ever changes.

## Credentials are per-session, not one-time

The live ISO's filesystem is RAM-backed and disappears on reboot, so
`user_credentials.json` only exists inside that ephemeral clone of the repo.
**You regenerate it every time you boot a fresh live ISO session** - it's not
a setup step you do once and forget.

## Running it

Boot the Arch ISO on your target VM/machine (make sure it's on the network),
then, since the ISO has `git` and `openssl` available out of the box:
```
git clone https://github.com/fenn0046/archinstaller.git
cd archinstaller/bootstrap
./make-credentials.sh      # prompts for archuser + root passwords, hashes them
./detect-disk-and-install.sh
```

When it finishes, the machine reboots into `archbox`, logs the bootstrap
service's progress to `/var/log/arch-project-bootstrap.log`, and lands on the
SDDM login screen only once the whole Ansible run (KDE, GPU driver, gaming,
snapshots, etc.) has completed.

## Notes / things worth knowing

- The `custom_commands` script assumes the account created is `archuser`
  (matches `user_credentials.json` and `group_vars/all.yml`'s
  `aur_build_user`). If you rename the account, update both places.
- If `archinstall`'s JSON schema changes in a future version, the exact keys
  in `user_configuration.template.json` may need updating. Verified against
  the actual installed `archinstall-4.4-1` source (extracted from a real
  release ISO's squashfs, not assumed from the GitHub sample - the two
  disagree on several fields, e.g. the upstream sample's `"sector_size":
  null` and `"unit": "Percent"` both crash this installed version).
  `checks/03-archinstall-dryrun.sh` and `checks/04-smoke-test.sh` catch
  this kind of drift automatically going forward.
- This assumes UEFI firmware (the boot partition is a FAT32 ESP mounted at
  `/boot`). Legacy BIOS boot would need a `bios_grub` partition instead -
  flag it if your target hardware/VM is BIOS-only.
- `enc_password` just needs to be a hash `crypt(3)`/glibc understands -
  confirmed against archinstall's `users.py` source, which stores whatever
  string you give it verbatim. `openssl passwd -6` (sha512crypt) works exactly
  as well as the yescrypt hashes archinstall's own TUI generates.
