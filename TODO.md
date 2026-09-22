# TODO - Media Refresh Studio (Windows OS media patching)

Last updated: 2026-09-22 (step 3 built and mock-tested, delivered as v2.3; steps 10-12 added to the list, not started). Stable build for testing: `MediaRefresh_v2.1.ps1` (draft; mock-tested, **never run against real images or a real DISM**) and `MediaRefresh_v2.2.ps1` (step 1 only; Terry has completed one real run and real-run logs are pending). Development build: `MediaRefresh_v2.3.ps1` (steps 1 and 3 done; mock-tested only, **never run against real images or a real DISM**).

## How the order was chosen

The order minimizes rework: data and structure that later features read come first, features that need real DISM feedback wait for it, and pieces that share code were merged so the shared part is written once.

- **Profiles before features.** The catalog search rules (step 5), package order, end-of-support date and SCCM defaults are all per-OS settings. If they are built into code first, they get moved into profile files later. So profiles go first.
- **Output handling before anything that writes or copies output.** Dated output and archiving are needed by the change log file names (step 3) and the SCCM copy step (step 7).
- **One instrumentation pass.** The title-bar phase display, the change log and the validation gate all need the engine to report the same stage boundaries, ISO file names and the finished image's contents. That is written once (step 3).
- **Real-image feedback early, in parallel.** Terry's first real runs (step 2) need no new code, so they start now on the untouched v2.1 while step 1 is built in v2.2. Results only cause fix-ups; they do not block the coding.
- **Host DISM decision after the Win11 result** (step 4), **downloader before SCCM import** (5 before 7, because the import needs a finished, current image), **hard cancel and batch queue last** (8), because they change how every earlier step is started and stopped.

### Old-to-new mapping

| New step | Merges old tasks |
|---|---|
| 1 | 11 (profiles JSON), 12 (order manifest), 10 (protect previous output), 18 (retirement date), test-kit part of 19 |
| 2 | 2 (missing ISOs), 3 (open questions), 1 (real-image runs), 4 (WinRE with languages) |
| 3 | 20 (title bar phase), 5 (change log), 9 (validation gate) |
| 4 | 13 (host DISM / ADK) |
| 5 | 6 (MSCatalogLTS), 7 (checkpoint CUs), 8 (Setup DU / Safe OS DU) |
| 6 | 17 (media refresh, .NET order) plus second real-image round |
| 7 | 16 (SCCM import engine), 21 (SCCM import tab) |
| 8 | 14 (hard cancel), 15 (batch queue and scheduled run) |
| 9 | 19 (rest of housekeeping) |

## Index

| # | Step | Owner | Status |
|---|------|-------|--------|
| [1](#s1) | Foundation: JSON profiles, package order, end-of-support dates, safe dated output | Claude | **Done in v2.2 (mock-tested)** |
| [2](#s2) | Real-image validation round 1: inputs, preflight, first servicing runs, WinRE with languages | Terry (parallel) | In progress (one v2.2 run completed; logs pending) |
| [3](#s3) | Run reporting: title-bar phase, change log (HTML + CSV), validation gate | Claude | **Done in v2.3 (mock-tested)** |
| [4](#s4) | Host DISM vs image build (ADK DISM decision) | Claude + Terry | After step 2 Win11 result |
| [5](#s5) | Acquisition layer: MSCatalogLTS download, checkpoint CUs, Setup DU / Safe OS DU | Claude | Next |
| [6](#s6) | Upgrade-package media readiness and validation round 2 | Claude + Terry | After 5 |
| [7](#s7) | SCCM import: new tab, local copy to content source, import, distribute | Claude | After 3 and 5 |
| [8](#s8) | Hard cancel, batch queue, scheduled run | Claude | Last feature |
| [9](#s9) | Housekeeping and final documentation | Claude | Ongoing |
| [10](#s10) | Operator UX: INSTRUCTIONS.md + Instructions tab, saved settings, utility menu (Clear Settings / Cleanup Mountpoints / Image Inventory) | Claude (+ Terry for the inventory script) | Added 2026-09-22, not started |
| [11](#s11) | App / provisioned-app removal (debloat) — runs first, before any other servicing | Claude | Added 2026-09-22, not started |
| [12](#s12) | Bootable WinPE recovery/rescue ISO (ADK-based, 2023 UEFI CA signed) | Claude | Added 2026-09-22, not started |

---

<a id="s1"></a>
## 1. Foundation: JSON profiles, package order, end-of-support dates, safe dated output

**Owner:** Claude. **Status:** built and mock-tested in `MediaRefresh_v2.2.ps1` (v2.1 stays untouched for step 2). Needs a first look on the real build machine (see "Try it" below).

**1a. OS profiles as JSON files** (old 11)

- One JSON file per OS in a `Profiles` folder beside the script: display name, folder and alternate folder names, edition regex / preferred index, service-all-indexes flag, language pack file pattern, default languages, SSU required flag, package order (below), end-of-support date, notes. The five built-in profiles are written out as files on first run, so the single script still works on its own. A bad or incomplete file is reported and skipped, never crashes the run.
- The loader ignores keys it does not know, so steps 5 and 7 can add their own keys (catalog search rules, SCCM defaults) to the same files without a new file format.
- Adding an OS (Server 2025, Win11 25H2, LTSC 2024) then needs a JSON file, not a code change.

**1b. Package order manifest** (old 12)

- Per package class (SSU, LCU, .NET CU, Safe OS DU, Setup DU) an optional ordered list of file-name patterns. Matching files are applied in that order; anything else follows in name order. Replaces "filename order" for legacy SSU chains.

**1c. End-of-support dates** (old 18)

- Each profile carries an end-of-support date. The run logs a warning when it is past or within 180 days, and the GUI shows it next to the OS selection. Known dates: Windows 10 Enterprise LTSC 2021 (KMS) **2027-01-13**; IoT LTSC 2021 2032-01-14; LTSC 2019 2029-01-10. Win11 24H2 Enterprise and Server 2022 are left blank until checked against the Microsoft lifecycle pages.
- The decision itself (when to stop refreshing the KMS image and what replaces it) stays with Terry.

**1d. Safe dated output** (old 10)

- Before a real run writes anything, the previous `NEWWIM` output (install.wim, boot.wim, media folder) is moved into `NEWWIM\Archive\<yyyyMMdd_HHmmss>` instead of being overwritten; the newest few archives are kept and older ones removed.
- Free-space check in the preflight and before a real run (tens of GB per run), with a clear message instead of a DISM failure half way through.

**1e. Keep the test kit** (part of old 19)

- The mock-based test kit (unit, end-to-end, runner and parse checks) is saved into the project so it survives this session and can re-check every later change.

**What was built (v2.2)**

- `Profiles\*.json` beside the script, created on first run from the built-ins; "Reload profiles" button; the run re-reads the files each time, so an edit applies to the next run. Invalid file = skipped with a message naming the file and the reason; if the first file by name defines an OS twice, the later file is skipped.
- `packageOrder` per class with wildcard patterns; the applied order is logged (`SSU order: a -> b`); a pattern that matches nothing logs a WARN.
- `endOfSupport` per profile: WARN in the log at the start of a run when past or within 180 days, and a line under the OS selector in the GUI (red when near or past). With today's date the KMS profile is already inside the 180-day window (2027-01-13).
- Previous `NEWWIM` output moved to `NEWWIM\Archive\<timestamp>` just before the first new output is written (install.wim, boot.wim or media); newest 3 kept (`keepArchives`; 0 keeps all). Preflight never archives.
- Free-space check in preflight and real runs: about 3x the source WIM plus 6 GB scratch, plus one OS ISO for media and another for an ISO build, never below the profile's `minFreeGB` (30 GB client, 60 GB Server). `spaceCheck` = enforce, warn or off.
- Test kit stored in the project under `claude/testkit/` (6 suites, 162 checks, all passing on PowerShell 7.4).

**Try it (first real look):** copy `MediaRefresh_v2.2.ps1` next to v2.1, start it as Administrator, confirm that a `Profiles` folder with five JSON files appears beside the script and that the OS list, the support line and "Reload profiles" work; then run a Preflight-only on one OS and check the new `Profile:`, `Support ends`, `... order:` and `Free space on ...` log lines. Servicing itself is unchanged from v2.1, so step 2's real runs can continue on either file.

**Open points for Terry**

- Win11 24H2 and Server 2022 end-of-support dates are blank until checked against the Microsoft lifecycle pages (fill them in the JSON files).
- The free-space estimate is a rule of thumb; if it is too strict or too loose on real runs, tune `minFreeGB` or set `spaceCheck` to `warn`.

**Done when (met in mock tests):** v2.2 loads profiles from JSON (and falls back to built-ins), applies the order manifest, warns about end of support, archives previous output and checks free space; all existing checks plus new ones pass; the test kit is stored in the project.

<a id="s2"></a>
## 2. Real-image validation round 1: inputs, preflight, first servicing runs, WinRE with languages

**Owner:** Terry (Claude analyses the logs). **Status:** can start now, in parallel with step 1. Use `MediaRefresh_v2.1.ps1` as it is; nothing in step 1 changes how DISM is driven.
**Merges old 2, 3, 1, 4.**

**2a. Inputs still needed**

| OS folder | Needed | Why |
|---|---|---|
| Win10_Enterprise_LTSC_2019 | 1809 Language Pack ISO (LP ISO, not the FOD ISO) | Only FOD part 1 is present, so the ten languages cannot be added. |
| Win10_Enterprise_LTSC_2021_KMS | Copy the `LangPackAll` (2004 family) ISO into this folder | It currently has only the OS ISO and FOD part 1. |
| Win10_IOT_Enterprise_LTSC_2021 | FOD part 1 ISO, **or** confirmation that the LangPackAll ISO already carries `Microsoft-Windows-LanguageFeatures-*` cabs | Check with `Get-ChildItem X:\ -Recurse -Filter 'Microsoft-Windows-LanguageFeatures-*'` on the mounted ISO. |
| Win11 24H2, Server 2022 | Fresh Microsoft ISOs each cycle | English only, no LP/FOD ISOs needed. |

**2b. Questions to answer**

- Was WinRE servicing switched off deliberately in the two logged v2 runs?
- Build host: OS version and ADK version (drives step 4).
- Exact image names in the IoT 2021 ISO (paste the `Detected indexes:` log line from a preflight).
- Current Setup DU and Safe OS DU files for the legacy OSes, if WinRE and upgrade-package media should be refreshed (step 5).
- Settled already: SCCM content sources are on `<SCCM-SOURCE-SERVER>` (this server); the LTSC 2019 SSU is KB5005112 (x64) and the LTSC 2021 IoT and KMS SSU is `ssu-19041.3562-x64.msu`.

**2c. Runs** (full test plan in `MediaRefresh_Review_and_Roadmap.md`, section 0)

- Before any run: `Unblock-File` the script, run from elevated Windows PowerShell 5.1, exclude the MediaRefresh folder from antivirus, have tens of GB free, rename any NEWWIM\install.wim you still need (the run overwrites it in v2.1), keep only the newest LCU in PATCHES\LCU.
- Preflight only on every OS folder. Check the ISO role lines, patch counts, language pack check and the `Detected indexes` / `Selected client image index` lines (this confirms the IoT 2021 edition fix).
- First servicing run: **LTSC 2021 KMS, de-de + ja-jp only**, WinRE on, NetFx3 on, Verify on (about 1.5 hours). Then all ten languages, then Server 2022 (English only, four indexes, WinRE once), then LTSC 2019, IoT 2021 and Win11 24H2.
- **WinRE with languages is the highest-risk path** and has never run in any log. Run once with WinRE on and once off to isolate it. Record WinRE size before and after, and confirm the same winre.wim is reused for every Server index.
- Confirm on a real console: clicking in the console no longer pauses the run (Quick Edit fix), and the window stays responsive during mount and patch.
- Send `MediaRefresh_*.log` and `DISM_*.log` from LOGS after each run. The `VERIFY` lines are the evidence that the LCU and languages are really in the image.
- **AV exclusion — verify it's actually in place (Terry, 2026-09-22).** The IoT 2021 LTSC real run (v2.2, 2026-09-21) completed successfully with 0 verify issues, but took ~3h53m total, with individual steps way out of proportion to the rest: LCU pass 1 ~46 min, LCU final ~38 min, one .NET CU ~29 min, component cleanup ~24 min, versus ~5-7 min per language pack. The DISM log for that run contains 30,000+ `Error CSI ... Matching binary ... missing for component ... dualModeDriver` entries (Hyper-V driver components: `wvmbusr`, `vmbusr`, `vmbuspiper`, `wstorvsp`, `storvsp`) — a known-benign DISM/CBS quirk that doesn't fail the run, but retrying/logging it that many times costs real time, and lines up with exactly the steps that ran long. This is also consistent with real-time antivirus scanning fighting DISM for every file it touches. The pre-run checklist above already says to exclude the MediaRefresh folder from AV — **double-check that exclusion is actually configured** (folder path, and whether it needs the OS drive/MOUNT subfolders specifically, not just the top-level MediaRefresh folder) and re-run the same OS once excluded to see whether the slow steps and the dual-mode-driver error volume both drop. Not urgent (the image itself was fine), but worth doing before Server 2022's 4-index runs multiply the cost.

**Done when:** each OS produces an install.wim whose VERIFY lines show the expected RollupFix, languages and fonts, with no crash or hang, and any fix-ups from the logs are folded into v2.2.

<a id="s3"></a>
## 3. Run reporting: title-bar phase, change log (HTML + CSV), validation gate

**Owner:** Claude. **Status:** built and mock-tested in `MediaRefresh_v2.3.ps1` (v2.2 stays untouched for step 2's real runs). **Depends on:** 1 (dated output and file naming). Wording and checks may still need tuning once Terry's real-run logs come back (step 2).
**Merges old 20, 5, 9.**

All three need the engine to report the same things, so the engine is instrumented once and the three consumers read it:

- **Stage boundaries** - a small `Set-Phase` call at each stage (also the source of the title-bar text).
- **Change events** - every package, language pack, capability and font the tool adds, with a timestamp taken when the step succeeds.
- **ISO sources** - the file name (not only the drive letter) of the OS ISO and every additional ISO.
- **Finished-image data** - read once from the existing read-only verification mount (`Test-OutputWim`): build, packages, features, capabilities, appx, provisioned appx.

**3a. Title bar: OS name and current phase** (old 20)

- The header has the title "Configuration Manager OSD Media Refresh" and its subtitle on the left with unused space to the right. Use that space, right-aligned, for two lines: the **OS being worked on** (the selected OS while idle, the running OS during a run), and directly below it the **current phase**.
- Phases: Idle; Preflight; Mounting ISOs; Clearing stale mounts; Exporting image; **Removing apps** (step 11, once built — runs first, before WinRE/SSU/LCU); Servicing WinRE; Adding SSU; Adding LCU (pass 1 / final); Adding language packs; Adding FODs and fonts; Component cleanup; Enabling .NET 3.5 / adding .NET CU; Servicing boot.wim; Exporting install.wim; Verifying image; Building media / ISO; Writing change log; later Copying to content source and Importing to SCCM (step 7); Done; Failed; Cancelled. Server 2022 shows the index ("Servicing index 2 of 4").
- The engine already streams log and progress to the window through a queue: add a third message type for phase and OS name, and let the GUI timer update the two header text blocks. Turn the header `StackPanel` into a two-column grid so the right block stays right-aligned. In step 8 the phase line can add "OS 2 of 3".

**3b. Per-image change log, separate from the run log** (old 5). **Input from Terry:** the inventory script he offered; use it as the starting point for the data collection.

Produce **both** an HTML file (for reading) and a CSV (for filtering/import) from one data model.

- Files: `LOGS\ChangeLog_<OS>_<build>_<yyyyMMdd_HHmmss>.html` and `.csv`, also copied beside the output WIM in `NEWWIM\` so it travels with the image and can be referenced by the SCCM object. Server 2022 (several indexes): one file per output WIM with a section (or `Index` column) per index.
- **Header block:** (1) title line `<OS name> - Build <major.build.revision>` from the finished image; (2) source line 1 = file name of the **OS ISO**; (3) source lines 2..n = every additional ISO used (Language Pack, FOD, others); (4) build **before** and build **after** patching; (5) run date/time, tool version, edition/index, languages requested.
- **Section A - what this tool changed** (date/time on every row): KB patches installed (SSU, LCU incl. checkpoints, .NET CU, Safe OS/WinRE update, Setup DU) with KB number, file name and target (install.wim / WinRE / WinPE); language packs; Features on Demand / capabilities (including `Language.*`); fonts (`Language.Fonts.*`); other actions (NetFx3, WinRE serviced, cleanup, export).
- **Section B - final state of the image** (read from the read-only mount of the finished WIM): enabled optional features, packages, capabilities, appx packages, provisioned appx packages, hotfixes.
- **Columns:** `Date | Section | Item | Version / KB | State | Source | Index`. Every item has a date next to it.
- **Decisions while building** (offline images differ from a running system): dates for inventory items use the DISM install time when it exists (packages), otherwise the date the image was serviced, with a `DateSource` note; appx comes from provisioned packages plus `Program Files\WindowsApps` (no per-user appx offline); hotfixes are derived from `Package_for_KBxxxxxxx` and RollupFix package names (`Get-HotFix` is live-only); build before = `Get-WindowsImage -Index` Version, build after = offline registry (`CurrentBuild` + `UBR`, `DisplayVersion`), or a read-only mount of the source index if more accuracy is wanted; confirm these with Terry.
- The report is written even when verification finds issues, and says so at the top.

**3c. Validation gate** (old 9)

- From the same finished-image data: compare build/revision with the applied LCU, confirm the RollupFix package, index count and edition names. On failure mark the output as failed (for example `install.wim.FAILED`, and do not offer it to the SCCM step) instead of leaving a stale WIM that looks fine. The result goes into the change log header.

**Done when:** during a run the header always shows the OS and a phase that matches the log and returns to Idle/Done/Failed afterwards; a serviced image produces both change-log files whose Section A counts match the `VERIFY` lines; Section B lists the RollupFix and every requested language and font; the title shows the OS and final build; the OS ISO is the first source line; and a stale image is flagged instead of passing quietly.

**What was built (v2.3)**

- **Title bar.** The header is now a two-column grid: "Configuration Manager OSD Media Refresh" stays left, and the OS name + current phase are right-aligned next to it. A `Set-Phase` call at every stage boundary in `Invoke-MediaRefresh` (mounting, clearing stale mounts, exporting, each servicing index — "Servicing install.wim (index N of M)" on Server — verifying, building media/ISO, writing the change log, done) drives it. In the foreground path it writes straight to the two `TextBlock`s; in the background-runspace path it enqueues an `H`-tagged queue message that `Update-RunUi` now reads and applies. While idle, the header shows whatever OS is selected in the combo box (`Update-HeaderIdle`, wired to the OS selector and to start-up). `Complete-BackgroundRun` sets a terminal phase — **Done**, **Cancelled**, or **Failed** (distinguished by whether Cancel was requested) — and a run whose gate FAILED gets its own warning-styled completion dialog instead of the plain success message.
- **Change events.** A single `Add-ChangeEvent` call, added at each point a package, language pack, capability/font, WinRE service, NetFx3 enable or component cleanup succeeds, timestamps and categorizes everything the run actually changed (SSU, LCU, LanguagePack, Font, Capability, SafeOS, NetCU, WinRE, NetFx3, Cleanup, Other). ISO source file names (OS, Language Pack, FOD) are captured the same way, from the role map rather than by re-deriving them later.
- **Change log (HTML + CSV).** `Write-ChangeLog` builds both from one row list: `LOGS\ChangeLog_<OS>_<build>_<timestamp>.html`/`.csv`, copied beside the output into `NEWWIM\` after a successful `Install` run. Header block (OS + build, every source ISO by file name, build before/after, run date, tool version, edition/index, languages, and the gate result) comes first, then **Section A** (every change event, with KB parsed from the file name where present), then **Section B** — the finished image's packages, capabilities (including a Font/Language-capability split), enabled optional features, provisioned appx, staged appx folders, and hotfixes, all read from the same read-only verify mount `Test-OutputWim` already opens, so nothing is mounted twice. Columns are exactly `Date | Section | Item | Version / KB | State | Source | Index`. When Verify is off, the log still gets written (Section A only) and says plainly that Section B and the gate are unavailable for that run.
- **Validation gate.** Reuses the existing verify-issue count (RollupFix, language pack and font checks) rather than adding new comparisons: `Gate` is `PASSED` when `Test-OutputWim` finds zero issues, `FAILED` when it finds any, and `Skipped` when Verify wasn't run or the run was Preflight-only. **Decision:** the gate flags rather than blocks — a failing image is still written and still usable, but the run log says `VALIDATION GATE: FAILED` at ERROR level, the change log header is marked FAILED, and the GUI's completion dialog calls it out as a warning. Nothing is renamed to `.FAILED` or hidden from a later SCCM import step; step 7 can decide whether to read `Gate` and refuse a failed image outright once it exists.
- **Small engine fix found along the way:** `Add-Packages` now derives the logged/recorded package name from `FullName` (`Split-Path -Leaf`) instead of assuming the package object has a `.Name` property — real file objects from `Get-ChildItem` have one, but the language-pack call site builds a bare `FullName`-only object, and would have thrown under `Set-StrictMode` the first time a language pack was applied on a real run.
- **Test kit:** `mocks.ps1` gained `Get-WindowsOptionalFeature`/`Get-AppxProvisionedPackage` mocks (new calls inside the rewritten `Test-OutputWim`); `e2e.ps1` gained checks for the gate (PASSED/FAILED/Skipped), change-event categories and counts, Section B population, the change-log CSV's columns and the HTML header's OS/gate text, and the archive-count message was updated to account for the two new change-log files that now land in `NEWWIM` alongside `install.wim`. All 6 suites pass: 172 checks (parse, xaml, harness 39, e2e 48, runner 18, profiles 62).

**Try it:** copy `MediaRefresh_v2.3.ps1` next to v2.2, start it, and watch the header while a Preflight or real run goes through its phases. After a real run with Install + Verify both on, check `NEWWIM` for the two `ChangeLog_*` files alongside `install.wim`, open the HTML one, and confirm Section A matches what the `VERIFY` log lines report and the header shows PASSED or FAILED to match. Servicing itself is unchanged from v2.2/v2.1, so step 2's real runs are unaffected either way.

**Open point for Terry:** once real-run change logs exist, check whether Section B's derived dates, hotfix list and appx inventory actually say something useful, or need trimming — the mock tests can only confirm the mechanism runs, not that the real data is worth reading.

<a id="s4"></a>
## 4. Host DISM vs image build (ADK DISM decision)

**Owner:** Claude + Terry. **Depends on:** 2 (Win11 24H2 result and the build host answer). Old 13.

v2.1 only logs a warning when the host DISM is older than the image. Servicing Win11 24H2 (build 26100) from a Server 2022 host (DISM 10.0.20348) is a known source of odd failures. Options: detect and use the ADK's newer DISM for both the cmdlets (module path) and `dism.exe`, or require a newer build host. It is a small change once decided, but it touches every DISM call, so it is done once, before the downloader and SCCM steps pile on more code.

<a id="s5"></a>
## 5. Acquisition layer: MSCatalogLTS download, checkpoint CUs, Setup DU / Safe OS DU

**Owner:** Claude. **Depends on:** 1 (search rules live in the profile). **Reference:** WimWizard (TacII) and MSCatalogLTS 2.1.0.2. **Merges old 6, 7, 8** (the last two are just more package classes for the same downloader).

Fill the existing `PATCHES\*` folders automatically; the servicing engine keeps reading only those folders.

- Per-OS **search rules** in each profile (catalog titles differ by product): search string, architecture, exclude Preview, package class, build filter. Titles are editable data. Examples: LTSC 2019 = "Windows 10 Version 1809", LTSC 2021 = "21H2", Server 2022 = "Cumulative Update for Microsoft server operating system version 21H2".
- Derive the version string from the base WIM build number.
- Download LCUs through the catalog DownloadDialog call so the original hashed file name is kept (`Save-MSCatalogUpdate` strips it), as WimWizard does.
- Package classes: LCU (`.msu`), .NET CU, **Safe OS DU** (`.cab`; without it WinRE stays at its shipped level), **Setup DU** (without it upgrade packages run RTM Setup files). Never mistake the Safe OS `.cab` for an LCU.
- **Checkpoint cumulative updates (Win11 24H2+, Server 2025):** when adding FODs or language packs, all prior checkpoint MSUs plus the target LCU must be in one folder and installed together. The downloader must know which checkpoints the target needs and prune the rest. Not needed for the Win10 LTSC profiles.
- Cache by KB, delete superseded files, keep only the newest LCU (plus required checkpoint chain) in `PATCHES\LCU`.
- **Manual SSUs stay manual.** The legacy SSUs (LTSC 2019 KB5005112; LTSC 2021 `ssu-19041.3562-x64.msu`) are dropped in `PATCHES\SSU` by hand and never touched by the downloader.
- **Dry run in the GUI:** show the KB list that would be downloaded and applied, and require confirmation.
- Install/verify the module from the Gallery on first use (PowerShell 5.1+); fail clearly if the machine is offline. Runs on the background runspace.
- Check WimWizard's licence before copying any code.

**Done when:** one click fills PATCHES for a chosen OS with the right latest files (including SafeOS/SetupDU where the profile asks for them and the checkpoint chain on Win11), shows what it chose, and never deletes the manual SSUs.

<a id="s6"></a>
## 6. Upgrade-package media readiness and validation round 2

**Owner:** Claude + Terry. **Depends on:** 5 (needs Setup DU) and the round-1 results. Old 17.

- Confirm whether setup.exe and boot manager files in the media folder should be refreshed from the serviced WinPE (Microsoft step; matters only for the media/ISO path used by Upgrade Packages), and add it if so.
- v2.1 follows Microsoft's order (LCU, cleanup, then NetFx3 and .NET CU). If a real run shows the .NET CU or the LCU missing after deployment, test the alternative order and let the validation gate (step 3) decide.
- Terry runs the second round: an OS with the downloader-fed patch set, media folder built, change log and gate checked.

<a id="s7"></a>
## 7. SCCM import: new tab, local copy to content source, import, distribute

**Owner:** Claude. **Depends on:** 1 (dated output), 3 (change log for the image comment, validation gate so a failed image is never imported), 5 (a current image), 6 for the upgrade-package path. **Merges old 16 and 21.**

**The tab** (next to "Source and targets", "Updates and features", "Languages" and "Log"):

| Field | Behaviour |
|---|---|
| Site server name | Text box (FQDN). A "Test connection" button confirms the server answers and reads the site code (needed for the import; read it automatically or add a Site code box). |
| Distribution point **or** distribution point group | A choice of the two, plus a name box or drop-down. A "Load from site" button fills the list from the site; typing a name by hand stays possible. |
| Name of the imported image | Pre-filled with **the OS name with the date appended as `yyyyMM`**, for example `Windows 10 Enterprise LTSC 2021 KMS 202609`. Follows the selected OS until edited by hand; a "Reset" link restores it. Date format kept in one place in the code. |
| Content source folder | Text box with a **Browse... folder picker**. The value must be a UNC path that **begins with `\\<SCCM-SOURCE-SERVER>\`** (fixed prefix shown in the UI); the rest comes from the picker. |
| Package type | Drop-down: **Full OS image** or **Upgrade package**. |

**Decisions (Terry, 2026-09-21; all confirmed)**

- Image name date format is `yyyyMM`.
- MediaRefresh lives on the source server itself (`<SCCM-SOURCE-SERVER>`), so moving the finished image into the SCCM content source location is a **local file copy**, not a network copy. The import itself uses a UNC path that begins with `\\<SCCM-SOURCE-SERVER>\`.
- The folder picker selects the **destination** content source folder. The tool copies the finished image (serviced WIM or media) into it, then imports from that folder using the properly formatted UNC path.

**The engine behind it**

- **UNC conversion.** Because the tool runs on `<SCCM-SOURCE-SERVER>`, the picker is a normal local folder picker; the tool converts the chosen folder to its UNC path by matching it to the server's SMB shares (`Get-SmbShare`, longest share path that contains the folder) and shows the result, for example `\\<SCCM-SOURCE-SERVER>\<share>\<rest of path>`. If the folder is not inside any share, say so and stop. A picker that browses the UNC tree directly is the alternative if share matching proves awkward.
- **Validation:** the final path must start with `\\<SCCM-SOURCE-SERVER>\`, exist, and be readable; warn if the site server's computer account may lack read access (Test connection can try it).
- **Local copy step.** After servicing, copy the finished `install.wim` (Full OS image) or the media folder (Upgrade package, needs the refreshed media output from step 6) from `NEWWIM` into the chosen folder by local path, then import from the UNC path of that folder. Never overwrite the content source of an existing image without asking; prefer a dated subfolder or file name. Check free space first (media is several GB). Show progress in the phase line (step 3a).
- **Package type maps to the SCCM object:** Full OS image = operating system image (import takes the WIM file path); Upgrade package = operating system upgrade package (folder = full media). Warn or disable Upgrade package when the media folder was not built.
- **Distribution:** after the import, distribute to the chosen DP or DP group; show progress in the phase line and log.
- **Duplicates:** if an image with the same name exists, ask whether to update that object or create a new one (default to be decided with Terry).
- **Requirements:** the Configuration Manager console (PowerShell module) on the build machine and rights on the site; "Test connection" checks both and says plainly what is missing.
- **Optional extras (cheap):** "Import after servicing finishes" checkbox; Version and Comment fields pre-filled with the final build number and a pointer to the change log; remembering the last-used values in a small settings file so the site server and DP are not re-entered. Confirm per OS which SCCM object is consumed (OS Image, OS Upgrade Package, or boot image, which is normally built from the ADK WinPE and patched only per major CM update). WimWizard's SCCM functions are a reference.
- Runs on the background runspace so the window stays responsive.

**Done when:** the tab validates its fields, the name is pre-filled and follows the OS selection, the picker returns a usable UNC source path, the local copy lands in the chosen folder, and a finished image that passed the validation gate is imported from a `\\<SCCM-SOURCE-SERVER>\...` path and distributed to the chosen DP or DP group as the chosen package type.

<a id="s8"></a>
## 8. Hard cancel, batch queue, scheduled run

**Owner:** Claude. **Depends on:** 3, 5, 7 (they define what one OS run is). **Merges old 14 and 15.**

- **Hard cancel:** stop a running DISM call, then clean up (discard/unmount any live image, clear mount folders, dismount ISOs). Cancel today works at the next safe point between operations. The start-up stale-mount cleanup is the safety net for anything orphaned.
- **ISO mount hygiene (Terry, 2026-09-22):** two related fixes, small enough to do independently of the rest of this step.
  - **Detect ISOs already mounted at start.** `Clear-StaleMounts` already discards stray WIM mounts under the OS's `MOUNT` folder before a run; there is no equivalent check for ISOs. An ISO left mounted from a crashed run (or mounted by hand) that is not one of the files the current run iterates would go unnoticed. Add a preflight step that lists currently-mounted disk images (`Get-DiskImage`) matching this OS's ISO folder and dismounts anything found there before the run starts, logged the same way as the stale-mount cleanup.
  - **Keep ISOs mounted until the completion dialog is dismissed.** Today `Invoke-MediaRefresh` dismounts every ISO it mounted in its own `finally` block, so they are gone before the completion dialog even appears. Change this so a **successful** run leaves its ISOs mounted, hands their paths back to the GUI (the background-run result), and the GUI dismounts them only after the user clicks OK on the completion dialog (Dism cmdlets are available on the main thread too, since the module is imported at start-up). A **failed or cancelled** run should keep dismounting immediately in the engine's `finally`, as a safety net — there is no guaranteed "OK click" to hang cleanup on when the run didn't finish normally. Decide whether Preflight's own completion dialog gets the same treatment for consistency, or dismounts right away since it never touched an image.
- **Batch queue:** tick several OS profiles and process them one after another, one change log each, a summary at the end, the phase line showing "OS 2 of 3", and cancel semantics that make sense (skip this OS / stop all).
- **Scheduled run** (later): a monthly unattended run after Patch Tuesday with a summary file or email.

<a id="s9"></a>
## 9. Housekeeping and final documentation

**Owner:** Claude. **Ongoing.** Old 19 (the test kit part moved to step 1).

- Keep `MediaRefresh_Review_and_Roadmap.md` and this file in step with the script; update the roadmap as steps close.
- Check WimWizard's licence before reusing any of its code (steps 5 and 7).
- Version numbering: v2.1 is the draft under test; the first tested build gets a clean version number. Settle one default repository root (header says `C:\mediaRefresh`, GUI says `F:\mediaRefresh`).
- Minor code items from the review: rename the `$matches` variable; make OS display names match the project list.
- Operator guide: superseded by step 10's `INSTRUCTIONS.md` (folders, ISO roles, preflight first, where logs and change logs land, plus a full GUI walkthrough) rather than a separate write-up here.

<a id="s10"></a>
## 10. Operator UX: INSTRUCTIONS.md + Instructions tab, saved settings, utility menu

**Owner:** Claude for the mechanism; Terry for the Image Inventory script. **Depends on:** 1 (settings/profile file conventions to reuse), 3 (the header row the menu button sits in; the change-log writer the inventory output can reuse). **Added 2026-09-22 (Terry), four related asks.**

**10a. `INSTRUCTIONS.md`**

- New file next to the script (same folder as `Profiles\`), written in Markdown so it doubles as the source for the Instructions tab (10b) and is still readable on its own in a text editor or on GitHub.
- Contents: what the tool does and the folder layout it expects (ISO/LOGS/MOUNT/OLDWIM/NEWWIM/PATCHES/TEMP/WINPE/WINRE/WORKING per OS); a walkthrough of every GUI tab and control (Source and targets, Updates and features, Languages, Log, and whatever this step and step 7 add); the recommended order of operations (Preflight first, then a real run); and — the specific thing Terry asked for — **where the log files for a run land**: `LOGS\MediaRefresh_*.log` (run log), `LOGS\DISM_*.log` (DISM's own log), and the per-image change log `LOGS\ChangeLog_<OS>_<build>_<timestamp>.html`/`.csv` (also copied to `NEWWIM\` beside the output, per step 3b).

**10b. "Instructions" tab in the GUI**

- New tab beside the Log tab. Terry's ask is explicit that **looks matter** — this is not a plain read-only `TextBox` dump of the raw Markdown (that's what the Log tab already looks like). WPF has no built-in Markdown renderer, so this needs a small Markdown-to-`FlowDocument` conversion (headings, bold/italic, bullet and numbered lists, code spans/blocks, links) feeding a `RichTextBox` (or a `FlowDocumentScrollViewer`), styled to match the rest of the window (fonts, spacing, the app's color palette). Rendered once at start-up from `INSTRUCTIONS.md`; a small "Reload" affordance re-renders it if the file was hand-edited without restarting the tool.

**10c. Save option selections for future runs**

- After the user starts a run (or on every successful completion — decide which), write the current GUI selections (repository root, OS pick, every checkbox on "Source and targets" and "Updates and features", selected languages) to a small JSON settings file, for example `Settings\LastRun.json` beside `Profiles\`. On next start-up, load that file and pre-select the same options instead of the XAML defaults, so a repeat run does not need every box re-ticked.
- This overlaps with step 7's SCCM tab idea ("remembering the last-used values in a small settings file so the site server and DP are not re-entered") — one settings file and one load/save mechanism should cover both rather than building two.

**10d. Menu button, upper-right of the window**

- A small button or menu glyph in the header (near the OS/phase display added in step 3a), opening a dropdown with three actions:
  - **Clear Settings** — deletes/resets the `LastRun.json` file from 10c back to the XAML defaults. Confirm before doing it (destructive-ish, easy to fat-finger).
  - **Cleanup Mountpoints** — runs the existing stale-WIM-mount and stray-ISO-mount cleanup (`Clear-StaleMounts`, plus the "detect ISOs already mounted at start" fix logged under step 8's ISO mount hygiene item) on demand, without starting a full run — useful after a crash or a manually-mounted ISO left behind.
  - **Image Inventory** — opens a file picker for an arbitrary image file (a WIM, an ESD, or an index within one — Terry to confirm exactly what the picker should target), then runs an inventory script against it and shows/saves a complete inventory: enabled optional features, installed languages, installed KBs, and whatever else the script reports. **Terry is providing this script.**
    - **This is the same request as the "inventory script" noted under step 3b** ("Input from Terry: the inventory script he offered; use it as the starting point for the data collection") — that script became the basis for Section B of the per-run change log (the finished image's packages/capabilities/features/appx/hotfixes, built in v2.3). This menu item is the **on-demand, any-image** version of the same idea: instead of only running automatically against the image a servicing run just produced, it runs against whatever image file the operator points it at, on request. Once Terry's script is in hand, prefer reusing step 3b's data model and HTML/CSV writer (`Write-ChangeLog`'s row/column shape) for the output rather than inventing a second report format, so an ad-hoc inventory and a run's Section B look and read the same way.

**Done when:** `INSTRUCTIONS.md` exists and covers the folder layout, every GUI control, and exactly where each log type lands; the Instructions tab renders it as formatted Markdown (headings/lists/bold actually look like headings/lists/bold, not a wall of `#`/`-`/`**` characters); a run's option selections are saved and reappear pre-selected on the next start-up; and the menu's three actions all work without requiring a full servicing run — Clear Settings and Cleanup Mountpoints can be built and mock-tested now, Image Inventory once Terry's script arrives.

<a id="s11"></a>
## 11. App / provisioned-app removal (debloat) — first step in the servicing order

**Owner:** Claude. **Depends on:** 1 (profile conventions, for a per-OS removal list), 3 (`Set-Phase`/`Add-ChangeEvent` instrumentation, so removals show up in the title bar and the change log like everything else). **Terry, 2026-09-22: ordering decision.**

**Ordering decision (settled):** app removal runs **before any other injection** — before WinRE servicing, SSU, LCU, language packs and FODs. It is effectively the first thing that happens to the mounted image, right after mount and before the SSU/LCU/language block in `Service-InstallIndex`. Reasoning from Terry: removing apps first means every later step (LCU, language packs, capabilities) only ever has to deal with the leaner, final app set, instead of servicing apps that are about to be removed anyway, or having a later removal step interact with capabilities/language content that was just added.

**Still open (not yet designed in detail):**

- **What gets removed and how it's specified.** Likely a per-profile list (same shape as the package order manifest in step 1b) of Appx package family names / provisioned-package name patterns to remove, with a sensible built-in default list per OS family (client only — Server 2022 ships basically no provisioned consumer apps, so this is mostly a Win10/Win11 client concern). Needs Terry's input on the actual removal list per OS.
- **Removal mechanism:** `Remove-AppxProvisionedPackage -Path <mount> -PackageName <...>` offline, one call per matched provisioned package. Log what was removed the same way `Add-ChangeEvent` logs additions (Category `AppRemoved`), so the change log's Section A shows removals alongside everything that was added.
- **Toggle:** a checkbox (like the existing patch-type checkboxes) so a run can skip removal entirely; ticked packages/patterns that match nothing are logged and skipped, same convention as the rest of the tool.
- **Server exemption:** decide whether the removal list/checkbox is simply hidden or always a no-op for Server profiles (`ServiceAllIndexes = true`), since there is normally nothing to remove there.

**Done when:** a profile can list apps/provisioned packages to remove, the checkbox controls whether it runs, removal happens as the very first servicing action (before WinRE/SSU/LCU/languages) and is visible in the title-bar phase, the run log, and the change log's Section A, and Server profiles are unaffected unless Terry asks otherwise.

<a id="s12"></a>
## 12. Bootable WinPE recovery/rescue ISO (ADK-based, 2023 UEFI CA signed)

**Owner:** Claude. **Depends on:** 4 (the ADK-vs-host-DISM decision settles which ADK tooling is already in play; this step needs the ADK's `copype`/WinPE tooling regardless of what that decision picks for regular servicing). **Terry, 2026-09-22: clarified scope.**

This is a **separate deliverable from the per-OS WinRE servicing already built** (the WinRE step in `Service-InstallIndex`/`Service-WinRe` patches the recovery partition that ships *inside* each serviced `install.wim`). This new item is a **standalone, bootable troubleshooting/recovery ISO**, built independently of any specific OS profile:

- **Base:** the ADK's own WinPE (`copype amd64 <dest>` / `winpe.wim` from the installed Windows ADK + WinPE add-on), not an OS ISO's WinRE. Confirm the ADK version installed on the build host is recent enough to matter for the next point.
- **Signing:** the recovery ISO's boot components must chain to the **2023 Windows UEFI CA** rather than the older 2011 one, for Secure Boot trust going forward. In practice this most likely means: use boot files (`bootmgfw.efi`/`bootx64.efi` and friends) sourced from a sufficiently current ADK/WinPE build that Microsoft has already signed against the 2023 cert, rather than any self-signing step in the script — **needs research to confirm exactly which ADK/WinPE version first ships 2023-CA-signed boot binaries**, and whether anything beyond "use a current-enough ADK" is required (e.g. explicit `Add-WindowsDriver`/cert-store steps, or a specific WinPE add-on package). Flag this as a research task before writing any build code.
- **Contents:** beyond the bare ADK WinPE base, decide with Terry what tools/drivers/scripts should be baked into the recovery image (storage/network drivers for the target hardware, diagnostic tools, etc.) — open question, not yet scoped.
- **Build/output:** likely reuses the same `oscdimg`-based ISO-building code already used for the regular media/ISO path (step 6/`Build-Iso`), pointed at the WinPE working folder instead of a serviced OS media folder. Output location and naming convention TBD (a dedicated folder outside the per-OS `MediaRefresh\<OS>\` structure, since this isn't tied to any one OS).

**Done when:** a bootable WinPE-based recovery ISO can be built from the ADK on demand, its boot components are confirmed to chain to the 2023 UEFI CA, and it boots and passes Secure Boot on a representative target machine.

---

## Done so far (for reference)

- Recommendation: refactor MediaRefresh_v2 rather than start over or fork WimWizard.
- v2.1 draft: null-safe patch/language handling, content-based ISO role detection, language packs checked before any mount, Microsoft servicing order (WinRE once, SSU, LP/FOD/fonts, LCU last, cleanup, NetFx3/.NET CU), stale-mount cleanup, DISM log in LOGS, verification mount, refreshed media folder, Preflight-only mode, per-OS default languages, folder aliases.
- Console "hang until Enter" fixed (Quick Edit off, no console log writes, progress suppressed).
- IoT 2021 "pattern matched multiple images" error fixed (edition pattern now requires "IoT"; clearer messages).
- GUI freeze during mount/patch fixed (engine on a background runspace, live log/progress/elapsed time, soft cancel).
- v2.2 (step 1): JSON profiles, package order manifest, end-of-support warnings, safe dated output with archiving, free-space checks. Test kit stored in the project.
- v2.3 (step 3): title-bar OS/phase display, per-image HTML + CSV change log (copied into NEWWIM), validation gate (PASSED/FAILED/Skipped, flags rather than blocks). Test kit extended to 172 checks.
