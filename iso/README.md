# Custom ISO: true zero-keystroke install

This is the fullest version of the automation: a custom Arch ISO that, once
booted, wipes the (single) disk it finds and installs the whole system with
**no input at all** - no cloning a repo, no running a script, no typing a
password. Boot it and walk away.

**This is more dangerous than the `bootstrap/` flow, on purpose.** There is
no confirmation step before the disk gets wiped. Only boot this ISO on a
machine/VM you specifically intend to wipe. Never leave it as the default
boot device on anything else.

**Run `../checks/run-all.ps1` before building/booting this** - see
[`../checks/README.md`](../checks/README.md). It exists specifically
because most bugs found building this ISO were much cheaper to catch this
way than via a full boot cycle.

## How it works

- Built on top of Arch's official `releng` ISO profile (the same one used
  for real Arch release images), which already ships `archinstall` and a
  `.automated_script.sh` hook that runs on tty1 login.
- We replace that hook so it unconditionally runs a baked-in installer
  (`/root/archproject-bootstrap/auto-install.sh`) instead of waiting for a
  `script=` boot parameter.
- That installer auto-selects the disk **only if there's exactly one** -
  if it finds more than one, it aborts to a shell instead of guessing.
  There's no "retype the device path to confirm" step like `bootstrap/`'s
  script has, since nobody's there to type it.
- **The machine must be set to UEFI firmware.** The disk layout is GPT with
  an ESP at `/boot` and no BIOS boot partition, so GRUB can only install in
  UEFI mode. `auto-install.sh` checks `/sys/firmware/efi` up front and
  aborts with a clear message rather than failing at `grub-install` twenty
  minutes later with nobody watching.
- Credentials are baked in, but they're **yours**: `build-iso.ps1` prompts
  once for a password, hashes it inside the build container, and writes it
  into the ISO. Nothing is asked on the VM, so the install stays
  zero-keystroke, and no password (or hash of one) lives in this repo.
- After archinstall's silent run finishes, the ISO's script reboots the
  machine itself (archinstall's `--silent` mode skips its own reboot
  prompt entirely). From there, the same first-boot systemd bootstrap
  service as the `bootstrap/` flow takes over: clones this repo and runs
  `ansible-playbook site.yml`.
- That service is guarded by
  `ConditionPathExists=!/var/lib/arch-project/provisioned`, and
  `roles/finalize` writes that marker just before rebooting. This is what
  stops it running forever: the script's own trailing `systemctl disable`
  can never execute on a successful run, because the reboot the playbook
  triggers kills the script first. Leaving the `disable` in place is still
  useful - a *failed* run has no marker, so it retries on the next boot.

## Building it

Requires Podman (already set up on this machine via `podman-machine-default`).
`archiso`/`mkarchiso` need real Arch tooling that doesn't exist on Windows or
in a generic WSL distro, so the build runs inside a privileged `archlinux`
container instead - no need to install an Arch WSL distro.

```powershell
.\iso\build-iso.ps1
```

It prompts (twice, to confirm) for the password `archuser` and `root` will
have on the installed system. Then it starts the Podman machine if needed
and, inside an ephemeral `archlinux` container: copies the `releng` profile,
overlays our `iso/overlay/` files on top, hashes the password with
`openssl passwd -6` and writes `user_credentials.json` into the build
profile, generates the baked config from
`bootstrap/user_configuration.template.json` via `generate-config.py`, and
runs `mkarchiso`. Output lands in `iso/out/*.iso`.

The password reaches the container on **stdin**, never as an argument
(argv is visible to any other process via `ps`), and is only ever written
inside the container's `/tmp/profile` - never back into this repo.

## After building

Write `iso/out/*.iso` to a VM's virtual CD-ROM (or a USB drive for real
hardware) and boot it, with the firmware set to **UEFI**. That's the whole
process from here.

**Treat the built ISO as a secret.** It contains a hash of your real
password, so don't upload or share the `.iso` file. `iso/out/` is
gitignored.

## Structure

```
iso/
  build-iso.ps1              # prompts for the password, orchestrates the build
  generate-config.py         # copies bootstrap/user_configuration.template.json
                             # into the ISO's baked config
  overlay-packages.x86_64    # extra packages appended to releng's list
  overlay/airootfs/
    root/.automated_script.sh          # replaces releng's script= hook
    root/archproject-bootstrap/
      auto-install.sh                  # the zero-confirmation installer
      # user_credentials.json is NOT here - it's generated into the build
      # profile from your typed password, and gitignored at this path
  out/                        # build output (gitignored, and secret)
```

## Relationship to `bootstrap/`

Same underlying `archinstall` config and same first-boot Ansible handoff -
this is a stricter, riskier front end to it (no typed confirmation, baked
credentials) built for genuine walk-away automation. Use `bootstrap/` when
you want to supervise the install; use this when you don't.

Both flows now ask for the password at the same point conceptually - the
last moment a human is present. `bootstrap/make-credentials.sh` does it on
the live ISO before the install; `build-iso.ps1` does it on your desktop
before the build.
