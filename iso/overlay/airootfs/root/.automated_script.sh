#!/usr/bin/env bash
# Replaces archiso releng's stock .automated_script.sh, which normally only
# runs a script passed via the "script=" boot parameter. This ISO bakes its
# own installer in directly, so it runs unconditionally on tty1 - no boot
# parameter needed, true zero-keystroke.
# -e, not -x: `touch` creates the marker mode 644, so an -x test is never
# true and the run-once guard never actually fired - logging back in on the
# live ISO would restart the installer against an already-installed disk.
if [[ $(tty) == "/dev/tty1" ]] && [[ ! -e /tmp/archproject_started ]]; then
  touch /tmp/archproject_started
  /root/archproject-bootstrap/auto-install.sh
fi
