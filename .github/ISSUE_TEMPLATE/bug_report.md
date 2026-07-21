---
name: Bug report
about: Something broken on a device running this port
labels: bug
---

**Device**: SM-X800 (or variant — X700/X706/X800/X806/X900/X906?)
**Stock firmware the device shipped from**: (e.g. One UI 7 / X800XXU9DYDC)
**Kernel package release**: (`uname -v` on the device, or the pkgrel you built)
**Device package release**: (`apk info device-samsung-gts8pwifi`)

**What happened**

**What you expected**

**Logs** (as applicable)
```
dmesg | tail -50
journalctl -b --no-pager | tail -50   # the journal is persistent; -b -1 for the previous boot
```

**Notes**: the tablet-side toolkit (`sudo gts8pwifi-setup`) installs the debug
tools most issues need (evtest, i2c-tools, libgpiod, strace).
