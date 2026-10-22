# Rntech Engine

The destructive, VPS-side install engine for the Rntech Windows/RDP installer.
It runs **inside a freshly-created droplet** (pushed and triggered by the Rntech
panel over SSH), writes Windows Server + VirtIO to the droplet's disk, and
reboots into Windows. The panel (in `../web`) is a separate, proprietary
program that invokes this engine as a tool over SSH.

## Files

- `rntech-install.sh` — the Rntech entry point. Loads the job-env
  (`RNTECH_*`), fetches and SHA-256-verifies `reinstall.sh`, points `confhome`
  at this fork, hands reinstall the Windows ISO **URL** + image name + RDP port
  over STDIN, then reboots into the installer. Posts
  `installing`/`finishing`/`done`/`failed` callbacks to the panel.
- `rntech-setup.bat` — the rebranded post-install script that applies RDP
  settings inside Windows and posts the final callbacks.
- `reinstall.sh`, `trans.sh`, `windows.xml`, `windows-*.bat`,
  `windows-driver-utils.sh`, and the other helpers — the reinstall engine this
  fork is derived from. `confhome` in `reinstall.sh` is set to this fork so all
  helpers are fetched from our own repository at runtime, not upstream
  (`confhome` = `https://raw.githubusercontent.com/Rnotebot/rnoteinstaller/main`).
- `INTEGRATION.md` — exactly how the panel drives this engine per job.
- `LICENSE`, `NOTICE` — GPLv3 text and the derivation/attribution notice.

## License & attribution

This engine is free software under **GPLv3** (see `LICENSE`). It is a derivative
work of [`bin456789/reinstall`](https://github.com/bin456789/reinstall) (GPLv3).
See `NOTICE` for the full attribution and the list of modifications relative to
upstream. Per GPLv3, if you redistribute a modified version you must keep these
notices and license the result under GPLv3.

> The Rntech **panel** (`../web`) is a separate proprietary program; it contains
> no GPL code and only invokes this engine over SSH.
