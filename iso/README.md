# Custom ISO: true zero-keystroke install

This is the fullest version of the automation: a custom Arch ISO that, once
booted, wipes the (single) disk it finds and installs the whole system with
**no input at all** - no cloning a repo, no running a script, no typing a
password. Boot it and walk away.

**This is more dangerous than the `bootstrap/` flow, on purpose.** There is
no confirmation step before the disk gets wiped. Only boot this ISO on a
machine/VM you specifically intend to wipe. Never leave it as the default
boot device on anything else.

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
- Credentials are baked in and **intentionally temporary**: both `archuser`
  and `root` get the password `ChangeMe-ArchProject!1`. This password is
  deliberately public (it's committed to this repo) - it is only ever meant
  to survive from first boot to first login.
- After archinstall's silent run finishes, the ISO's script reboots the
  machine itself (archinstall's `--silent` mode skips its own reboot
  prompt entirely). From there, the same first-boot systemd bootstrap
  service as the `bootstrap/` flow takes over: clones this repo and runs
  `ansible-playbook site.yml -e force_password_expiry=true`, then disables
  itself.
- The forced password change (`chage -d 0`, `roles/finalize`) happens at
  the very **end** of that Ansible run, not at install time. It has to -
  several roles use `become_user: archuser` (aur/gaming/experimental), and
  the first-boot service itself does `sudo -u archuser git clone`. PAM
  rejects `sudo -u archuser` non-interactively once that account's password
  is expired, regardless of who invoked sudo - expiring it any earlier
  breaks the entire pipeline before Ansible runs a single task (this
  happened during testing: the git clone failed silently and nothing after
  it ever ran, including KDE - it looked like "nothing installed" with no
  obvious error).

## Building it

Requires Podman (already set up on this machine via `podman-machine-default`).
`archiso`/`mkarchiso` need real Arch tooling that doesn't exist on Windows or
in a generic WSL distro, so the build runs inside a privileged `archlinux`
container instead - no need to install an Arch WSL distro.

```powershell
.\iso\build-iso.ps1
```

This starts the Podman machine if needed, then inside an ephemeral
`archlinux` container: copies the `releng` profile, overlays our
`iso/overlay/` files on top, generates the baked config (from
`bootstrap/user_configuration.template.json`, patched to pass
`-e force_password_expiry=true` to the first-boot Ansible run) via
`generate-config.py`, and runs `mkarchiso`. Output lands in `iso/out/*.iso`.

## After building

Write `iso/out/*.iso` to a VM's virtual CD-ROM (or a USB drive for real
hardware) and boot it. That's the whole process from here.

## Structure

```
iso/
  build-iso.ps1              # orchestrates the Podman-based build
  generate-config.py         # bakes bootstrap/user_configuration.template.json
                              # + forced password expiry into the ISO's config
  overlay-packages.x86_64    # extra packages appended to releng's list
  overlay/airootfs/
    root/.automated_script.sh          # replaces releng's script= hook
    root/archproject-bootstrap/
      auto-install.sh                  # the zero-confirmation installer
      user_credentials.json            # baked placeholder credentials
  out/                        # build output (gitignored)
```

## Relationship to `bootstrap/`

Same underlying `archinstall` config and same first-boot Ansible handoff -
this is a stricter, riskier front end to it (no typed confirmation, baked
credentials) built for genuine walk-away automation. Use `bootstrap/` when
you want to supervise the install; use this when you don't.
