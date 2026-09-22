# volup-trap

Watcher for the Volume Up dead state (issue #18). On some boots the pm8350
GPIO 6 interrupt counts edges on every press while the pad level never
changes, so gpio-keys emits nothing until the next reboot. The trap records
the state of that boot when it happens.

`volup-trap.py` runs as root and:

- logs every gpio-keys KEY event with the current interrupt count;
- every 10 s compares the `Volume Up` line of `/proc/interrupts` with the last
  reading. A rise with no key event in the window is the dead state: it writes
  `DEAD-STATE` to the log and captures the GPIO 6 register block, all GPIO
  chips, the regulator list and, once per hour, the full pmk8350 / pm8350 /
  pm8350c regmaps;
- takes a `boot-*` capture at every start.

Output lives in `/home/user/volup-trap/`: `trap.log`, `boot-<stamp>.txt`,
`dead-<stamp>.txt` and `dead-<stamp>-pmic-0-0N.txt`. The baseline to diff a
dead capture against is `device-facts/volup-2026-09-19/`.

## Install (after any userdata reflash)

```sh
scp tools/volup-trap/volup-trap.py user@<ip>:/home/user/
scp tools/volup-trap/volup-trap.service user@<ip>:/tmp/
ssh user@<ip> 'sudo install -m 644 /tmp/volup-trap.service /etc/systemd/system/ &&
               sudo systemctl daemon-reload && sudo systemctl enable --now volup-trap'
```

First check on any session: `cat /home/user/volup-trap/trap.log`. A boot
that never showed `DEAD-STATE` is a working boot.
