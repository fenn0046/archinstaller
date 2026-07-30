# Unattended install (disk -> finished desktop, zero prompts)

This makes the *entire* pipeline hands-off: boot the Arch ISO, run one
command, and the machine partitions itself, installs the base OS, reboots,
and automatically clones+runs the main Ansible playbook on first boot -
no menu selections, no second command to type after reboot.

**This wipes the target disk.** Test on a disposable/snapshotted VM before
ever pointing it at real hardware.

## How it fits together

1. `user_configuration.template.json` - the archinstall config (verified
   against archinstall's actual source, not guessed): Btrfs root with
   `@`/`@home`/`@log`/`@pkg`/`@.snapshots` subvolumes, GRUB, NetworkManager,
   a `Minimal` profile (Ansible owns the desktop, not archinstall, so KDE
   isn't defined in two places), PipeWire audio, zram swap. It also embeds a
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
4. `user_credentials.sample.json` - copy this to `user_credentials.json`
   (gitignored - never commit real password hashes) and fill in real hashes.

## One-time setup before first use

**1. Repo URL is already set.** `user_configuration.template.json` points at
`https://github.com/fenn0046/archinstaller.git` - update it if the remote
ever changes.

**2. Generate password hashes.** From any Linux machine (the Arch live ISO
works fine - it has `openssl`):
```
openssl passwd -6
```
Run it once for the `archuser` account password and once for root, then
paste the resulting hashes into `user_credentials.json`:
```
cp user_credentials.sample.json user_credentials.json
# edit user_credentials.json, paste hashes in place of REPLACE_WITH_HASH
```

## Running it

Boot the Arch ISO on your target VM/machine (make sure it's on the network),
then, since the ISO has `git` available out of the box:
```
git clone https://github.com/fenn0046/archinstaller.git
cd archinstaller/bootstrap
cp user_credentials.sample.json user_credentials.json   # then fill in hashes
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
  in `user_configuration.template.json` may need updating - it was verified
  against the `archlinux/archinstall` GitHub repo's own
  `examples/config-sample.json` and source models on 2026-07-30, pinned to
  archinstall version 2.8.6.
- This assumes UEFI firmware (the boot partition is a FAT32 ESP mounted at
  `/boot`). Legacy BIOS boot would need a `bios_grub` partition instead -
  flag it if your target hardware/VM is BIOS-only.
