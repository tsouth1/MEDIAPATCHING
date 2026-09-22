# Media Refresh Studio

Automates adding cumulative patches, language packs, and Features on Demand to
Windows OS media (Windows 11, Windows 10 LTSC, Windows Server 2022, and
others) as an offline DISM servicing step, ahead of importing the refreshed
images into SCCM/Configuration Manager for deployment.

The tool is a single-file PowerShell 5.1 WPF GUI application: mount an OS ISO
(plus optional Language Pack / Features on Demand ISOs), apply the SSU/LCU/
language packs/.NET CU in Microsoft's documented order, verify the result,
and optionally build a refreshed media folder and ISO for OS Upgrade
Packages.

## Files

- `MediaRefresh_v2_original.ps1` — the original script this project started
  from (kept for history).
- `MediaRefresh_v2.1.ps1`, `MediaRefresh_v2.2.ps1`, `MediaRefresh_v2.3.ps1` —
  successive versions. Each is a complete, standalone script (no shared
  modules). `v2.3` is the current development build.
- `TODO.md` — the project's living task list: what's done, what's in
  progress, and open design questions, broken into numbered, dependency-
  ordered steps.
- `MediaRefresh_Review_and_Roadmap.md` — the original code review and
  roadmap that this project's plan grew out of.
- `testkit/` — a mock-based PowerShell test kit (unit tests, end-to-end
  scenario tests, XAML/parse/lint checks) that runs against any of the
  versioned scripts via `$env:MR_SCRIPT`. See `testkit/README_TESTKIT.md`.

## Status

See `TODO.md` for the current state of each piece of work. As of this
commit, steps 1 (foundation: profiles, package order, dated output) and 3
(run reporting: title-bar phase, change log, validation gate) are built and
mock-tested in `v2.3`; real-image validation against actual DISM/ISOs is
still in progress.

## Requirements

Windows PowerShell 5.1, run elevated, on a machine with the DISM module and
enough free disk space per profile (30 GB client / 60 GB Server minimum).
See `TODO.md` and the in-script header comments for the expected working
folder layout (`ISO`, `LOGS`, `MOUNT`, `OLDWIM`, `NEWWIM`, `PATCHES`, `TEMP`,
`WINPE`, `WINRE`, `WORKING` per OS).
