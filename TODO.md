# TODO - WimForge (Windows OS media patching)

Last updated: 2026-09-24. The list now tracks one script only, v2.4. Older versions moved to `archive\`, and steps 1, 3 and 5 are summarised as reference at the end.

**Build under test: `MediaRefresh_v2.4.ps1`.** It contains everything from v2.1-v2.3 (steps 1 and 3) plus the catalog download layer (step 5). The older scripts in `archive\` are kept for history only; nothing below needs them.

Where v2.4 stands:

- **Mock test kit:** 7 suites, 297 checks, all passing on Windows PowerShell 5.1 and PowerShell 7.6 (2026-09-26).
- **Real Microsoft Update Catalog:** every built-in rule for all five profiles picks the right entry from the live catalog (2026-09-24, step 2A), confirmed by GUI dry runs of all five OSes on the build machine the same evening. Real GUI downloads (LTSC 2019, LTSC 2021 KMS, Win11 24H2) the same evening found one pruning bug, fixed (step 2A).
- **Real images and real DISM:** three complete real v2.4 servicing runs, all with gate PASSED: Win11 24H2 Enterprise on 2026-09-23 and 2026-09-25 (English only), and **LTSC 2019 with ten languages on 2026-09-25 16:15-20:30** (`LOGS\`: preflight x2 + full run; WinRE was switched off). LTSC 2021 KMS / IoT and Server 2022 have not been serviced on v2.4 yet (a v2.2 run of IoT LTSC 2021 finished with 0 verify issues on 2026-09-21, but v2.3/v2.4 changed the servicing code).

## Index

Step numbers are kept from earlier versions of this list because the script, the logs and older notes refer to them. Steps 1, 3 and 5 are built; they are described under [Built into v2.4](#built) at the end.

| # | Step | Owner | Status |
|---|------|-------|--------|
| [2](#s2) | **Validate v2.4:** real catalog, real servicing runs, feature checks | Claude (catalog) + Terry (servicing) | **Now** (2A catalog done; 2B-2D open) |
| [4](#s4) | Host DISM vs image build (ADK DISM decision) | Claude + Terry | Needs the build-host answer and the Win11 24H2 run from step 2 |
| [6](#s6) | Upgrade-package media readiness and validation round 2 | Claude + Terry | After 2 |
| [7](#s7) | SCCM import: new tab, local copy to content source, import, distribute | Claude | After 2 |
| [8](#s8) | Hard cancel, batch queue, scheduled run | Claude | Last feature |
| [9](#s9) | Housekeeping and final documentation | Claude | Ongoing |
| [10](#s10) | Operator UX: INSTRUCTIONS.md + Instructions tab, saved settings, utility menu, Languages tab from Languages.json | Claude (+ Terry for the inventory script) | Not started |
| [11](#s11) | App / provisioned-app removal (debloat), first in the servicing order | Claude | Not started |
| [12](#s12) | Bootable WinPE recovery/rescue ISO (ADK-based, 2023 UEFI CA signed) | Claude | Not started |
| [13](#s13) | Expand OS support: Windows 11 25H2, Windows 11 26H2, Windows Server 2025 | Claude + Terry | Not started |

Order of work: validate v2.4 first (2), settle the DISM question (4), then the new features. The SCCM import (7) waits for a validated image, and hard cancel / batch queue (8) comes last because it changes how every other step is started and stopped.

---

<a id="s2"></a>
## 2. Validate v2.4: real catalog, real servicing runs, feature checks

**Owner:** Claude for 2A, Terry for 2B (Claude reads the logs), both for 2C. **Done when:** 2A, 2B and 2C are all ticked off, and any fixes found along the way are made in v2.4 with a test added for each.

### 2A. Real catalog (Claude, on Terry's PC) - done 2026-09-24

This PC has Windows PowerShell 5.1 with **MSCatalogLTS 2.1.0.1** installed (not installed for PowerShell 7), and catalog.update.microsoft.com is reachable, so Claude ran every built-in rule through the script's own engine (`Search-CatalogCandidates`) against the live catalog.

**What the live catalog picks now (x64, newest first, 2026-09-24)**

| Profile | LCU | .NET CU | Safe OS DU | Setup DU |
|---|---|---|---|---|
| LTSC 2019 (1809) | KB5129238 | KB5126144 (3.5, 4.7.2 and 4.8) | KB5122886 (2026-09) | KB5068795 (2025-11) |
| LTSC 2021 IoT / KMS (21H2) | KB5129236 | KB5126145 (3.5, 4.8 and 4.8.1) | KB5122887 | KB5126029 |
| Win11 24H2 | KB5129195 (26100.9457, entry also carries checkpoint KB5043080) | KB5126052 (3.5 and 4.8.1) | KB5125758 | KB5127216 |
| Server 2022 | KB5129237 | KB5126149 (3.5, 4.8 and 4.8.1) | KB5122889 | KB5126031 |

Terry's real download run the day before (`MediaRefresh_20260923_084200.log`, LTSC 2019) shows the same problem from the GUI: the LCU (KB5129238) and both .NET CU files (KB5126043, KB5126048) were downloaded and the older files pruned correctly, but Safe OS and Setup DU got 0 raw results for a rule that is correct. That is the module behaviour fixed below.

**Fixed in v2.4 (test kit now 255 checks)**

- **Safe OS and Setup DU searches could never return anything.** The installed MSCatalogLTS 2.1.0.1 differs from the upstream source the script was written against: it drops every title containing "Dynamic" unless `-IncludeDynamic` is passed, reads only the first page (25 rows) unless `-AllPages` is passed, and rewrites a search starting "Dynamic Update for ..." into its own "Cumulative Update for <OS>" query. `Invoke-CatalogUpdateSearch` now passes `-IncludeDynamic` and `-AllPages` when the module declares them, and sends the search with a leading space so the module's rewrite does not match (the catalog trims it). It also passes `-IncludePreview` when a rule sets `excludePreview` to false (2.1.0.1 has no `-ExcludePreview`; previews are hidden by default).
- **The catalog returns nothing for a search over 100 characters** (106 characters: 0 results; 93: 41). Profiles now refuse such a search when they load, with a message saying so.
- **Built-in rules corrected from the real results:** 21H2 and Server 2022 NetCU use the combined "3.5, 4.8 and 4.8.1" entry (two files each, like 1809); 21H2 and Server 2022 Safe OS / Setup DU use the 1809 pattern (plain "Dynamic Update for ..." title, told apart by the Products field); Win11 24H2 gained a NetCU rule (its .NET CU *is* a separate catalog entry) and title filters on Safe OS / Setup DU (its titles changed from "Windows 11 Version 24H2" to "Windows 11, version 24H2" in 2026-05; the filters accept both). Profile notes now say the rules were checked on 2026-09-24.
- **Test kit under Windows PowerShell 5.1:** two test-only fixes (a three-part `Join-Path`, and a JSON check that assumed PowerShell 7 spacing). All 7 suites pass on 5.1 and 7.

**GUI dry runs on the build machine (Terry, 2026-09-24 22:16-22:18): all five OSes, 20 of 20 picks correct, no WARN or ERROR lines**

Run with the regenerated profiles (`Profiles_corrected_2026-09-24.zip`, written by the script's own `Save-BuiltInProfiles` and reloaded with 0 differences from the built-ins). Every pick matches the table above. Logs: `MediaRefresh_W10LTSC2019_1809.log` and the four in `MediaRefresh.zip`. Base builds read from the ISOs: LTSC 2019 10.0.17763.107, LTSC 2021 IoT and KMS 10.0.19041.1288 (21H2 is an enablement package on 19041), Win11 24H2 10.0.26100.9168, Server 2022 10.0.20348.5499.

**Still open**

- [x] **Regenerate the `Profiles` folder** on the build machine (done 2026-09-24; the dry runs above used the new files).
- [x] **Fixed 2026-09-24: the "WimForge - confirm download" message listed every KB twice** (Terry). Cause: the line is built as `<class>: <title> (<KB>)`, but the catalog title already ends in the KB, e.g. `LCU: 2026-09 Cumulative Update ... (KB5129238) (KB5129238)`. The run log's `selected '...' (KB...)` line doubles it the same way. Fixed with `Format-CatalogPick` (adds the KB only when the title does not already contain it), used for both the dialog and the log line; 7 new checks (test kit 262). **Not a double download**: checked in the code, the plan holds one entry per class (per search term), and the real run downloads each entry once (the 2026-09-23 real download log shows one download per class). A test now also confirms a real run downloads the picked entry exactly once; confirm again on the next real GUI download.
- [x] **Fixed and confirmed on a real run 2026-09-25: LCU + checkpoint - only the target LCU is installed, the checkpoint stays in the same folder** (Terry, 2026-09-24). The LCU step used to call `Add-WindowsPackage` for every file in `PATCHES\LCU`, so with the checkpoint present it would have added KB5043080 directly to WinRE, install.wim and WinPE (confirmed by running the new test against the previous script). Microsoft's method for offline media ([Checkpoint cumulative updates and the Microsoft Update Catalog](https://learn.microsoft.com/en-us/windows/deployment/update/catalog-checkpoint-cumulative-updates); the KB5129195 page says the same): put the target LCU and all earlier checkpoint `.msu` files in one folder with no other `.msu` files, add the latest `.msu` as the sole target, and DISM installs the checkpoints the image still needs. Now `Resolve-LcuTarget` (called from `Get-PackageSet`) picks the target as the `.msu` with the highest KB when `PATCHES\LCU` holds more than one; every LCU install point (install.wim, WinRE, WinPE) adds only that file, the log names the checkpoint(s) left in the folder, and a checkpoint in a different subfolder from the target gets a WARN. A single LCU file (every Win10 / Server 2022 profile) or files with no KB number are installed as before. The early "failed" Win11 run in `LOGS.zip` turned out to be the successful 2026-09-23 run (only the LCU was in the folder then), so no real failure was seen - the next Win11 run is the first with the checkpoint present. 7 new checks (test kit 282).
  - **Real-run confirmation (Terry, 2026-09-25 09:44-11:04, `LOGS.7z`):** the log says `LCU: only windows11.0-kb5129195-x64.msu is installed; windows11.0-kb5043080-x64.msu stay in the folder ...`, and every "Adding LCU" line names only KB5129195. The DISM log shows DISM picking the checkpoint up from the same folder and skipping it because the image is already past it, for WinRE (09:51) and install.wim (09:58): `Processing metadata source ...\PATCHES\LCU\windows11.0-kb5043080-x64.msu` then `Not applicable ... Feature: CumulativeUpdate_KB5043080`. Image 10.0.26100.9457, 0 verify issues, gate PASSED.
- [ ] **LCU into WinRE: Microsoft says it does not apply** (found 2026-09-25 while checking the checkpoint guidance). The same Microsoft page says monthly LCUs apply to install.wim and boot.wim "but not to WinRE (winre.wim)"; WinRE is serviced with the servicing stack update from the LCU plus the Safe OS Dynamic Update ([Update Windows installation media with Dynamic Update](https://learn.microsoft.com/en-us/windows/deployment/update/media-dynamic-update)). The script adds the LCU to WinRE today (`Add-Packages $WinReMount $Packages.LCU ... -IgnoreCombinedLcu7007e`); on the 2026-09-23 Win11 run it succeeded in about 77 s. To do: check the Dynamic Update article's exact WinRE steps (including how the SSU inside a combined LCU is applied to WinRE), decide with Terry whether to stop adding the LCU to WinRE, and test on a real run with WinRE on.
- [x] **Done 2026-09-26: languages go into install.wim only - never WinRE, never boot.wim (decision, Terry 2026-09-26).** WinRE and boot.wim (WinPE / Setup) stay English-only. Removed: `Add-WinPeLanguages` (the WinRE and boot.wim language step, including the WinPE component cabs, fonts and speech), `Find-WinPeOcRoot` (the WinPE_OCs lookup that only served it), the boot.wim `lang.ini` regeneration (only needed after adding languages), and the `OcRoot` / `Languages` parameters of `Service-WinRe` and `Service-BootWim`. WinRE keeps its SSU / LCU / Safe OS DU servicing and boot.wim its patching. A run with languages and WinRE or Boot ticked logs "Languages are added to install.wim only; WinRE and boot.wim stay English-only." Verify had no WinRE / WinPE language checks. 5 new checks (a ten-language run with WinRE and Boot ticked adds no language cab to either; the old script added `lp.cab` to both). WinRE and Boot can now be ticked on runs with languages.
- [x] **Real downloads from the GUI (Terry, 2026-09-24 22:37-22:39; logs `W10ltsc2019_1809.log`, `W10LTSC2021_KMS.log`, `w11.log`).** LTSC 2019 and LTSC 2021 KMS: every pick downloaded, both .NET CU files kept (1809: KB5126043 + KB5126048; 21H2: KB5126046 `-ndp48` + KB5126421 `-ndp481`), last month's LCU / .NET / Safe OS files pruned. Win11 24H2 .NET CU is one file by design (the "3.5 and 4.8.1" entry has a single download, KB5126052). Terry checked the other OSes' downloads by eye.
- [x] **Fixed 2026-09-24: the Win11 24H2 real download deleted the LCU it had just picked** (`Removed superseded file windows11.0-kb5129195-x64.msu`). MSCatalogLTS 2.1.0.1 skips a file that already exists unless `-Force` is passed; the LCU file was already in `PATCHES\LCU`, so only the checkpoint was written, and the pruning (which keeps only files new or re-written in this run) removed the LCU. Fixed two ways: `Save-CatalogCandidate` passes `-Force` when the module declares it (a pick is always re-downloaded - costs bandwidth on a repeat run, several GB for the Win11 LCU + checkpoint), and as a safety net `Update-PatchCache -KeepKbs` never removes a file whose KB was picked in this run unless this run also saved a file with that KB (the older long-name copy is then a true duplicate). 6 new checks reproduce the run (test kit 268). **Action for Terry:** the Win11 `PATCHES\LCU` folder probably holds only `windows11.0-kb5043080-x64.msu` now - pull the fix and run the Win11 download again (or copy `windows11.0-kb5129195-x64.msu` back) before any Win11 servicing run.
- [ ] **1809 Setup DU:** the newest one is from 2025-11. Setup DUs for 1809 are released less often than Safe OS DUs, so this is expected, but worth a glance at the catalog before relying on it.

### 2B. Real servicing runs (Terry, on the build machine)

**Inputs still needed**

| OS folder | Needed | Why |
|---|---|---|
| Win10_Enterprise_LTSC_2019 | ~~1809 Language Pack ISO~~ **done 2026-09-25**: `SW_DVD9_NTRL_Win_10_1809_32_64_ARM64_MultiLang_LangPackAll_LIP_X21-91305.ISO` | The first attempt (`MediaRefresh_20260925_143636.log`) stopped because only the FOD ISOs were present. FOD ISOs carry `Microsoft-Windows-LanguageFeatures-*` capability cabs, which add spelling, fonts, OCR and speech on top of a language; the display language itself comes only from `Microsoft-Windows-Client-Language-Pack_x64_<lang>.cab` on the Language Pack ISO. |
| Win10_Enterprise_LTSC_2021_KMS | Copy the `LangPackAll` (2004 family) ISO into this folder | It currently has only the OS ISO and FOD part 1. |
| Win10_IOT_Enterprise_LTSC_2021 | FOD part 1 ISO, **or** confirmation that the LangPackAll ISO already carries `Microsoft-Windows-LanguageFeatures-*` cabs | Check with `Get-ChildItem X:\ -Recurse -Filter 'Microsoft-Windows-LanguageFeatures-*'` on the mounted ISO. |
| Win11 24H2, Server 2022 | Fresh Microsoft ISOs each cycle | English only, no LP/FOD ISOs needed. |

**Questions to answer**

- Build host: OS version and ADK version (drives step 4).
- Settled already: SCCM content sources are on `<SCCM-SOURCE-SERVER>` (this server); the LTSC 2019 SSU is KB5005112 (x64); the LTSC 2021 IoT and KMS SSU is `ssu-19041.3562-x64.msu`; the IoT 2021 edition selection works (v2.2 run, 2026-09-21).

**Before any run**

- `Unblock-File` the script and run it from elevated Windows PowerShell 5.1.
- **Antivirus exclusion: check it is really in place.** The v2.2 IoT 2021 run took about 3h53m. A few steps took far longer than the rest (LCU pass 1 ~46 min, LCU final ~38 min, one .NET CU ~29 min, cleanup ~24 min, against ~5-7 min per language pack). Its DISM log has 30,000+ benign `Error CSI ... Matching binary ... missing for component ... dualModeDriver` entries (Hyper-V driver components). Both point to real-time scanning fighting DISM. Confirm the exclusion covers the MediaRefresh folder including each OS's `MOUNT` subfolder, then compare the timings on the next run. **Update 2026-09-25:** the LTSC 2019 ten-language run spent 1 h 40 min in component cleanup alone - check the exclusion covers `F:\mediaRefresh\<OS>\MOUNT` before the Server 2022 runs (four indexes).
- Tens of GB free. v2.4 checks this itself and archives the previous `NEWWIM` output, so nothing needs renaming by hand.
- Fill `PATCHES` with "Download patches..." (after 2A) or by hand; the SSU always goes into `PATCHES\SSU` by hand.

**Runs, in order** (full test plan in `MediaRefresh_Review_and_Roadmap.md`, section 0)

1. [ ] Preflight only, on every OS folder. Check the ISO role lines, patch counts, the language pack check and the `Detected indexes` / `Selected client image index` lines. Done so far: Win11 24H2 (2026-09-25) and LTSC 2019 (2026-09-25, all 10 language packs located).
2. [ ] First v2.4 servicing run: **LTSC 2021 KMS, de-de + ja-jp only**, WinRE on, NetFx3 on, Verify on (about 1.5 hours).
3. [ ] LTSC 2021 KMS with all ten languages.
4. [ ] Server 2022 (English only, four indexes). Confirm WinRE is serviced once and the same winre.wim is reused for every index.
5. [x] LTSC 2019 - **done 2026-09-25 16:15-20:30 on v2.4, ten languages, gate PASSED**, with WinRE off and no Setup DU / media. SSU KB5005112, LCU pass 1 KB5129238 (29 min), 10 language packs (5-6 min each) each with Basic, OCR, Handwriting, TextToSpeech and Speech, fonts Jpan / Kore / Hans / Hant, LCU final (14 min), **component cleanup 1 h 40 min** (18:06-19:45; 24 min on the v2.2 IoT run, 6 min on Win11 - see the antivirus note), NetFX3, .NET CU. Verify: build 10.0.17763.9247, all 10 language packs present, 58 language capabilities, 0 issues. **.NET CU pair confirmed on real DISM:** KB5126043 (3.5 + 4.7.2) applied; KB5126048 (4.8) was rejected by CBS as not applicable (`0x800f081e`, `Skipping package ... current: Absent`) because the image has 4.7.2 - but `Add-WindowsPackage` returned success for the .MSU, so the run logged no skip and the change log listed the 4.8 part as added. **Fixed 2026-09-26:** where skipping is allowed (.NET CU), the image's package list is compared before and after each file; no change is logged as a WARN and recorded as "skipped, not applicable". The build machine was still on a copy without the 2026-09-25 change-log fixes (all Section A rows at 20:30:22, a `Deleted` row in Section B) - pull `main` before the next run.
6. [ ] IoT LTSC 2021 (repeat on v2.4).
7. [x] Win11 24H2 (English only; WinRE, NetFX3, Verify and media on) - **done 2026-09-23 on v2.4, gate PASSED** (see "Where v2.4 stands"). The LCU folder held only KB5129195 then, so the checkpoint question (2A) did not come up; since the 2026-09-24 download it also holds KB5043080; the LCU step now installs only KB5129195 and leaves the checkpoint to DISM (fixed 2026-09-25), and the next Win11 run is the first real test of that. Timing: WinRE about 3 min, LCU about 33 min, .NET CU about 21 min, whole run 82 min. DISM log errors were the usual noise (0x80070490 progress, TurboStack hydration, "failed to get hash info").
   - **Second Win11 run, 2026-09-25 (after the re-download):** download 09:40 (LCU entry downloaded KB5043080 + KB5129195, both kept; .NET KB5126052, Safe OS KB5125758, Setup DU KB5127216), preflight 09:44, full run 09:44-11:04 (80 min): WinRE with LCU + Safe OS DU (WinRE now 26100.9545) about 4.5 min, LCU on install.wim about 31 min, cleanup about 6 min, .NET CU about 18 min, export, verify (0 issues, gate PASSED), media folder with the Setup DU expanded, change log. English only; the new `SW_DVD9_Win_11_24H2_25H2_x64_MultiLang_LangPackAll_LIP_LoF` ISO was detected as the Language Pack / FOD source.

- On a real console, confirm that clicking in the console no longer pauses the run (Quick Edit fix) and that the window stays responsive during mount and patch.
- After each run, send `MediaRefresh_*.log`, `DISM_*.log` and the `ChangeLog_*` files from `LOGS`. The `VERIFY` lines are the evidence that the LCU and languages are really in the image.

**Done when:** each OS produces an install.wim whose VERIFY lines show the expected RollupFix, languages and fonts, the validation gate says PASSED, and there is no crash or hang.

### 2C. v2.4 feature checks (tick off during the 2B runs)

These are the "Try it" checks from steps 1, 3 and 5. They were only ever confirmed in mock tests.

- [ ] A `Profiles` folder with five JSON files appears beside the script on first start; the OS list, the support-date line under it and "Reload profiles" work. An edited file applies to the next run, and a broken file is reported and skipped.
- [ ] The preflight log shows the `Profile:`, `Support ends`, `... order:` and `Free space on ...` lines, and packages are applied in the logged order.
- [x] The previous `NEWWIM` output is moved to `NEWWIM\Archive\<timestamp>` just before new output is written; only the newest 3 archives are kept. Preflight never archives. Confirmed 2026-09-25 (Win11): `Previous output (4 item(s)) archived to ...\NEWWIM\Archive\20260925_094434`.
- [ ] The free-space estimate is neither too strict nor too loose (otherwise tune `minFreeGB`, or set `spaceCheck` to `warn`).
- [ ] The header shows the OS and a phase that matches the log throughout a run ("Servicing install.wim (index N of M)" on Server), then Done, Failed or Cancelled.
- [x] `ChangeLog_<OS>_<build>_<timestamp>.html` and `.csv` land in `LOGS` and beside the output in `NEWWIM`. Section A matches the `VERIFY` lines, the OS ISO is the first source line, and the header's gate result matches the log. Confirmed 2026-09-25 (Win11, gate PASSED in the header). Three problems found and fixed the same day: (1) every Section A row showed the time the log was written (11:04:10) instead of the time its step succeeded - rows now carry each change event's own time; (2) the Setup DU expanded into the media was not listed - it is now a Section A row (target `Media\sources`); (3) see Section B below.
- [ ] Section B (derived dates, hotfix list, appx inventory) is worth reading on real data, or needs trimming. **Partly done 2026-09-25:** the staged-appx list included `Deleted` and `Merged`, which are Windows' housekeeping folders under WindowsApps, not packages; only folders named like packages (`<Name>_<Version>_...`) are listed now (`Test-AppxPackageFolder`). Still to judge: whether the rest of Section B is worth reading.
- [x] "Download patches..." shows a dry-run list first, downloads only after confirmation, prunes superseded files in `PATCHES\<class>`, never touches `PATCHES\SSU`, and the downloads show up in Section A of the next servicing run's change log. Confirmed on the real GUI runs of 2026-09-24/25 (dry-run list, confirmation, pruning, SSU untouched; the downloads show up in Section A of the next run's change log).

### 2D. Profile data (Terry)

- [ ] Fill in the Win11 24H2 and Server 2022 end-of-support dates from the Microsoft lifecycle pages (the `endOfSupport` key in the JSON files; the built-in profiles in the script can be updated at the same time).

<a id="s4"></a>
## 4. Host DISM vs image build (ADK DISM decision)

**Owner:** Claude + Terry. **Depends on:** 2 (the build-host answer and the Win11 24H2 run).

The script only logs a warning when the host DISM is older than the image. Servicing Win11 24H2 (build 26100) from a Server 2022 host (DISM 10.0.20348) is a known source of odd failures. Options: detect and use the ADK's newer DISM for both the cmdlets (module path) and `dism.exe`, or require a newer build host. It is a small change once decided, but it touches every DISM call, so do it once, before the SCCM step adds more code.

**First data point (2026-09-23):** the Server 2022 host's DISM 10.0.20348.2849 serviced the Win11 24H2 image (26100.9168 -> 26100.9457) with no failure - only the expected "host DISM is older" WARN, and the gate PASSED. One clean run does not prove it is safe (language packs and FODs were not part of it), so keep the decision open until a Win11 run with languages.

**Second data point (2026-09-25):** the same host DISM serviced Win11 24H2 again, this time with the LCU checkpoint in the folder, Safe OS DU into WinRE and the Setup DU into the media - no failure, gate PASSED. Still no run with languages.

**Third data point (2026-09-25):** the same host DISM serviced LTSC 2019 (17763) with ten languages and their FODs - no failure. That is an older image than the host, so it says nothing about the 26100 case; Win11 with languages is still the missing test.

<a id="s6"></a>
## 6. Upgrade-package media readiness and validation round 2

**Owner:** Claude + Terry. **Depends on:** 2 (a validated v2.4, including the Setup DU download).

- Confirm whether setup.exe and boot manager files in the media folder should be refreshed from the serviced WinPE (Microsoft step; matters only for the media/ISO path used by Upgrade Packages), and add it if so.
- The engine follows Microsoft's order (LCU, cleanup, then NetFx3 and .NET CU). If a real run shows the .NET CU or the LCU missing after deployment, test the alternative order and let the validation gate (step 3) decide.
- Terry runs the second round: an OS with the downloader-fed patch set, media folder built, change log and gate checked.

<a id="s7"></a>
## 7. SCCM import: new tab, local copy to content source, import, distribute

**Owner:** Claude. **Depends on:** 1 (dated output), 3 (change log for the image comment, validation gate so a failed image is never imported), 5 (a current image), 6 for the upgrade-package path.

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

**Owner:** Claude. **Depends on:** 3, 5, 7 (they define what one OS run is).

- **Hard cancel:** stop a running DISM call, then clean up (discard/unmount any live image, clear mount folders, dismount ISOs). Cancel today works at the next safe point between operations. The start-up stale-mount cleanup is the safety net for anything orphaned.
- **ISO mount hygiene (Terry, 2026-09-22):** two related fixes, small enough to do independently of the rest of this step.
  - **Detect ISOs already mounted at start.** `Clear-StaleMounts` already discards stray WIM mounts under the OS's `MOUNT` folder before a run; there is no equivalent check for ISOs. An ISO left mounted from a crashed run (or mounted by hand) that is not one of the files the current run iterates would go unnoticed. Add a preflight step that lists currently-mounted disk images (`Get-DiskImage`) matching this OS's ISO folder and dismounts anything found there before the run starts, logged the same way as the stale-mount cleanup.
  - **Keep ISOs mounted until the completion dialog is dismissed.** Today `Invoke-MediaRefresh` dismounts every ISO it mounted in its own `finally` block, so they are gone before the completion dialog even appears. Change this so a **successful** run leaves its ISOs mounted, hands their paths back to the GUI (the background-run result), and the GUI dismounts them only after the user clicks OK on the completion dialog (Dism cmdlets are available on the main thread too, since the module is imported at start-up). A **failed or cancelled** run should keep dismounting immediately in the engine's `finally`, as a safety net — there is no guaranteed "OK click" to hang cleanup on when the run didn't finish normally. Decide whether Preflight's own completion dialog gets the same treatment for consistency, or dismounts right away since it never touched an image.
- **Batch queue:** tick several OS profiles and process them one after another, one change log each, a summary at the end, the phase line showing "OS 2 of 3", and cancel semantics that make sense (skip this OS / stop all).
- **Scheduled run** (later): a monthly unattended run after Patch Tuesday with a summary file or email.

<a id="s9"></a>
## 9. Housekeeping and final documentation

**Owner:** Claude. **Ongoing.**

- Keep `MediaRefresh_Review_and_Roadmap.md` and this file in step with the script; update the roadmap as steps close.
- Check WimWizard's licence before reusing any of its code (steps 5 and 7).
- Version numbering: v2.4 is the build under test; once it passes step 2 it becomes the first tested release with a clean version number (and ideally a file name without the version, with older builds left in `archive\`). Settle one default repository root (header says `C:\mediaRefresh`, GUI says `F:\mediaRefresh`).
- Minor code items from the review: rename the `$matches` variable; make OS display names match the project list.
- Operator guide: superseded by step 10's `INSTRUCTIONS.md` (folders, ISO roles, preflight first, where logs and change logs land, plus a full GUI walkthrough) rather than a separate write-up here.

<a id="s10"></a>
## 10. Operator UX: INSTRUCTIONS.md + Instructions tab, saved settings, utility menu, Languages tab

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

**10e. Languages tab driven by `Languages.json` (Terry, 2026-09-26)**

- **Source list.** Terry's `Languages.json` (committed at the repo root, 2026-09-26) is the reference for which languages the Languages tab shows: an array of `{ "language": "German (Germany)", "code": "de-de" }`. Today the list is hard-coded in the XAML (de-de, en-gb, es-es, fr-fr, it-it, ja-jp, ko-kr, pt-br, zh-cn, zh-tw).
- **Where it lives.** At run time the file is `Profiles\Languages.json`, beside the OS profiles. Same convention as the profiles: the script carries the list as a built-in, writes `Profiles\Languages.json` when it is missing, reads it at start-up and on "Reload profiles", and a bad or empty file is reported and replaced by the built-in list, never a crash. (`Profiles\` is not in source control, so the repo copy is the reference.)
- **Display.** Each entry shows the full name followed by the code, e.g. `German (Germany) - de-de`; the list is wide enough for the longest name (`Chinese (Simplified, China) - zh-cn`). Selection, saved settings and the engine keep using the code only (item `Tag` = code, display text = name + code).
- **Profile defaults.** Each profile's `defaultLanguages` should be a subset of the list; a default that is not in the list gets a WARN and is not selected. As of 2026-09-26 the built-in default set (de-de, en-gb, es-es, fr-fr, it-it, ja-jp, ko-kr, pt-br, zh-cn, zh-tw) is fully in `Languages.json` - Terry added en-gb "English (United Kingdom)" and zh-tw "Chinese (Traditional, Taiwan)" and removed en-us (the base language of every English source image), 20 entries.
- **New languages not yet in any run:** ca-es, cs-cz, hu-hu, pl-pl, pt-pt, ro-ro, ru-ru, sk-sk, sv-se, tr-tr. The preflight shows whether each OS's Language Pack ISO has `Microsoft-Windows-Client-Language-Pack_x64_<code>.cab` for them (it names any that are missing). ca-es: no evidence so far that its file name differs on any ISO - an earlier note assumed it might, from general knowledge that Catalan was a Language Interface Pack on some Windows 10 releases; nothing in Terry's ISOs or logs shows that. Check it with the first preflight that selects it.

**Done when:** `INSTRUCTIONS.md` exists and covers the folder layout, every GUI control, and exactly where each log type lands; the Instructions tab renders it as formatted Markdown (headings/lists/bold actually look like headings/lists/bold, not a wall of `#`/`-`/`**` characters); a run's option selections are saved and reappear pre-selected on the next start-up; and the menu's three actions all work without requiring a full servicing run — Clear Settings and Cleanup Mountpoints can be built and mock-tested now, Image Inventory once Terry's script arrives. 10e: the Languages tab lists exactly the entries of `Profiles\Languages.json` as "full name - code", created from the built-in list when missing, and each profile's defaults are pre-selected from it.

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

<a id="s13"></a>
## 13. Expand OS support: Windows 11 25H2, Windows 11 26H2, Windows Server 2025

**Owner:** Claude + Terry. **Depends on:** 1 (profile schema/folder conventions) and 5 (acquisition layer - each new OS needs its own `catalogSearch` rules). Added 2026-09-22, requested by Terry.

Add these three OSes to the set the tool services, alongside the existing five (LTSC 2019, LTSC 2021 IoT, LTSC 2021 KMS, Win11 24H2, Server 2022).

- **New profile per OS.** Same shape as the existing five: `folder` (and the matching `MediaRefresh\<folder>\{ISO,LOGS,MOUNT,OLDWIM,NEWWIM,PATCHES,TEMP,WINPE,WINRE,WORKING}` tree), `editionRegex`/`preferredIndex` (or `serviceAllIndexes` for Server), `lpPattern`, `defaultLanguages`, `endOfSupport`, and a `catalogSearch` block (LCU/NetCU/SafeOS/SetupDU search strings). Like the current five, treat every search string as best-effort until spot-checked against the real catalog - not assumed correct on the first try.
- **Windows 11 25H2 and 26H2.** Confirm current release/servicing status and exact catalog title conventions before building the profile - Microsoft Update Catalog title text for a newer release can differ from the 24H2 pattern already in use, and 26H2 in particular should be confirmed as actually released and catalog-searchable before relying on it. Decide whether 25H2/26H2 are meant to replace the 24H2 profile over time or run alongside it as separate profiles - affects whether the 24H2 profile is retired later.
- **Windows Server 2025.** Likely follows the same `serviceAllIndexes = true` / every-index-patched-and-recombined pattern as Server 2022, with the Server language pack pattern (`Microsoft-Windows-Server-Language-Pack_x64_{0}.cab`). Confirm the LCU/NetCU/SafeOS/SetupDU catalog title conventions for 2025 specifically rather than assuming they match 2022's wording.
- **Source media.** Terry supplies the OS ISO (and FOD/language ISO where relevant) for each new OS in its `ISO\` folder, same as the existing five - nothing here can be built without the source media in hand.
- **.NET CU check.** While building these, check how each ships its .NET CU. For 1809 it is one combined catalog entry that downloads one file per .NET version (step 5, "Real catalog facts"); a rule's `search` also accepts an array of terms if a product needs more than one entry.

**Done when:** a profile exists for each of the three OSes (built-in or added the same way Terry can add any custom OS profile), the servicing engine runs against each with no code changes beyond the profile files, and at least one real (or dry-run) catalog search per OS confirms the search strings actually return the right update.

---

<a id="built"></a>
## Built into v2.4 (reference)

These steps are built and pass the mock test kit. What is left for them is real-world confirmation, which is tracked in step 2. They are kept here because later steps build on them and refer to them by number.

<a id="s1"></a>
### 1. Foundation: JSON profiles, package order, end-of-support dates, safe dated output

- **1a. OS profiles as JSON files.** One file per OS in `Profiles\` beside the script: display name, folder and alternate folder names, edition regex / preferred index, service-all-indexes flag, language pack pattern, default languages, SSU required flag, package order, end-of-support date, catalog search rules, notes. The built-in profiles are written out when the folder is empty; "Reload profiles" re-reads them and every run re-reads them too. A bad or incomplete file is reported and skipped, never crashes the run. Unknown keys are ignored, so later steps (7: SCCM defaults) can add keys without a new format. A new OS needs a JSON file, not a code change.
- **1b. Package order manifest.** Per package class (SSU, LCU, .NET CU, Safe OS DU, Setup DU), an optional ordered list of wildcard file-name patterns (`packageOrder`). Matching files go first in that order, the rest in name order. The applied order is logged; a pattern that matches nothing logs a WARN.
- **1c. End-of-support dates.** `endOfSupport` per profile: a WARN at the start of a run when past or within 180 days, and a line under the OS selector (red when near or past). Known dates: LTSC 2021 KMS **2027-01-13** (already inside the 180-day window), IoT LTSC 2021 2032-01-14, LTSC 2019 2029-01-10. The decision on when to retire the KMS image stays with Terry.
- **1d. Safe dated output.** Before a real run writes anything, the previous `NEWWIM` output moves to `NEWWIM\Archive\<yyyyMMdd_HHmmss>`; the newest `keepArchives` (default 3; 0 keeps all) are kept. A free-space check in preflight and before a real run: about 3x the source WIM plus 6 GB scratch, plus the ISOs for media/ISO builds, never below the profile's `minFreeGB` (30 GB client, 60 GB Server). `spaceCheck` = enforce, warn or off.
- **1e. Test kit** in `testkit\`: see `testkit\README_TESTKIT.md`.

<a id="s3"></a>
### 3. Run reporting: title-bar phase, change log (HTML + CSV), validation gate

All three read the same instrumentation: a `Set-Phase` call at each stage boundary, an `Add-ChangeEvent` call at each point something is successfully added to the image, the ISO file names from the role map, and the finished image's contents read once from the read-only verification mount (`Test-OutputWim`).

- **3a. Title bar.** "WimForge" on the left; right-aligned, the OS being worked on (the selected OS while idle) and the current phase below it. Phases include Mounting ISOs, Clearing stale mounts, Exporting image, Servicing WinRE, Adding SSU, Adding LCU, language packs, FODs and fonts, Component cleanup, .NET, boot.wim, Verifying, Building media / ISO, Writing change log, then Done / Failed / Cancelled. Later steps add their own phases (11: Removing apps; 7: Copying to content source, Importing to SCCM; 8: "OS 2 of 3").
- **3b. Per-image change log.** `LOGS\ChangeLog_<OS>_<build>_<timestamp>.html` and `.csv` from one row list, copied beside the output in `NEWWIM\`. Header: OS and final build, every source ISO by file name (OS ISO first), build before/after, run date, tool version, edition/index, languages, gate result. **Section A:** everything this run changed, with a timestamp (SSU, LCU, language packs, fonts, capabilities, Safe OS, .NET CU, WinRE, NetFx3, cleanup), with the KB parsed from the file name. **Section B:** the finished image's packages, capabilities, enabled features, provisioned appx, staged appx folders and hotfixes (derived from package names, since `Get-HotFix` is live-only). Columns: `Date | Section | Item | Version / KB | State | Source | Index`. With Verify off, only Section A is written and the log says so. Terry's inventory script was the starting point for Section B (see step 10d).
- **3c. Validation gate.** `PASSED` when verification finds no issues (RollupFix, language pack and font checks), `FAILED` when it finds any, `Skipped` when Verify was off or the run was Preflight-only. **Decision: the gate flags, it does not block.** A failed image is still written, but the log says `VALIDATION GATE: FAILED` at ERROR level, the change log header is marked FAILED and the completion dialog warns. Step 7 decides whether to refuse a failed image at import.

<a id="s5"></a>
### 5. Acquisition layer: MSCatalogLTS download, Setup DU / Safe OS DU, checkpoint CUs

**Module:** MSCatalogLTS ([Marco-online/MSCatalogLTS](https://github.com/Marco-online/MSCatalogLTS)), a fork of [ryan-jan/MSCatalog](https://github.com/ryan-jan/MSCatalog). The parameter handling was checked against the installed 2.1.0.1 on 2026-09-24 (step 2A); it differs from the upstream source in ways that matter (below).

**How it works**

- **"Download patches..."** (next to Reload profiles) always starts with a dry run: it searches the catalog for every ticked class, then lists exactly what it found (title and KB per class) and asks for confirmation before anything is downloaded or removed. A class with no match is listed as skipped and the other classes still run. It runs on the background runspace, exclusive with a servicing run; Cancel works the same way.
- **Profile rules** (`catalogSearch.<class>` for `LCU`, `NetCU`, `SafeOS`, `SetupDU`): `search` (a string, or an array of strings searched independently), `architecture` (default `x64`; `''` switches the check off), `excludePreview` (default true), `buildFilter` (regex against the title), `productFilter` / `productExclude` (regex against the Products field), `checkpointKBs`. Invalid rules and invalid regexes are refused when the profile loads. `catalogSearch.SSU` is refused: **SSUs stay manual** and `PATCHES\SSU` is never touched.
- **Engine:** installs MSCatalogLTS from the Gallery (CurrentUser) on first use, reads the base image build from the OS ISO for `{build}`/`{version}` substitution, searches, filters and sorts newest first, downloads with `Save-MSCatalogUpdate` (search: `-IncludeDynamic`, `-AllPages`, `-Architecture`, and `-IncludePreview` / `-ExcludePreview` per the rule; download: `-DownloadAll` / `-AcceptMultiFileUpdates` / `-Force`; each only when the installed module declares it), then prunes `PATCHES\<class>` to this run's files plus the checkpoint list, logging every keep and remove. Every download is recorded with `Add-ChangeEvent`, so it appears in the next servicing run's change log.
- **Servicing:** a .NET CU part that does not apply to the image (0x800f081e) is skipped with a WARN and a change-log line; every other class still fails on it.

**Real catalog facts (Terry's LTSC 2019 tests 2026-09-23; all profiles 2026-09-24)**

- Results have **no Architecture property** (only Title, Products, Classification, LastUpdated, Version, Size, SizeInBytes, Guid, FileNames), and the search matches words loosely: "for x64" in the search still returns the x86 entry. The x86 .NET entry names no architecture in its title. So the title must name the profile's architecture, and a downloaded file whose name names another architecture is deleted with a WARN.
- **A catalog entry can download several files.** The combined 1809 .NET CU `...3.5, 4.7.2 and 4.8 for Windows 10 Version 1809 for x64 (KB5126144)` downloads `windows10.0-kb5126043-x64.msu` (3.5 + 4.7.2) and `windows10.0-kb5126048-x64-ndp48.msu` (3.5 + 4.8). No file carries the title KB. All files are kept, each logged under its own KB "part of catalog entry KB5126144".
- **LCU searches also match** the .NET CU and Dynamic Updates from the same Patch Tuesday, so every built-in LCU rule has a title filter anchored at the start, e.g. `^\d{4}-\d{2} Cumulative Update for Windows 10 Version 1809`.
- **The 1809 Safe OS DU** is titled plain `Dynamic Update for Windows 10 Version 1809 for x64-based Systems` (KB5120247, Critical Updates); only its Products field ("Windows 10 and later Dynamic Update, Windows Safe OS Dynamic Update") says Safe OS. Hence `productFilter` / `productExclude`.
- `Save-MSCatalogUpdate` (2.1.0.1) names the saved file after the download URL **with the `_<hash>` part cut off** (`windows10.0-kb5126043-x64_<hash>.msu` is saved as `windows10.0-kb5126043-x64.msu`), and **skips a file that already exists unless `-Force` is passed** (read from its source, 2026-09-24). Files from older downloads can therefore carry the long name; the pruning treats a same-KB long-name file as a duplicate of this run's download.
- **The same Products pattern holds for 21H2 and Server 2022:** Safe OS and Setup DUs share the plain title "Dynamic Update for ..." and differ only in Products. Win11 24H2 names them in the title ("Safe OS Dynamic Update", "Setup Dynamic Update").
- **Combined .NET CU entries everywhere except Win11:** 21H2 and Server 2022 have a "3.5, 4.8 and 4.8.1" entry (a `-ndp48` and a `-ndp481` file) beside separate "3.5 and 4.8" / "3.5 and 4.8.1" entries. Win11 24H2 has one "3.5 and 4.8.1" entry.
- **MSCatalogLTS 2.1.0.1 behaviour:** hides Dynamic Updates without `-IncludeDynamic`; reads one page of 25 rows without `-AllPages`; hides previews unless `-IncludePreview`; rewrites searches that start with an update-type phrase ("Dynamic Update for ...", "Cumulative Update for ...") or that name "Windows 10/11 <version>" without an update type, into its own query. The engine sends every search with a leading space to keep it as written.
- **The catalog returns nothing for a search over 100 characters.** Profiles refuse one when they load.
- **Title wording changes over time:** Win11 24H2 titles changed from "Windows 11 Version 24H2" to "Windows 11, version 24H2" around 2026-05, so the Win11 title filters accept both.
- **Out-of-band LCUs (decision, Terry 2026-09-24): keep picking the newest cumulative release, out-of-band included.** September 2026 had an out-of-band LCU for every OS on 09-14 (1809 KB5129238, 21H2 KB5129236, Win11 KB5129195, Server 2022 KB5129237) after the Patch Tuesday ones on 09-08 (KB5122876, KB5122878, KB5124008, KB5122882). Out-of-band LCUs are cumulative (Win11 26100.9457 builds on Patch Tuesday's 26100.9445). The classification does not tell them apart - the Win11 one is classed "Security Updates" like Patch Tuesday - so the date does: the dry-run dialog and the "selected" log line now show the release date and classification, and for the LCU "Patch Tuesday" (second Tuesday) or "out-of-band".

**Open design points**

- **Checkpoint CUs (Win11 24H2+, Server 2025).** When adding FODs or language packs, every earlier checkpoint MSU plus the target LCU must be in one folder, and only the target LCU is installed; DISM applies the checkpoint(s) from the same folder as needed. **Found in 2A:** the current Win11 24H2 LCU catalog entry (KB5129195) carries its checkpoint (KB5043080) as a second file, so the "keep every file of an entry" download already puts the chain in `PATCHES\LCU`. **Install side (fixed 2026-09-25):** only the target LCU (highest KB) is added; the checkpoint stays beside it for DISM - see step 2A. `checkpointKBs` (a hand-kept KB list, empty everywhere) stays as a fallback for a chain an entry does not carry.
- **WimWizard licence.** WimWizard's source and licence have not been read. The design only follows its general approach (search strings, checkpoint handling). Check the licence before reusing anything more directly.

---

## History

- Recommendation: refactor MediaRefresh_v2 rather than start over or fork WimWizard (`MediaRefresh_Review_and_Roadmap.md`).
- v2.1: null-safe patch/language handling, ISO roles detected by content, language packs checked before any mount, Microsoft servicing order (WinRE once, SSU, LP/FOD/fonts, LCU last, cleanup, NetFx3/.NET CU), stale-mount cleanup, DISM log in LOGS, verification mount, refreshed media folder, Preflight-only mode, per-OS default languages, folder aliases. Console "hang until Enter" fixed; IoT 2021 edition matching fixed; GUI kept responsive with a background runspace and soft cancel.
- v2.2: step 1. First real run (IoT LTSC 2021, 2026-09-21): completed, 0 verify issues, slow (see 2B antivirus note).
- v2.3: step 3.
- v2.4: step 5, then fixed after Terry's real-catalog tests on 2026-09-23 (architecture from titles, multi-file entries, combined 1809 .NET CU, LCU title filters, not-applicable .NET parts skipped, empty-result crash, `productFilter` / `productExclude`).
- 2026-09-26: LTSC 2019 ten-language run recorded (gate PASSED, WinRE off). .NET CU parts that DISM silently finds not applicable are now logged and recorded as skipped (package list compared before/after); a FOD ISO without language features (1809 FOD part 2) is recognised as an extra FOD source instead of "not recognised". Test kit 292 checks.
- 2026-09-26: decision - languages go into install.wim only, never WinRE or boot.wim (the WinRE-with-languages test is dropped; removing the WinRE and boot.wim language steps is an open item). `Languages.json` committed (20 entries: en-gb and zh-tw added, en-us removed); Languages tab to be driven by it (step 10e).
- 2026-09-26: WinRE and boot.wim language steps removed (languages go into install.wim only). Test kit 297 checks.
- 2026-09-25: second real Win11 24H2 run (gate PASSED) confirms the LCU/checkpoint fix on real DISM; change log fixed (per-step times in Section A, Setup DU recorded, WindowsApps housekeeping folders dropped from Section B); unpassed `[string[]]` parameters given an empty default (Windows PowerShell 5.1 throws on `@($x).Count` for an unbound typed array under StrictMode). Test kit 286 checks.
- 2026-09-25: LCU step installs only the target LCU and leaves checkpoint(s) in the folder for DISM (Microsoft's method); open point added on the LCU not applying to WinRE. Test kit 282 checks.
- 2026-09-24: out-of-band LCUs kept as the pick (decision); dialog and log show release date, classification and Patch Tuesday / out-of-band for the LCU. First real v2.4 servicing run recorded (Win11 24H2, 2026-09-23, gate PASSED). Test kit 275 checks.
- 2026-09-24: real GUI downloads: the Win11 run deleted the LCU it had picked (module skips existing files without -Force; pruning kept only re-written files) - fixed with -Force plus a keep-picked-KBs safety net; confirm-dialog KBs no longer doubled. Test kit 268 checks.
- 2026-09-24: step 2A done - every built-in catalog rule checked against the live catalog; Safe OS / Setup DU searches fixed (module hid Dynamic Updates and rewrote the search), 100-character search guard, 21H2 / Server 2022 / Win11 rules corrected, test kit passing on Windows PowerShell 5.1 (255 checks).
- 2026-09-24: this list refocused on validating v2.4; v2_original, v2.1, v2.2, v2.3 and the saved .NET CU conversation moved to `archive\`; the test kit now defaults to `MediaRefresh_v2.4.ps1` and runs on Windows (CRLF fix in `profiles.ps1`).
