# MediaRefresh v2 – Review, Recommendation and Roadmap

Prepared 2026-09-20. Sources: your `MediaRefresh_v2` script (read in full and parse-checked), Microsoft's media Dynamic Update guidance, Microsoft's checkpoint-CU guidance, the WimWizard repo/README/release pages, and the MSCatalogLTS module page. Links at the bottom.

## 0. Update 2026-09-20 (evening): your logs, your answers, and the v2.1 draft

### What your two logs show (both LTSC 2019, host DISM 10.0.20348.2849, image 10.0.17763.9121)

| | Aug 19 run (v1.0.0 sequence) | Aug 20 run (v1.0.1 sequence) |
|---|---|---|
| Sequence | SSU KB5005112, LCU KB5120238, languages, NetFx3, .NET CU KB5120703, cleanup, export | Same, but two .NET CUs (KB5120698, KB5120703) and a **second LCU pass** after them, then cleanup, export |
| Duration | 2h17m | 1h22m |
| Cleanup | Failed with 0x800F0806 (pending operations), skipped | Same |

1. **The Aug 19 run is the missing-LCU sequence.** FODs, NetFx3 and the .NET CU were all added *after* the only LCU pass. Microsoft's order puts the LCU last so components added earlier are brought to the current level. The Aug 20 run fixes that, which is why 1.0.1 helped.
2. **No language packs were ever added, in either run.** All ten languages log "Language pack ... was not found on the FOD ISO". The 1809 FOD ISO contains FODs only; the language pack cabs are on a separate Language Pack ISO. The `Language.*` capabilities were still added (no errors), but without the packs the image has no display languages. Nothing in the run flagged this as a failure. v2.1 now checks for every pack *before* mounting anything.
3. **Cleanup never ran.** 0x800F0806 came from enabling NetFx3 before cleanup (Microsoft's sample warns that legacy optional components leave pending operations). v2.1 does cleanup first and NetFx3 + .NET CU after it.
4. **WinRE was not serviced in either run** (no WinRE lines in the log). The Safe OS DU was counted (1 file) but never used. If that is intentional, fine; v2.1 now logs a visible warning when the box is unticked.
5. **Three long stalls in the Aug 19 run:** 16 minutes between "Mounting install image" and the first package (Aug 20: under 2 minutes), a 38-minute gap with nothing logged between the de-de language warning and the first capability, and a 15-minute gap after fr-fr. The Aug 20 run had none. Each gap starts immediately after a log line was written, which is exactly where the next console write would block. They are most likely the "hang until Enter" you saw (Quick Edit, see below), not host contention. That is an inference from the timestamps; the v2.1 DISM log will show whether any stall survives the fix.
6. **ISOs stayed mounted until someone clicked the completion dialog** (36 minutes on Aug 19, until the next morning on Aug 20). Fixed.
7. The LCU took about 33 minutes on the first pass and about 12 minutes on the second.

### Your ISO folders against what the script needs

The v2 script classified ISOs by file-name keywords. I tested that regex against your file names: `SW_DVD9_NTRL_Win_10_2004_..._LangPackAll_LIP_...ISO` does **not** match (it contains "Lang" but not "Language"), so in the IoT 2021 folder it would be counted as a second OS ISO and stop the run. v2.1 detects roles from ISO content instead.

| Folder | Has today | Needed for 10 languages + fonts |
|---|---|---|
| Win10 LTSC 2019 (IoT) | OS, FOD part 1 (1809) | Add the **1809 Language Pack ISO**. Do not reuse the 2004 LangPackAll ISO here, it targets a different build. |
| Win10 LTSC 2021 (KMS) | OS, FOD part 1 | Add the **LangPackAll ISO** (same file as in the IoT folder) |
| Win10 IoT LTSC 2021 | OS, LangPackAll | Add **FOD part 1** (same file as in the KMS folder), unless the check below shows the LangPackAll ISO already carries the language features |
| Win11 24H2 | OS | Nothing (English only) |
| Server 2022 | OS, combined LP + FOD + App Compat | Nothing (English only); the combined ISO can be removed |

### The "hang until I press Enter" problem

This is almost certainly the console's **Quick Edit** mode. Clicking anywhere inside a classic console window starts a text selection, and the next write to that console blocks until Enter or Esc ends the selection. The v2 script writes every log line with `Write-Host` and runs on the same thread as the GUI, so one stray click (or focusing the window with a click) freezes the whole script, with no error. It is a known Windows console behavior, not a bug in your code, and it can be fixed. v2.1 does three things: turns Quick Edit off at start-up (clears `ENABLE_QUICK_EDIT_MODE`, sets `ENABLE_EXTENDED_FLAGS`), stops writing log lines to the console when the GUI is running (window and log file only), and sets `$ProgressPreference = 'SilentlyContinue'` so cmdlet progress bars are not drawn to the console. You can also turn it off by hand: console title bar, Properties, Options, untick Quick Edit Mode. The call itself was checked only for its bit arithmetic here, not on a live console, so confirm on your build machine by clicking in the console during a run.

### Using the Win_10_2004_..._LangPackAll_LIP ISO for both LTSC 2021 folders

Yes for language packs, with one check. By your description (x86/x64 language packs, WinPE optional components for every language, language experience packs) it is the language pack source for both 2021 profiles, so the same file can sit in both ISO folders. Microsoft's language pack guidance for Windows 10 2004 and later also lists WinPE language components in a `Windows Preinstallation Environment\x64\WinPE_OCs` folder, which v2.1 uses for WinRE and boot.wim languages.

What it may not replace is the FOD ISO. The language *features* (`Language.Basic`, OCR, Handwriting, Text-to-Speech, Speech) and the CJK fonts are Features on Demand, and Microsoft's page lists them as separate from the language pack. Check with one command on the mounted ISO: `Get-ChildItem X:\ -Recurse -Filter 'Microsoft-Windows-LanguageFeatures-*' | Select-Object -First 5`. If it returns files, that ISO carries them and one ISO is enough; if not, keep FOD part 1 in the folder alongside it. v2.1 handles either layout: ISO roles come from content, an ISO can be both language pack and FOD source, and several FOD ISOs are all used as capability sources instead of stopping the run. It does not use the x86, ARM64 or LXP content (only `_x64_` language pack cabs).

### Decisions taken from your answers

- Win11 and Server 2022 are English-only, so the no-languages path is the normal path for them. In v2 that path crashed on the first line that counts languages, so it was the first thing that would have stopped a Win11 or Server run. It is fixed in v2.1 and tested.
- The Server 2022 language pack file pattern (finding 5) and multi-ISO language handling for Server are no longer urgent. The Server pattern is kept in the profile.
- Legacy SSUs are staged in PATCHES\SSU: KB5005112 for LTSC 2019, ssu-19041.3562-x64.msu for both 2021 profiles. v2.1 stops early if the SSU folder is empty for those three profiles, and does not require one for Win11 or Server.
- You deploy **OS Upgrade Packages** from the same patched install.wim, so v2.1 adds a "refreshed media folder" output (NEWWIM\Media: source ISO content, patched install.wim, Setup DU expanded into sources). Put the current Setup DU in PATCHES\SETUPDU for the legacy OSes, otherwise upgrade packages run RTM Setup files against a current install.wim. Boot images stay on their own cadence; boot.wim servicing is off by default.
- Win11 and Server ISOs are replaced with Microsoft's refreshed media each time, so the script still needs to add the newest LCU (and for Win11 24H2, the checkpoint chain) on top of them.
- The host is Server 2022 (DISM 10.0.20348). That is fine for the three Win10 images and Server 2022, but Win11 24H2 is build 26100. v2.1 logs a warning when the host DISM is older than the image; plan to use the ADK's DISM or a newer host for Win11.

### v2.1 draft: `MediaRefresh_v2.1.ps1`

A new file beside your v2 (v2 is untouched). It covers roadmap phases 0 and 2 plus the ISO/language parts of phase 1. Tested here with the PowerShell 7.4 parser, a Windows PowerShell 5.1 syntax-compatibility lint (PSScriptAnalyzer, no findings) and 58 mock-based checks (call order for every scenario above, ISO role detection with your layouts, empty folders, no-language runs, WinRE once across four indexes, failure cleanup, verification). **It has not been run against real images or a real DISM**, so treat it as a draft for a non-production run.

Window freezing during DISM is now fixed: the engine runs on a background runspace and the GUI shows live log, progress and elapsed time (Cancel takes effect at the next safe point between DISM operations). Not yet done: a hard cancel that aborts a running DISM call, MSCatalogLTS downloads, SCCM import, JSON profiles.

### Test plan for the first real runs

Before any run: unblock the file (`Unblock-File`), run it from an elevated Windows PowerShell 5.1 (`powershell.exe -ExecutionPolicy Bypass -File ...`), rename any existing NEWWIM\install.wim you still need (the run overwrites it), keep only the newest LCU (plus intended checkpoint chain) in PATCHES\LCU because v2.1 applies every file in the folder in name order, exclude the MediaRefresh folder from antivirus, and have tens of GB free.

1. **Preflight only** (new checkbox, about a minute, changes nothing) on each OS folder. It mounts the ISOs, shows which ISO got which role, counts patches per folder, confirms every language pack cab exists and shows the edition it will export.
2. **First servicing run: LTSC 2021 KMS, only de-de and ja-jp**, WinRE on, NetFx3 on, Verify on. It needs the LangPackAll ISO copied into that folder and uses your SSU. It exercises ISO roles, SSU, language packs, fonts, both LCU passes, cleanup, NetFx3, .NET CU and verification in roughly 1.5 hours.
3. Then all ten languages on the same OS, then Server 2022 (English only, four indexes, WinRE once), then LTSC 2019 once its 1809 Language Pack ISO is in the folder.
4. After each run send the `MediaRefresh_*.log` and `DISM_*.log` from the LOGS folder. The `VERIFY` lines are the evidence that the LCU and languages are really in the image.

Highest-risk untested path: WinRE servicing with languages. It never ran in any log you sent, even under v2. If it fails, untick WinRE and rerun to separate it from the rest.

## 1. Recommendation

**Keep and refactor MediaRefresh_v2. Do not start from scratch, and do not fork WimWizard.**

- **Why not scratch.** The hard part is already in your script and tracks Microsoft's sequence closely: WinRE first (SSU/LCU, WinPE language cabs, Safe OS DU, `/ResetBase /Defer`), then install.wim (SSU, LCU, language + FOD, LCU again, `/StartComponentCleanup` without ResetBase), the `0x8007007e` tolerance for combined LCUs on WinRE/WinPE, the `0x800F0806` pending-op tolerance, per-index export, and multi-index Server output. It also already has the per-OS profile idea (`$OsDefinitions`) and the folder model you want. Rewriting throws that away.
- **Why not WimWizard.** It is Windows 11-centric by design. Its own release notes describe Windows 11 Enterprise/Education (24H2/25H2, plus LTSC 2024 handling) and I found no Windows 10 or Server 2022 image support; Server 2022 is only listed as a supported *host*. Its catalog search strings, build filter, inbox-app/winget fix and SCCM import are all Windows 11 specific. It is the best *reference* for acquisition (see section 4), not a base.
- **What "refactor" means.** Four structural changes, in this order: (1) fix the crash bugs and safety issues; (2) move per-OS assumptions out of code into profile data; (3) align servicing with Microsoft's order; (4) add a catalog acquisition layer (MSCatalogLTS) and split engine from GUI.

## 2. Comparison

| | MediaRefresh_v2 | WimWizard 5.x | Microsoft sample |
|---|---|---|---|
| OS coverage | 5 profiles: Win10 LTSC 2019, 2021 IoT, 2021 KMS, Win11 24H2, Server 2022 | Win11 Ent/Edu 24H2/25H2 (+LTSC 2024), x64 + ARM64 | Win10/11, Server 2022/2025 (package naming differs per OS) |
| Patch acquisition | Manual drop into PATCHES\* | MSCatalogLTS: LCU, .NET CU, SafeOS; cache + superseded cleanup | Manual |
| WinRE | Serviced once **per index** | Serviced first, isolated ResetBase | Serviced **once** from index 1, reused for all editions |
| Multi-index Server | Yes | No | Yes |
| Legacy SSU chains | Manual folder, applied in filename order | n/a | n/a |
| GUI | Single-file WPF, servicing runs on UI thread | Separate GUI launcher passes parameters to an engine script | None |
| SCCM | None | Create/update OS image, DP staging, source-stability check | None |

Caveat: the WimWizard column is from its README and release pages, not a line-by-line read of the source. The release page shows v5.2.2 (May 18) while the README lists script v5.2.6, so the release list I fetched may be truncated. Check its license before lifting any code.

## 3. Findings in MediaRefresh_v2

### Confirmed by running your code (PowerShell 7.4, `Set-StrictMode -Version Latest`; please re-confirm on 5.1)

1. **Empty patch folder with its box ticked crashes the run.** `Get-PackageFiles` returns nothing, the hashtable stores `$null`, and `Add-Packages` iterates `@($null)` once and fails on `$pkg.FullName`. This contradicts the GUI note "Empty selected folders are logged and skipped." It bites every Win11 24H2 run that leaves SSU ticked, since 24H2 has no separate SSU. Fix: filter nulls at the top of `Add-Packages` and log "skipped, none found".
2. **Running with no languages selected fails.** `Get-SelectedLanguages` returns `$null`, then `(Get-SelectedLanguages).Count` throws under StrictMode. Same root cause reappears in `Add-OfflineLanguages` / `Add-WinPeLanguages` when the FOD ISO is mounted with no languages. Fix: `$languages = @(Get-SelectedLanguages | Where-Object { $_ })` and type parameters `[string[]]$Languages = @()`.

### High priority, from reading the code

3. **Stale-mount data loss risk.** `Invoke-MediaRefresh` empties MOUNT\MainOS, WinRE and WinPE with `Remove-Item -Recurse -Force` *before* checking for images still mounted from a crashed run. Deleting inside a live mount deletes files in that image. Add a preflight: `Get-WindowsImage -Mounted`, discard or `dism /Cleanup-Wim`, then clear. Also normalize trailing `\` when comparing mount paths in the catch blocks, otherwise the discard-on-error branch may never fire.
4. **WinRE is serviced once per index.** Microsoft's sample services it once (index 1) and copies the result into every edition. For Server 2022 (typically 4 indexes) you pay 4x the time and likely carry four different winre.wim copies in the final WIM, because they no longer dedupe. Fix: service once, cache in WINRE\, copy into each index.
5. **Server 2022 language packs cannot work as written** (update: not urgent, Server is English-only; v2.1 keeps the correct pattern in the profile). The pattern `Microsoft-Windows-Client-Language-Pack_x64_$lang.cab` is Client-only; Server media uses `Microsoft-Windows-Server-Language-Pack_x64_<lang>.cab` in `LanguagesAndOptionalFeatures`. This belongs in the OS profile.
6. **"Exactly one FOD/language ISO" is wrong for the Windows 10 LTSC profiles** (update: confirmed by your logs and ISO list; fixed in v2.1 with content-based ISO roles). Microsoft's guidance says Windows 10 language packs ship on a separate LANGPACK ISO (not the FOD ISO) and use a different folder layout. The script's name regex lumps them together and throws when two are present. Model ISO *roles* (OS, LP, FOD) per profile instead.
7. **Checkpoint cumulative updates (Win11 24H2+, Server 2025).** Microsoft says that when you add FODs or language packs, all prior checkpoint MSUs plus the target must be in one folder and installed. Your script applies every MSU it finds in filename order. The download layer must know which checkpoints the target needs and prune the rest. This is a plausible contributor to the "LCU missing" symptom you patched in 1.0.1, but I cannot confirm that without your logs.
8. **The 1.0.1 second LCU pass is correct in principle** (Microsoft applies the LCU first for the servicing stack and again last). What deviates is the order around it: you enable NetFx3 and apply the .NET CU *before* the final LCU and cleanup, whereas Microsoft's table is LCU, cleanup, then .NET + .NET CU, then export. Test both orders and let the validation gate (section 5) decide.
9. **Missing Microsoft steps.** `Language.Fonts.*` capabilities (your language list includes ja-jp, ko-kr, zh-cn, zh-tw, which need them), `dism /Gen-LangINI` for boot.wim when languages are added, and refreshing setup.exe/boot manager files from the serviced WinPE (matters only for the ISO/OS-upgrade-media path).
10. **Multi-SSU legacy chains are applied in filename order.** Not a dependency order. Use an explicit order manifest per profile (or numeric prefixes, as WimWizard does with `1_LCU`, `2_DotNet`, `3_SafeOS`).
11. **No host/target DISM check.** The DISM cmdlets and `dism.exe` come from the build host. Servicing a newer image (24H2, Server 2025) from an older host DISM is a known way to get odd failures. Add a preflight comparing host build to target build, and optionally prefer the ADK's DISM.
12. **UI thread.** All servicing runs inside the button handler. The window shows Not Responding during long DISM calls, and Cancel only works between packages. Run the engine as a separate process or runspace and stream its log to the GUI.

### Minor

- `$matches` shadows a PowerShell automatic variable; rename.
- Default root differs between the header (`C:\mediaRefresh`) and the GUI (`F:\mediaRefresh`); your project says `MediaRefresh`.
- OS display names differ from your project list (2019 is not labelled IoT).
- DISM's own log is not routed to LOGS; pass `-LogPath` to every cmdlet and `/LogPath` to dism.exe. You will want this for the "LCU missing" investigation.

## 4. Catalog acquisition layer (MSCatalogLTS)

- Module: MSCatalogLTS 2.1.0.2 (May 13, 2026), PowerShell 5.1+, cmdlets `Get-MSCatalogUpdate`, `Save-MSCatalogUpdate`. WimWizard auto-installs it.
- Patterns worth borrowing from WimWizard: derive the version string from the WIM build number; exclude Preview and wrong architecture; match a build filter to stop overlapping KBs; download LCUs through the catalog DownloadDialog call so the original filename (with hash) is kept because `Save-MSCatalogUpdate` strips it; canonical names for .NET and SafeOS; cache by KB; delete superseded files; require `.msu` for LCU so SafeOS `.cab` is never mistaken for it.
- Per-OS search rules are the piece WimWizard cannot give you. Catalog titles differ by product. Example: Server 2022 LCUs are titled "Cumulative Update for Microsoft server operating system version 21H2 for x64-based Systems". Windows 10 LTSC 2019 and 2021 use "Windows 10 Version 1809" and "21H2" titles. Put the search string, filters, and package class in each profile, and treat titles as data you can edit when Microsoft renames them.
- Keep PATCHES\ as the single source of truth. The downloader fills PATCHES\LCU, .NET, SAFEOS and so on; a `PATCHES\MANUAL` (or pinned entries in the profile) covers legacy SSUs the catalog search will not find; the servicing engine only ever reads the folders.
- Add a dry-run that shows the KB list it *would* download and apply, then requires confirmation in the GUI.

## 5. SCCM architect notes

- **Decide the SCCM object per OS.** OS Image (install.wim) needs only the serviced WIM. OS Upgrade Package (in-place upgrade) needs full media, so Setup DU, boot.wim and media refresh matter. Boot images in ConfigMgr are normally built from the matching ADK WinPE, not the OS media boot.wim, so confirm whether you actually consume the serviced boot.wim.
- **Lifecycle.** Windows 10 Enterprise LTSC 2021 (your KMS profile) reaches end of support on January 13, 2027. Windows 10 IoT Enterprise LTSC 2021 runs to January 14, 2032, and Windows 10 Enterprise LTSC 2019 to January 10, 2029. Prioritise the other profiles, and expect the LTSC 2021 KMS profile to stop receiving LCUs soon. Some reports mention an ESU plan; I did not verify it.
- **Validation gate before import.** After export, read each index with `Get-WindowsImage -ImagePath <wim> -Index n` and check the build/revision against the LCU KB, confirm the RollupFix package is present, and confirm the index count and edition names. Fail the run rather than produce a stale WIM.
- **Optional last stage.** `New-` or `Set-CMOperatingSystemImage`, version/comment stamping, DP update or staged DP group. WimWizard's implementation is a useful reference.

## 6. Roadmap

| Phase | Work | Outcome |
|---|---|---|
| 0 | Fix findings 1-3; add `-LogPath`; add stale-mount preflight | Stable v2.1 baseline. **Drafted in MediaRefresh_v2.1.ps1, needs a real-image test.** |
| 1 | Profile JSON per OS: folder, edition match/index, serviceAllIndexes, ISO roles, LP file pattern, package classes and order, catalog search rules, manual SSU list, EOL date | One engine, five profiles |
| 2 | Servicing alignment: WinRE once, checkpoint chain, fonts, lang.ini, order test for .NET, validation gate | Correct, verifiable output. **Drafted in v2.1 (checkpoint chain handling still open).** |
| 3 | Acquisition layer with MSCatalogLTS, cache, superseded cleanup, dry-run, manual override | Hands-off monthly patch set |
| 4 | Engine/GUI split, batch queue for several OSes, real Cancel, scheduled unattended run | Multi-OS monthly run |
| 5 | Optional SCCM import and DP stage | End-to-end pipeline |

## 7. Still open

1. The 1809 Language Pack ISO for LTSC 2019, the LP ISO for the KMS 2021 folder, and FOD part 1 for the IoT 2021 folder (see the table in section 0).
2. Current Setup DU and Safe OS DU files for the legacy OSes, if you want WinRE and upgrade-package media refreshed.
3. Whether WinRE servicing was switched off deliberately in the two logged runs.
4. A verification run of v2.1 on LTSC 2019 (log file), so the VERIFY lines can confirm the LCU and languages are really in the image.
5. Build host: OS and ADK version, needed before Win11 24H2 servicing.

## How this was checked

The v1 script and the v2.1 draft were parse-checked with the PowerShell 7.4 parser (0 errors). v2.1 was also run through 34 unit-style and 15 end-to-end checks with mocked DISM cmdlets. Findings 1 and 2 were reproduced with small tests that copy your `Add-Packages` and `Get-SelectedLanguages` logic under `Set-StrictMode -Version Latest`. Everything else in section 3 is from reading the code against the Microsoft sources and was not executed against real images.

## Sources

- Microsoft Learn: https://learn.microsoft.com/en-us/windows/deployment/update/media-dynamic-update
- Microsoft Learn (checkpoint CUs): https://learn.microsoft.com/en-us/windows/deployment/update/catalog-checkpoint-cumulative-updates
- WimWizard: https://github.com/TacII/WimWizard (README, releases, WimWizard.ps1)
- MSCatalogLTS on PowerShell Gallery: https://www.powershellgallery.com/packages/MSCatalogLTS
- MSCatalogLTS repo: https://github.com/dbensmith/MSCatalogLTS
- Lifecycle: https://learn.microsoft.com/en-us/lifecycle/products/windows-10-enterprise-ltsc-2021 , https://learn.microsoft.com/en-us/lifecycle/products/windows-10-enterprise-ltsc-2019 , https://learn.microsoft.com/en-us/lifecycle/products/windows-10-iot-enterprise-ltsc-2021
- Server 2022 LP filename: https://www.winhelponline.com/blog/install-language-pack-offline-server-2022/
