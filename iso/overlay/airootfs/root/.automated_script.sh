#!/usr/bin/env bash
# Replaces archiso releng's stock .automated_script.sh, which normally only
# runs a script passed via the "script=" boot parameter. This ISO bakes its
# own installer in directly, so it runs unconditionally on tty1 - no boot
# parameter needed, true zero-keystroke.
if [[ $(tty) == "/dev/tty1" ]] && [[ ! -x /tmp/archproject_started ]]; then
  touch /tmp/archproject_started
  /root/archproject-bootstrap/auto-install.sh
fi
