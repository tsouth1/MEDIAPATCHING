#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    WimForge v2.4 - GUI offline servicing for Configuration Manager OSD WIMs.
.DESCRIPTION
    Mounts the OS ISO (plus optional Language Pack and FOD ISOs, detected by CONTENT, not file name),
    exports the configured client edition or preserves all Server indexes, services install.wim
    (and optionally WinRE / boot.wim), verifies the result, and can build a refreshed media folder
    (for OS Upgrade Packages) and an optional ISO.

    Servicing order for install.wim follows Microsoft's media Dynamic Update guidance:
      WinRE (once)  ->  SSU  ->  [LCU pass 1 -> language packs -> FODs/fonts when languages are selected]
      ->  LCU (final)  ->  component cleanup  ->  NetFx3 -> .NET CU  ->  export -> verify

.NOTES
    Version 2.4.0 (draft - mock-tested; real catalog dry runs for LTSC 2019 only; never run against real images or a real DISM yet).
      * Added: acquisition layer (step 5) - "Download patches..." searches the Microsoft Update Catalog via the
               MSCatalogLTS module using per-profile catalogSearch rules, shows a dry-run preview of what it found,
               and on confirmation downloads into PATCHES\<class> and prunes superseded files. PATCHES\SSU is never
               touched - legacy servicing-stack updates stay a manual, hand-placed file. Checkpoint-CU chains
               (Win11 24H2+/Server 2025) are looked up from a profile-supplied KB list, not derived automatically -
               open point, see TODO.md step 5. Catalog search strings shipped in the built-in profiles are
               best-effort and need spot-checking against catalog.update.microsoft.com.
      * Fixed (after Terry's real-catalog test, LTSC 2019): catalog results carry no Architecture property and the
               catalog search matches words loosely, so an x86 entry could be picked for an x64 profile. The
               architecture is now checked against the title (and each downloaded file name) instead.
      * Fixed: a catalog entry can download several files (the combined .NET CU "3.5, 4.7.2 and 4.8" for 1809,
               KB5126144, downloads KB5126043 for 3.5/4.7.2 and KB5126048 for 4.8). Every file is now kept,
               instead of only the newest one being kept and the rest pruned.
      * Fixed: a .NET CU file that does not apply to the image (the 4.8 part on an image without .NET 4.8) is
               skipped with a WARN instead of failing the whole servicing run.
      * Fixed: a catalog search with no match stopped the whole download with "The property 'Count' cannot be found"
               (Terry's first real dry run, LTSC 2019, Safe OS DU search); it is now reported as a skipped class.
      * Added: catalogSearch rules take productFilter / productExclude (regular expressions against the catalog
               Products field). The 1809 Safe OS DU is titled plain "Dynamic Update for Windows 10 Version 1809" and is
               only marked as Safe OS by its Products entry; the 1809 SafeOS/SetupDU rules now use that.
      * Changed: the built-in LCU rules have a title filter so a .NET CU or Dynamic Update released the same day can
               no longer be picked as the LCU; the 1809 .NET CU rule searches for the combined entry.
      * Fixed (live catalog check, 2026-09-24): the installed MSCatalogLTS 2.1.0.1 hides Dynamic Updates without
               -IncludeDynamic, reads one page without -AllPages and rewrites "Dynamic Update for ..." searches, so Safe OS
               and Setup DU searches could never find anything. Both switches are now passed and searches reach the
               catalog as written. A search over 100 characters (the catalog returns nothing for it) is refused when the
               profile loads. The 21H2, Server 2022 and Win11 24H2 rules were corrected from the real catalog, and
               Win11 24H2 gained a .NET CU rule.
      * Fixed: the "confirm download" dialog and the "selected" log line listed every KB twice (the catalog title
               already ends in it). Display only - each pick was always downloaded once.
      * Fixed: a real download could delete the patch it had just picked (Terry's Win11 24H2 run removed the LCU): the
               module skips a file that already exists unless -Force is passed, and the pruning kept only files new or
               re-written in the run. -Force is now passed, and pruning never removes a file whose KB was picked in the
               run unless the run also saved a file with that KB.
      * Changed: the "confirm download" dialog and "selected" log line show each pick's release date and catalog
               classification, and for the LCU whether it is the Patch Tuesday or an out-of-band release (the newest
               cumulative release is still the one picked).
      * Fixed: when PATCHES\LCU holds a checkpoint as well as the LCU (Win11 24H2+), only the target LCU (highest KB)
               is installed and the checkpoint stays in the same folder for DISM to apply where needed - Microsoft's
               method. Before, every file was added, so the checkpoint was installed directly into WinRE, install.wim
               and WinPE. A single LCU file is installed as before.
      * Fixed (Terry's 2026-09-25 Win11 change log): Section A rows show the time each step succeeded, not the time
               the log was written; the Setup DU expanded into the media is listed; Windows' housekeeping folders under
               WindowsApps ("Deleted", "Merged") are no longer listed as staged appx packages. [string[]] parameters that
               are counted default to an empty array (Windows PowerShell 5.1 throws on @($x).Count when one is unbound).
      * Fixed (Terry's 2026-09-25 LTSC 2019 run): a .NET CU part that DISM finds not applicable while still returning
               success for the .MSU (the 4.8 part on a 4.7.2 image) was logged and recorded as added; the package list
               is now compared before and after, and an unchanged list is logged as a WARN and recorded as skipped.
      * Fixed: a Features on Demand ISO without language features (1809 "FOD part 2") is recognised as an extra FOD
               source by its metadata\*CompDB* catalogue or package-identity cabs, instead of "not recognised".
      * Changed (Terry, 2026-09-26): languages go into install.wim only. WinRE and boot.wim stay English-only - the
               WinPE language step (lp.cab, WinPE component, font and speech cabs, lang.ini) is removed; WinRE and
               boot.wim are still patched.
      * Changed (Terry, 2026-09-26): the Languages tab lists Profiles\Languages.json (created from the built-in copy
               of Terry's list when missing; a bad file falls back to the built-in list) as "full name - code"; runs,
               saved choices and profile defaults use the code. A profile default not on the list is logged, not selected.
      * Added (Terry, 2026-09-27): "Save settings" and "Reset to defaults" buttons. The selected OS's checkboxes and
               languages are saved to Settings\<profile folder>.json (repository root to Settings\General.json), beside
               Profiles\, and applied whenever that OS is selected; an OS without saved settings gets the defaults.
    Version 2.2.0 (draft - test against non-production images first).
      * Added: OS profiles are JSON files in a Profiles folder beside the script (created from the built-in profiles the first
               time the folder is empty). Edit a file and press "Reload profiles"; a bad file is reported and skipped.
               New OSes need a JSON file, not a code change.
      * Added: package order manifest per profile (packageOrder) instead of plain file-name order, logged at run start.
      * Added: end-of-support date per profile; the run warns when it is past or within 180 days, and the GUI shows it.
      * Added: the previous NEWWIM output is archived to NEWWIM\Archive\<timestamp> before a run writes new output (newest 3 kept,
               keepArchives in the profile) instead of being overwritten.
      * Added: free-disk-space check in preflight and before a real run (estimate from the source WIM size; minFreeGB / spaceCheck
               in the profile).
    Version 2.1.0
      * Fixed: crash when a ticked PATCHES subfolder is empty (now skipped and logged).
      * Fixed: crash when no languages are selected (English-only OSes such as Win11 / Server 2022).
      * Fixed: language pack ISO was mis-detected as an OS ISO (roles are now detected from ISO content).
      * Fixed: language packs silently skipped ("not found on the FOD ISO"); now checked BEFORE any
               image is mounted, and the run stops early with a clear message.
      * Fixed: LCU was applied before FOD/NetFx3 and could show as missing after deployment; the final
               LCU is now applied after all languages/FODs, then cleanup, then NetFx3 + .NET CU
               (this also avoids the 0x800F0806 pending-operations cleanup failure).
      * Fixed: stale mounts are discarded before the mount folders are cleared (no more deleting into a
               live mount); mount-path checks tolerate trailing backslashes.
      * Fixed: WinRE is serviced once and reused for every index (Server 2022).
      * Fixed: ISOs are dismounted before the completion dialog is shown.
      * Added: font capabilities (ja-jp, ko-kr, zh-cn, zh-tw), Server language pack file pattern,
               lang.ini regeneration for boot.wim, DISM log in LOGS, host-vs-image DISM build warning,
               post-build verification (read-only mount), refreshed media folder for Upgrade Packages,
               default language selection per OS profile, folder-name aliases.
      * Fixed: console "hang until Enter is pressed" (Quick Edit mode pauses the script when the console
               window is clicked). Quick Edit is switched off at start-up, cmdlet progress bars are
               suppressed, and the GUI no longer writes every log line to the console.
      * Changed: several Features on Demand ISOs (or an LP ISO that also carries FODs) are all used as
               capability sources instead of stopping the run.
      * Added: "Preflight only" mode - mounts the ISOs and checks ISO roles, patch folders, language packs and
               edition selection in about a minute without touching any image. Run it before a long servicing run.
      * Fixed: the window no longer freezes ("Not Responding") during mounts and patching. The engine now runs on a
               background runspace; the window shows live log lines, progress and elapsed time, and Cancel responds at once
               (it takes effect at the next safe point between DISM operations).
      * Not yet done: MSCatalogLTS downloads, SCCM import, a hard cancel that aborts a running DISM call.
    Run on a supported Windows/ADK servicing workstation as Administrator.
    Keep one OS ISO, and (when languages are needed) one Language Pack ISO and one FOD ISO, in each ISO folder.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region BOOTSTRAP
$ProgressPreference = 'SilentlyContinue'   # cmdlet progress bars slow servicing and write to the console
function Disable-ConsoleQuickEdit {
    # Clicking inside a console window enters Quick Edit selection mode, which blocks the next console write
    # (and so the whole script) until Enter/Esc is pressed. Clear ENABLE_QUICK_EDIT_MODE (0x40), set ENABLE_EXTENDED_FLAGS (0x80).
    try {
        Add-Type -Namespace MediaRefresh -Name ConsoleMode -ErrorAction Stop -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)] public static extern System.IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool GetConsoleMode(System.IntPtr hConsoleHandle, out uint lpMode);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetConsoleMode(System.IntPtr hConsoleHandle, uint dwMode);
'@
        $h = [MediaRefresh.ConsoleMode]::GetStdHandle(-10)
        [uint32]$mode = 0
        if ([MediaRefresh.ConsoleMode]::GetConsoleMode($h, [ref]$mode)) {
            $new = ([int64]$mode -band 4294967231) -bor 128
            [void][MediaRefresh.ConsoleMode]::SetConsoleMode($h, [uint32]$new)
        }
    } catch { }
}
Disable-ConsoleQuickEdit
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
Import-Module Dism -ErrorAction Stop
#endregion BOOTSTRAP

#region ENGINE
$script:MountedIsoPaths = [System.Collections.Generic.List[string]]::new()
$script:LogFile    = $null
$script:LogBox     = $null
$script:Progress   = $null
$script:Status     = $null
$script:Cancelled  = $false
$script:UiQueue    = $null   # set only when the engine runs on a background runspace (GUI stays responsive)
$script:Shared     = $null   # synchronized hashtable shared with the GUI thread (Cancel flag, result)
$script:DismLogArgs = @{}
$script:LastResult = $null
$script:HeaderOs    = $null   # GUI header controls (idle/foreground path); background runs send 'H' queue messages instead
$script:HeaderPhase = $null
$script:CurrentOsName = ''
$script:ChangeEvents  = [System.Collections.Generic.List[object]]::new()   # Section A: what this run changed
$script:IsoSources    = [System.Collections.Generic.List[object]]::new()   # header: OS/Language Pack/FOD ISO file names
$script:VerifyInventory  = [System.Collections.Generic.List[object]]::new()   # Section B: final-state inventory from the verify mount
$script:VerifyBuildAfter = $null
$script:BuildBefore      = $null
$script:ToolVersion      = '2.4.0'

$script:ClientLpPattern = 'Microsoft-Windows-Client-Language-Pack_x64_{0}.cab'
$script:ServerLpPattern = 'Microsoft-Windows-Server-Language-Pack_x64_{0}.cab'
# Language -> font script capability (Language.Fonts.<Script>~~~und-<SCRIPT>~0.0.1.0)
$script:LangFontScripts = @{ 'ja-jp' = 'Jpan'; 'ko-kr' = 'Kore'; 'zh-cn' = 'Hans'; 'zh-tw' = 'Hant' }
$script:DefaultLanguageSet = @('de-de','en-gb','es-es','fr-fr','it-it','ja-jp','ko-kr','pt-br','zh-cn','zh-tw')

# ---------- OS profiles ----------
# Profiles live in JSON files (Profiles folder beside the script). The five built-in profiles below are written out as files the
# first time the folder is empty, and are used as-is when no usable file exists. Client matching is name-first, index-fallback.
#   ssuRequired : the separate SSU must be present in PATCHES\SSU (legacy OSes)
#   altFolders  : other accepted folder names
#   packageOrder: per package class, wildcard file-name patterns applied in that order (rest follow in name order)
#   endOfSupport: yyyy-MM-dd or empty; the run warns when it is past or within 180 days
#   keepArchives: how many archived NEWWIM outputs to keep (0 = keep all);  minFreeGB / spaceCheck: enforce | warn | off
$script:ProfileClasses  = @('SSU', 'LCU', 'NetCU', 'SafeOS', 'SetupDU')
$script:ProfileMessages = [System.Collections.Generic.List[object]]::new()
$script:LanguagesFileName = 'Languages.json'   # Profiles\Languages.json: the Languages tab list (step 10e), not an OS profile
$script:OutputArchived  = $false

function Get-BuiltInProfileData {
    $noOrder = { [ordered]@{ SSU = @(); LCU = @(); NetCU = @(); SafeOS = @(); SetupDU = @() } }
    return @(
        [ordered]@{ schemaVersion = 1; name = 'Windows 10 Enterprise LTSC 2019 (IoT)'; sortOrder = 10; folder = 'Win10_Enterprise_LTSC_2019'; altFolders = @()
            serviceAllIndexes = $false; editionRegex = '(?i)^Windows 10 (IoT )?Enterprise LTSC( 2019)?$'; preferredIndex = 1
            lpPattern = $script:ClientLpPattern; ssuRequired = $true; defaultLanguages = $script:DefaultLanguageSet; packageOrder = (& $noOrder)
            endOfSupport = '2029-01-10'; keepArchives = 3; minFreeGB = 30; spaceCheck = 'enforce'; notes = 'Needs the 1809 Language Pack ISO for languages. SSU KB5005112 goes in PATCHES\SSU. Catalog search rules checked against the real catalog on 2026-09-24.'; catalogSearch = [ordered]@{ LCU = [ordered]@{ search = 'Cumulative Update for Windows 10 Version 1809 for x64-based Systems'; architecture = 'x64'; excludePreview = $true; buildFilter = '^\d{4}-\d{2} Cumulative Update for Windows 10 Version 1809'; checkpointKBs = @() }; NetCU = [ordered]@{ search = 'Cumulative Update for .NET Framework 3.5, 4.7.2 and 4.8 for Windows 10 Version 1809 for x64'; architecture = 'x64'; excludePreview = $true; buildFilter = '^\d{4}-\d{2} Cumulative Update for \.NET Framework 3\.5, 4\.7\.2 and 4\.8 for Windows 10 Version 1809'; checkpointKBs = @() }; SafeOS = [ordered]@{ search = 'Dynamic Update for Windows 10 Version 1809 for x64-based Systems'; architecture = 'x64'; excludePreview = $true; buildFilter = '^\d{4}-\d{2} Dynamic Update for Windows 10 Version 1809'; productFilter = 'Safe OS'; productExclude = ''; checkpointKBs = @() }; SetupDU = [ordered]@{ search = 'Dynamic Update for Windows 10 Version 1809 for x64-based Systems'; architecture = 'x64'; excludePreview = $true; buildFilter = '^\d{4}-\d{2} Dynamic Update for Windows 10 Version 1809'; productFilter = 'Dynamic Update'; productExclude = 'Safe OS'; checkpointKBs = @() } } }
        [ordered]@{ schemaVersion = 1; name = 'Windows 10 IoT Enterprise LTSC 2021'; sortOrder = 20; folder = 'Win10_IoT_Enterprise_LTSC_2021'; altFolders = @('Win10_IOT_Enterprise_LTSC_2021')
            serviceAllIndexes = $false; editionRegex = '(?i)^Windows 10 IoT Enterprise LTSC( 2021)?$'; preferredIndex = 1
            lpPattern = $script:ClientLpPattern; ssuRequired = $true; defaultLanguages = $script:DefaultLanguageSet; packageOrder = (& $noOrder)
            endOfSupport = '2032-01-14'; keepArchives = 3; minFreeGB = 30; spaceCheck = 'enforce'; notes = 'SSU ssu-19041.3562-x64.msu goes in PATCHES\SSU. Catalog search rules checked against the real catalog on 2026-09-24.'; catalogSearch = [ordered]@{ LCU = [ordered]@{ search = 'Cumulative Update for Windows 10 Version 21H2 for x64-based Systems'; architecture = 'x64'; excludePreview = $true; buildFilter = '^\d{4}-\d{2} Cumulative Update for Windows 10 Version 21H2'; checkpointKBs = @() }; NetCU = [ordered]@{ search = 'Cumulative Update for .NET Framework 3.5, 4.8 and 4.8.1 for Windows 10 Version 21H2 for x64'; architecture = 'x64'; excludePreview = $true; buildFilter = '^\d{4}-\d{2} Cumulative Update for \.NET Framework 3\.5, 4\.8 and 4\.8\.1 for Windows 10 Version 21H2'; checkpointKBs = @() }; SafeOS = [ordered]@{ search = 'Dynamic Update for Windows 10 Version 21H2 for x64-based Systems'; architecture = 'x64'; excludePreview = $true; buildFilter = '^\d{4}-\d{2} Dynamic Update for Windows 10 Version 21H2'; productFilter = 'Safe OS'; productExclude = ''; checkpointKBs = @() }; SetupDU = [ordered]@{ search = 'Dynamic Update for Windows 10 Version 21H2 for x64-based Systems'; architecture = 'x64'; excludePreview = $true; buildFilter = '^\d{4}-\d{2} Dynamic Update for Windows 10 Version 21H2'; productFilter = 'Dynamic Update'; productExclude = 'Safe OS'; checkpointKBs = @() } } }
        [ordered]@{ schemaVersion = 1; name = 'Windows 10 Enterprise LTSC 2021 (KMS)'; sortOrder = 30; folder = 'Win10_Enterprise_LTSC_2021_KMS'; altFolders = @()
            serviceAllIndexes = $false; editionRegex = '(?i)^Windows 10 Enterprise LTSC( 2021)?$'; preferredIndex = 1
            lpPattern = $script:ClientLpPattern; ssuRequired = $true; defaultLanguages = $script:DefaultLanguageSet; packageOrder = (& $noOrder)
            endOfSupport = '2027-01-13'; keepArchives = 3; minFreeGB = 30; spaceCheck = 'enforce'; notes = 'SSU ssu-19041.3562-x64.msu goes in PATCHES\SSU. Support ends 2027-01-13; plan the replacement. Catalog search rules checked against the real catalog on 2026-09-24.'; catalogSearch = [ordered]@{ LCU = [ordered]@{ search = 'Cumulative Update for Windows 10 Version 21H2 for x64-based Systems'; architecture = 'x64'; excludePreview = $true; buildFilter = '^\d{4}-\d{2} Cumulative Update for Windows 10 Version 21H2'; checkpointKBs = @() }; NetCU = [ordered]@{ search = 'Cumulative Update for .NET Framework 3.5, 4.8 and 4.8.1 for Windows 10 Version 21H2 for x64'; architecture = 'x64'; excludePreview = $true; buildFilter = '^\d{4}-\d{2} Cumulative Update for \.NET Framework 3\.5, 4\.8 and 4\.8\.1 for Windows 10 Version 21H2'; checkpointKBs = @() }; SafeOS = [ordered]@{ search = 'Dynamic Update for Windows 10 Version 21H2 for x64-based Systems'; architecture = 'x64'; excludePreview = $true; buildFilter = '^\d{4}-\d{2} Dynamic Update for Windows 10 Version 21H2'; productFilter = 'Safe OS'; productExclude = ''; checkpointKBs = @() }; SetupDU = [ordered]@{ search = 'Dynamic Update for Windows 10 Version 21H2 for x64-based Systems'; architecture = 'x64'; excludePreview = $true; buildFilter = '^\d{4}-\d{2} Dynamic Update for Windows 10 Version 21H2'; productFilter = 'Dynamic Update'; productExclude = 'Safe OS'; checkpointKBs = @() } } }
        [ordered]@{ schemaVersion = 1; name = 'Windows 11 Enterprise 24H2'; sortOrder = 40; folder = 'Win11_Enterprise_24H2'; altFolders = @('Win11Enterprise_24H2')
            serviceAllIndexes = $false; editionRegex = '(?i)^Windows 11 Enterprise$'; preferredIndex = 3
            lpPattern = $script:ClientLpPattern; ssuRequired = $false; defaultLanguages = @(); packageOrder = (& $noOrder)
            endOfSupport = ''; keepArchives = 3; minFreeGB = 30; spaceCheck = 'enforce'; notes = 'English only. Support end date not yet checked against the Microsoft lifecycle page. Catalog search rules checked against the real catalog on 2026-09-24.'; catalogSearch = [ordered]@{ LCU = [ordered]@{ search = 'Windows 11, version 24H2'; architecture = 'x64'; excludePreview = $true; buildFilter = '^\d{4}-\d{2} Cumulative Update for Windows 11,? version 24H2'; checkpointKBs = @() }; NetCU = [ordered]@{ search = 'Cumulative Update for .NET Framework 3.5 and 4.8.1 for Windows 11, version 24H2 for x64'; architecture = 'x64'; excludePreview = $true; buildFilter = '^\d{4}-\d{2} Cumulative Update for \.NET Framework 3\.5 and 4\.8\.1 for Windows 11,? version 24H2'; checkpointKBs = @() }; SafeOS = [ordered]@{ search = 'Safe OS Dynamic Update for Windows 11, version 24H2'; architecture = 'x64'; excludePreview = $true; buildFilter = '^\d{4}-\d{2} Safe OS Dynamic Update for Windows 11,? version 24H2'; checkpointKBs = @() }; SetupDU = [ordered]@{ search = 'Setup Dynamic Update for Windows 11, version 24H2'; architecture = 'x64'; excludePreview = $true; buildFilter = '^\d{4}-\d{2} Setup Dynamic Update for Windows 11,? version 24H2'; checkpointKBs = @() } } }
        [ordered]@{ schemaVersion = 1; name = 'Windows Server 2022'; sortOrder = 50; folder = 'Windows_Server_2022'; altFolders = @()
            serviceAllIndexes = $true; editionRegex = ''; preferredIndex = 0
            lpPattern = $script:ServerLpPattern; ssuRequired = $false; defaultLanguages = @(); packageOrder = (& $noOrder)
            endOfSupport = ''; keepArchives = 3; minFreeGB = 60; spaceCheck = 'enforce'; notes = 'Every index is serviced and recombined. English only. Support end date not yet checked. Catalog search rules checked against the real catalog on 2026-09-24.'; catalogSearch = [ordered]@{ LCU = [ordered]@{ search = 'Cumulative Update for Microsoft server operating system version 21H2'; architecture = 'x64'; excludePreview = $true; buildFilter = '^\d{4}-\d{2} Cumulative Update for Microsoft server operating system,? version 21H2'; checkpointKBs = @() }; NetCU = [ordered]@{ search = '.NET Framework 3.5, 4.8 and 4.8.1 for Microsoft server operating system version 21H2'; architecture = 'x64'; excludePreview = $true; buildFilter = '^\d{4}-\d{2} Cumulative Update for \.NET Framework 3\.5, 4\.8 and 4\.8\.1 for Microsoft server operating system,? version 21H2'; checkpointKBs = @() }; SafeOS = [ordered]@{ search = 'Dynamic Update for Microsoft server operating system version 21H2 for x64-based Systems'; architecture = 'x64'; excludePreview = $true; buildFilter = '^\d{4}-\d{2} Dynamic Update for Microsoft server operating system,? version 21H2'; productFilter = 'Safe OS'; productExclude = ''; checkpointKBs = @() }; SetupDU = [ordered]@{ search = 'Dynamic Update for Microsoft server operating system version 21H2 for x64-based Systems'; architecture = 'x64'; excludePreview = $true; buildFilter = '^\d{4}-\d{2} Dynamic Update for Microsoft server operating system,? version 21H2'; productFilter = 'Dynamic Update'; productExclude = 'Safe OS'; checkpointKBs = @() } } }
    )
}
function Get-ProfileValue {
    param($Data, [string]$Key, $Default = $null)
    if ($null -eq $Data) { return $Default }
    if ($Data -is [System.Collections.IDictionary]) { foreach ($k in $Data.Keys) { if ([string]$k -ieq $Key) { return $Data[$k] } }; return $Default }
    $prop = @($Data.PSObject.Properties | Where-Object { $_.Name -ieq $Key }) | Select-Object -First 1
    if ($prop) { return $prop.Value } else { return $Default }
}
function ConvertTo-OsProfile {
    # Validates one profile (from JSON or the built-in data) and returns the object the engine uses. Throws a plain-language message.
    param([Parameter(Mandatory)]$Data, [string]$SourceFile = '(built-in)')
    $name = ([string](Get-ProfileValue $Data 'name' '')).Trim()
    if (-not $name) { throw "'name' is missing." }
    $folder = ([string](Get-ProfileValue $Data 'folder' '')).Trim()
    if (-not $folder) { throw "'folder' is missing." }
    $all = [bool](Get-ProfileValue $Data 'serviceAllIndexes' $false)
    $regex = [string](Get-ProfileValue $Data 'editionRegex' '')
    if (-not $all) {
        if (-not $regex) { throw "'editionRegex' is required unless serviceAllIndexes is true." }
        try { [void][regex]::new($regex) } catch { throw "'editionRegex' is not a valid regular expression: $($_.Exception.Message)" }
    }
    $prefRaw = [string](Get-ProfileValue $Data 'preferredIndex' 0); [int]$pref = 0
    if (-not [int]::TryParse($prefRaw, [ref]$pref) -or $pref -lt 0) { throw "'preferredIndex' must be a whole number, 0 or more." }
    if (-not $all -and $pref -eq 0 -and -not $regex) { throw "Set 'editionRegex' or a 'preferredIndex' of 1 or more." }
    $lp = [string](Get-ProfileValue $Data 'lpPattern' $script:ClientLpPattern)
    if ($lp -notmatch '\{0\}') { throw "'lpPattern' must contain {0} where the language code goes, for example Microsoft-Windows-Client-Language-Pack_x64_{0}.cab." }
    $langs = @(@(Get-ProfileValue $Data 'defaultLanguages' @()) | Where-Object { $_ } | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() })
    foreach ($l in $langs) { if ($l -notmatch '^[a-z]{2,3}-[a-z0-9]{2,8}$') { throw "'defaultLanguages' contains '$l', which is not a language code such as de-de." } }
    $alt = @(@(Get-ProfileValue $Data 'altFolders' @()) | Where-Object { $_ } | ForEach-Object { ([string]$_).Trim() })
    $order = @{}
    foreach ($c in $script:ProfileClasses) { $order[$c] = @() }
    $po = Get-ProfileValue $Data 'packageOrder' $null
    if ($null -ne $po) {
        $keys = if ($po -is [System.Collections.IDictionary]) { @($po.Keys) } else { @($po.PSObject.Properties | ForEach-Object { $_.Name }) }
        foreach ($k in $keys) {
            $canon = $script:ProfileClasses | Where-Object { $_ -ieq [string]$k } | Select-Object -First 1
            if (-not $canon) { throw "'packageOrder' has an unknown class '$k'. Use: $($script:ProfileClasses -join ', ')." }
            $order[$canon] = @(@(Get-ProfileValue $po ([string]$k) @()) | Where-Object { $_ } | ForEach-Object { [string]$_ })
        }
    }
    # catalogSearch (step 5): per package class, Microsoft Update Catalog search rules. SSU is refused here - legacy
    # servicing-stack updates always stay a manual, hand-placed file (PATCHES\SSU), never a downloader target.
    $catalogSearch = @{}
    $cs = Get-ProfileValue $Data 'catalogSearch' $null
    if ($null -ne $cs) {
        $csKeys = if ($cs -is [System.Collections.IDictionary]) { @($cs.Keys) } else { @($cs.PSObject.Properties | ForEach-Object { $_.Name }) }
        foreach ($k in $csKeys) {
            $canon = $script:ProfileClasses | Where-Object { $_ -ieq [string]$k } | Select-Object -First 1
            if (-not $canon) { throw "'catalogSearch' has an unknown class '$k'. Use: $($script:ProfileClasses -join ', ')." }
            if ($canon -eq 'SSU') { throw "'catalogSearch' cannot include SSU - servicing stack updates stay manual (PATCHES\SSU)." }
            $ruleData = Get-ProfileValue $cs ([string]$k) $null
            # 'search' may be a single string or an array of strings. Most classes need only one search term, but a
            # few (notably .NET CU on Windows 10 1809, which ships parallel "3.5 and 4.7.2" / "3.5 and 4.8" updates
            # side by side) need every term searched and every match kept, not just the newest single result.
            $searchRaw = Get-ProfileValue $ruleData 'search' $null
            $searchTerms = [System.Collections.Generic.List[string]]::new()
            if ($searchRaw -is [string]) {
                $t = $searchRaw.Trim(); if ($t) { $searchTerms.Add($t) }
            } elseif ($null -ne $searchRaw) {
                foreach ($item in @($searchRaw)) { $t = ([string]$item).Trim(); if ($t) { $searchTerms.Add($t) } }
            }
            if ($searchTerms.Count -eq 0) { throw "'catalogSearch.$canon.search' is required when the class is listed." }
            # The catalog returns nothing at all for a search over 100 characters (checked 2026-09-24: 106 -> 0 results, 93 -> 41).
            foreach ($st in $searchTerms) { if ($st.Length -gt 100) { throw "'catalogSearch.$canon.search' is $($st.Length) characters; the Microsoft Update Catalog returns nothing for a search over 100 characters. Shorten it and let buildFilter match the exact title." } }
            $chainKbs = @(@(Get-ProfileValue $ruleData 'checkpointKBs' @()) | Where-Object { $_ } | ForEach-Object { ([string]$_).Trim() })
            $catalogSearch[$canon] = [ordered]@{
                search = $searchTerms[0]
                searches = @($searchTerms)
                architecture = [string](Get-ProfileValue $ruleData 'architecture' 'x64')
                excludePreview = [bool](Get-ProfileValue $ruleData 'excludePreview' $true)
                buildFilter = [string](Get-ProfileValue $ruleData 'buildFilter' '')
                productFilter = [string](Get-ProfileValue $ruleData 'productFilter' '')
                productExclude = [string](Get-ProfileValue $ruleData 'productExclude' '')
                checkpointKBs = $chainKbs
            }
            foreach ($rk in @('buildFilter', 'productFilter', 'productExclude')) {
                $rx = $catalogSearch[$canon][$rk]
                if ($rx) { try { [void][regex]::new($rx) } catch { throw "'catalogSearch.$canon.$rk' is not a valid regular expression: $($_.Exception.Message)" } }
            }
        }
    }
    $eos = ([string](Get-ProfileValue $Data 'endOfSupport' '')).Trim()
    if ($eos) {
        $dt = [datetime]::MinValue
        if (-not [datetime]::TryParseExact($eos, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$dt)) { throw "'endOfSupport' must look like 2027-01-13 (or be empty)." }
    }
    [int]$keep = 3; if (-not [int]::TryParse([string](Get-ProfileValue $Data 'keepArchives' 3), [ref]$keep) -or $keep -lt 0) { throw "'keepArchives' must be a whole number, 0 or more." }
    [int]$minFree = 30; if (-not [int]::TryParse([string](Get-ProfileValue $Data 'minFreeGB' 30), [ref]$minFree) -or $minFree -lt 0) { throw "'minFreeGB' must be a whole number, 0 or more." }
    $sc = ([string](Get-ProfileValue $Data 'spaceCheck' 'enforce')).Trim().ToLowerInvariant()
    if (@('enforce', 'warn', 'off') -notcontains $sc) { throw "'spaceCheck' must be enforce, warn or off." }
    [int]$sort = 100; [void][int]::TryParse([string](Get-ProfileValue $Data 'sortOrder' 100), [ref]$sort)
    return [pscustomobject]@{
        Name = $name; SortOrder = $sort; Folder = $folder; AltFolders = $alt; ServiceAllIndexes = $all
        EditionRegex = $regex; PreferredIndex = $pref; LpPattern = $lp; SsuRequired = [bool](Get-ProfileValue $Data 'ssuRequired' $false)
        DefaultLanguages = $langs; PackageOrder = $order; CatalogSearch = $catalogSearch; EndOfSupport = $eos; KeepArchives = $keep; MinFreeGB = $minFree; SpaceCheck = $sc
        Notes = [string](Get-ProfileValue $Data 'notes' ''); SourceFile = $SourceFile
    }
}
function Add-ProfileMessage { param([string]$Level, [string]$Text) $script:ProfileMessages.Add([pscustomobject]@{ Level = $Level; Text = $Text }) }
function Write-ProfileMessages {
    foreach ($m in @($script:ProfileMessages)) { Write-Log $m.Text $m.Level }
    $script:ProfileMessages.Clear()
}
function Save-BuiltInProfiles {
    param([Parameter(Mandatory)][string]$Directory)
    Ensure-Directory $Directory
    foreach ($d in (Get-BuiltInProfileData)) {
        $file = Join-Path $Directory ($d.folder + '.json')
        if (Test-Path -LiteralPath $file) { continue }
        [System.IO.File]::WriteAllText($file, (($d | ConvertTo-Json -Depth 6) + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
    }
}
function Import-OsProfiles {
    # Returns an ordered table name -> profile. Problems are collected in $script:ProfileMessages (flush with Write-ProfileMessages).
    param([string]$Directory)
    $script:ProfileMessages.Clear()
    $table = @{}
    if ($Directory) {
        try {
            # Languages.json (the Languages tab list, step 10e) lives in the same folder but is not an OS profile.
            $profileFiles = { @(Get-ChildItem -LiteralPath $Directory -Filter '*.json' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne $script:LanguagesFileName } | Sort-Object Name) }
            $hasJson = (Test-Path -LiteralPath $Directory) -and (@(& $profileFiles).Count -gt 0)
            if (-not $hasJson) { Save-BuiltInProfiles -Directory $Directory; Add-ProfileMessage 'INFO' "Profile files created from the built-in profiles: $Directory" }
            foreach ($f in @(& $profileFiles)) {
                try {
                    $obj = [System.IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json -ErrorAction Stop
                    $p = ConvertTo-OsProfile -Data $obj -SourceFile $f.Name
                    if ($table.ContainsKey($p.Name)) { Add-ProfileMessage 'WARN' "Profile file $($f.Name) skipped: another file already defines '$($p.Name)'."; continue }
                    $table[$p.Name] = $p
                } catch { Add-ProfileMessage 'WARN' "Profile file $($f.Name) skipped: $($_.Exception.Message)" }
            }
        } catch { Add-ProfileMessage 'WARN' "Profiles folder '$Directory' could not be used: $($_.Exception.Message)" }
    }
    if ($table.Count -eq 0) {
        if ($Directory) { Add-ProfileMessage 'WARN' 'No usable profile file was found; using the built-in profiles.' }
        foreach ($d in (Get-BuiltInProfileData)) { $p = ConvertTo-OsProfile -Data $d; $table[$p.Name] = $p }
    }
    $ordered = [ordered]@{}
    foreach ($p in @($table.Values | Sort-Object SortOrder, Name)) { $ordered[$p.Name] = $p }
    return $ordered
}
$script:OsDefinitions = Import-OsProfiles   # built-ins until a Profiles folder is loaded

# ---------- language list (Languages tab, TODO step 10e) ----------
function Get-BuiltInLanguageData {
    # The languages offered on the Languages tab: Terry's Languages.json (repo root, 2026-09-26). Written to
    # Profiles\Languages.json when that file is missing; the file then wins, so the list is edited there.
    return @(
        @{ language = 'Catalan (Spain)'; code = 'ca-es' }, @{ language = 'Czech (Czech Republic)'; code = 'cs-cz' },
        @{ language = 'German (Germany)'; code = 'de-de' }, @{ language = 'English (United Kingdom)'; code = 'en-gb' },
        @{ language = 'Spanish (Spain)'; code = 'es-es' }, @{ language = 'French (France)'; code = 'fr-fr' },
        @{ language = 'Hungarian (Hungary)'; code = 'hu-hu' }, @{ language = 'Italian (Italy)'; code = 'it-it' },
        @{ language = 'Japanese (Japan)'; code = 'ja-jp' }, @{ language = 'Korean (South Korea)'; code = 'ko-kr' },
        @{ language = 'Polish (Poland)'; code = 'pl-pl' }, @{ language = 'Portuguese (Brazil)'; code = 'pt-br' },
        @{ language = 'Portuguese (Portugal)'; code = 'pt-pt' }, @{ language = 'Romanian (Romania)'; code = 'ro-ro' },
        @{ language = 'Russian (Russia)'; code = 'ru-ru' }, @{ language = 'Slovak (Slovakia)'; code = 'sk-sk' },
        @{ language = 'Swedish (Sweden)'; code = 'sv-se' }, @{ language = 'Turkish (Turkey)'; code = 'tr-tr' },
        @{ language = 'Chinese (Simplified, China)'; code = 'zh-cn' }, @{ language = 'Chinese (Traditional, Taiwan)'; code = 'zh-tw' }
    )
}
function ConvertTo-LanguageList {
    # Validates Languages.json content (an array of { "language": ..., "code": ... }) and returns one object per entry
    # with Name, Code and Display ("German (Germany) - de-de"). Throws a plain-language message.
    param($Data)
    $out = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($e in @($Data | Where-Object { $null -ne $_ })) {
        $name = ([string](Get-ProfileValue $e 'language' '')).Trim()
        $code = ([string](Get-ProfileValue $e 'code' '')).Trim().ToLowerInvariant()
        if (-not $name -or -not $code) { throw "every entry needs a 'language' name and a 'code'." }
        if ($code -notmatch '^[a-z]{2,3}-[a-z0-9]{2,4}$') { throw "'$code' ($name) is not a language code like de-de." }
        if (-not $seen.Add($code)) { throw "'$code' is listed more than once." }
        $out.Add([pscustomobject]@{ Name = $name; Code = $code; Display = "$name - $code" })
    }
    if ($out.Count -eq 0) { throw 'the list is empty.' }
    return @($out)
}
function Save-BuiltInLanguages {
    # Writes the built-in list in the same one-entry-per-line style as the repo's Languages.json.
    param([Parameter(Mandatory)][string]$File)
    Ensure-Directory (Split-Path $File -Parent)
    $rows = @(Get-BuiltInLanguageData | ForEach-Object { '  { "language": ' + (ConvertTo-Json ([string]$_.language)) + ', "code": ' + (ConvertTo-Json ([string]$_.code)) + ' }' })
    $nl = [Environment]::NewLine
    [System.IO.File]::WriteAllText($File, ('[' + $nl + ($rows -join (',' + $nl)) + $nl + ']' + $nl), (New-Object System.Text.UTF8Encoding($false)))
}
function Import-LanguageList {
    # Returns the Languages tab list from <Directory>\Languages.json, creating it from the built-in list when missing.
    # A bad file is reported and the built-in list used instead - never a crash. Problems go to $script:ProfileMessages,
    # so call this after Import-OsProfiles (which clears them) and before Write-ProfileMessages.
    param([string]$Directory)
    if ($Directory) {
        $file = Join-Path $Directory $script:LanguagesFileName
        try {
            if (-not (Test-Path -LiteralPath $file)) { Save-BuiltInLanguages -File $file; Add-ProfileMessage 'INFO' "Language list created from the built-in list: $file" }
            return ConvertTo-LanguageList -Data ([System.IO.File]::ReadAllText($file) | ConvertFrom-Json -ErrorAction Stop)
        } catch { Add-ProfileMessage 'WARN' "Language list $file could not be used ($($_.Exception.Message)); using the built-in list." }
    }
    return ConvertTo-LanguageList -Data (Get-BuiltInLanguageData)
}
# ---------- saved GUI settings per OS (TODO step 10c) ----------
# Settings\<profile folder>.json holds one OS's checkboxes and ticked languages; Settings\General.json the repository
# root. Kept apart from Profiles\ on purpose: profile files get regenerated, which must not wipe saved choices.
$script:SettingOptionNames = @('Preflight', 'Install', 'Boot', 'WinRE', 'Verify', 'BuildMedia', 'BuildIso', 'SSU', 'LCU', 'SafeOS', 'NetCU', 'SetupDU', 'NetFx3')
function Get-OsSettingsFile {
    param([Parameter(Mandatory)][string]$Directory, [Parameter(Mandatory)][pscustomobject]$Definition)
    return (Join-Path $Directory ($Definition.Folder + '.json'))
}
function Save-OsSettings {
    # Writes the selected OS's choices; returns the file path. Only the known option names are stored, as true/false.
    param([Parameter(Mandatory)][string]$Directory, [Parameter(Mandatory)][pscustomobject]$Definition, [hashtable]$Options = @{}, [string[]]$Languages = @())
    Ensure-Directory $Directory
    $opts = [ordered]@{}
    foreach ($k in $script:SettingOptionNames) { if ($Options.ContainsKey($k)) { $opts[$k] = [bool]$Options[$k] } }
    $data = [ordered]@{
        schemaVersion = 1; os = $Definition.Name; saved = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); options = $opts
        languages = @($Languages | Where-Object { $_ } | ForEach-Object { ([string]$_).ToLowerInvariant() })
    }
    $file = Get-OsSettingsFile -Directory $Directory -Definition $Definition
    [System.IO.File]::WriteAllText($file, (($data | ConvertTo-Json -Depth 4) + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
    return $file
}
function Read-OsSettings {
    # The OS's saved choices, or $null when it has none. An unusable file is reported (WARN) and ignored - never a crash.
    # Saved languages that are no longer on the Languages tab list come back in MissingLanguages, not in Languages.
    param([string]$Directory, [Parameter(Mandatory)][pscustomobject]$Definition, [object[]]$LanguageList = @())
    if (-not $Directory) { return $null }
    $file = Get-OsSettingsFile -Directory $Directory -Definition $Definition
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    try {
        $obj = [System.IO.File]::ReadAllText($file) | ConvertFrom-Json -ErrorAction Stop
        $optObj = Get-ProfileValue $obj 'options' $null
        if ($null -eq $optObj) { throw "'options' is missing." }
        $opts = @{}
        foreach ($k in $script:SettingOptionNames) {
            $v = Get-ProfileValue $optObj $k $null
            if ($null -eq $v) { continue }
            if ($v -isnot [bool]) { throw "'options.$k' must be true or false." }
            $opts[$k] = $v
        }
        $codes = @(@(Get-ProfileValue $obj 'languages' @()) | Where-Object { $_ } | ForEach-Object { ([string]$_).ToLowerInvariant() })
        $known = @($LanguageList | ForEach-Object { $_.Code })
        return [pscustomobject]@{ File = $file; Options = $opts; Languages = @($codes | Where-Object { $known -contains $_ }); MissingLanguages = @($codes | Where-Object { $known -notcontains $_ }) }
    } catch {
        Write-Log "Saved settings $file could not be used ($($_.Exception.Message)); using the defaults." 'WARN'
        return $null
    }
}
function Remove-OsSettings {
    # Deletes the OS's saved choices; $true when there was a file.
    param([Parameter(Mandatory)][string]$Directory, [Parameter(Mandatory)][pscustomobject]$Definition)
    $file = Get-OsSettingsFile -Directory $Directory -Definition $Definition
    if (-not (Test-Path -LiteralPath $file)) { return $false }
    Remove-Item -LiteralPath $file -Force -ErrorAction Stop
    return $true
}
function Save-GeneralSettings {
    param([Parameter(Mandatory)][string]$Directory, [string]$Root)
    Ensure-Directory $Directory
    $data = [ordered]@{ schemaVersion = 1; saved = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); root = [string]$Root }
    [System.IO.File]::WriteAllText((Join-Path $Directory 'General.json'), (($data | ConvertTo-Json) + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
}
function Read-GeneralSettings {
    # The saved repository root, or '' when there is none or the file is unusable (WARN).
    param([string]$Directory)
    if (-not $Directory) { return '' }
    $file = Join-Path $Directory 'General.json'
    if (-not (Test-Path -LiteralPath $file)) { return '' }
    try { return ([string](Get-ProfileValue ([System.IO.File]::ReadAllText($file) | ConvertFrom-Json -ErrorAction Stop) 'root' '')).Trim() }
    catch { Write-Log "Saved settings $file could not be used ($($_.Exception.Message))." 'WARN'; return '' }
}
function Get-DefaultLanguageSelection {
    # A profile's defaultLanguages split into the codes that are on the Languages tab list (to pre-select) and the ones
    # that are not (reported, not selected).
    param([pscustomobject]$Definition, [object[]]$LanguageList)
    $codes = @($LanguageList | ForEach-Object { $_.Code })
    $defaults = @($Definition.DefaultLanguages | Where-Object { $_ } | ForEach-Object { ([string]$_).ToLowerInvariant() })
    return [pscustomobject]@{ Select = @($defaults | Where-Object { $codes -contains $_ }); Missing = @($defaults | Where-Object { $codes -notcontains $_ }) }
}

function Get-SupportStatus {
    param([Parameter(Mandatory)]$Definition, [datetime]$Now = (Get-Date))
    if (-not $Definition.EndOfSupport) { return [pscustomobject]@{ Level = 'Unknown'; Days = $null; Text = 'Support end date not set in the profile.' } }
    $d = [datetime]::ParseExact($Definition.EndOfSupport, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
    $days = [int][Math]::Floor(($d.Date - $Now.Date).TotalDays)
    if ($days -lt 0) { return [pscustomobject]@{ Level = 'Past'; Days = $days; Text = "Support ended $($Definition.EndOfSupport) ($([Math]::Abs($days)) days ago)." } }
    $lvl = if ($days -le 180) { 'Soon' } else { 'OK' }
    return [pscustomobject]@{ Level = $lvl; Days = $days; Text = "Support ends $($Definition.EndOfSupport) ($days days)." }
}
function Write-SupportStatus {
    param([Parameter(Mandatory)]$Definition)
    $st = Get-SupportStatus -Definition $Definition
    $lvl = if ($st.Level -in @('Past', 'Soon')) { 'WARN' } else { 'INFO' }
    Write-Log $st.Text $lvl
}

function Get-TS { Get-Date -Format 'HH:mm:ss' }
function Write-Log {
    param([Parameter(Mandatory)][string]$Message, [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-TS), $Level, $Message
    if ($script:LogFile) { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 }
    if ($script:UiQueue) { $script:UiQueue.Enqueue("L`t$line") }   # background run: the GUI thread drains this queue
    elseif ($script:LogBox) {
        $script:LogBox.AppendText($line + [Environment]::NewLine)
        $script:LogBox.ScrollToEnd()
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, 'Background')
    } else { Write-Host $line }   # GUI runs log to the window and file only; console writes can block (Quick Edit)
}
function Set-Progress {
    param([int]$Percent, [string]$Status)
    $pct = [Math]::Max(0, [Math]::Min(100, $Percent))
    if ($script:UiQueue) { $script:UiQueue.Enqueue("P`t$pct`t$Status"); return }
    if ($script:Progress) { $script:Progress.Value = $pct }
    if ($script:Status)   { $script:Status.Text = $Status }
    if ($script:Progress) { [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, 'Background') }
}
function Set-Phase {
    # Updates the title-bar "OS being worked on / current phase" display. $OsName is sticky for the rest of the run; pass it
    # once (Invoke-MediaRefresh does, at the top) and just -Phase after that.
    param([string]$Phase, [string]$OsName = $null)
    if ($OsName) { $script:CurrentOsName = $OsName }
    if ($script:UiQueue) { $script:UiQueue.Enqueue("H`t$($script:CurrentOsName)`t$Phase"); return }
    if ($script:HeaderOs)    { $script:HeaderOs.Text = $script:CurrentOsName }
    if ($script:HeaderPhase) { $script:HeaderPhase.Text = $Phase }
    if ($script:HeaderPhase) { [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, 'Background') }
}
function Assert-NotCancelled {
    if ($script:Cancelled -or ($script:Shared -and $script:Shared['Cancel'])) { throw 'Operation cancelled by user.' }
}
function Ensure-Directory { param([string]$Path) if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null } }
function Join-Chain {
    param([Parameter(Mandatory)][string]$Base, [Parameter(Mandatory)][string[]]$Parts)
    $p = $Base
    foreach ($part in $Parts) { $p = Join-Path $p $part }
    return $p
}
function Get-NormalizedPath {
    param([string]$Path)
    if (-not $Path) { return '' }
    return $Path.TrimEnd('\', '/').ToLowerInvariant()
}

# ---------- mount safety ----------
function Test-IsMounted {
    param([string]$Path)
    $target = Get-NormalizedPath $Path
    foreach ($m in @(Get-WindowsImage -Mounted -ErrorAction SilentlyContinue)) {
        if ((Get-NormalizedPath $m.Path) -eq $target) { return $true }
    }
    return $false
}
function Dismount-IfMounted {
    param([string]$Path)
    if (Test-IsMounted $Path) {
        try { Dismount-WindowsImage -Path $Path -Discard -ErrorAction Stop | Out-Null; Write-Log "Discarded mounted image at $Path" 'WARN' }
        catch { Write-Log "Could not discard mounted image at ${Path}: $($_.Exception.Message)" 'WARN' }
    }
}
function Clear-StaleMounts {
    param([string]$Root)
    $rootN = Get-NormalizedPath $Root
    foreach ($m in @(Get-WindowsImage -Mounted -ErrorAction SilentlyContinue)) {
        if ((Get-NormalizedPath $m.Path).StartsWith($rootN)) {
            Write-Log "Found stale mount $($m.Path) (status $($m.MountStatus)); discarding it." 'WARN'
            try { Dismount-WindowsImage -Path $m.Path -Discard -ErrorAction Stop | Out-Null }
            catch {
                Write-Log "Discard failed ($($_.Exception.Message)); running Clear-WindowsCorruptMountPoint." 'WARN'
                Clear-WindowsCorruptMountPoint | Out-Null
            }
        }
    }
}
function Remove-DirectoryContents {
    param([string]$Path)
    Ensure-Directory $Path
    if (Test-IsMounted $Path) { throw "Refusing to clear $Path because an image is still mounted there." }
    Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction Stop
}

# ---------- DISM helpers ----------
function Invoke-DismExe {
    param([Parameter(Mandatory)][string[]]$Arguments = @(), [Parameter(Mandatory)][string]$Description, [switch]$AllowPending)
    Write-Log $Description
    $all = @($Arguments)
    if ($script:DismLogArgs.ContainsKey('LogPath')) { $all += ('/LogPath:' + $script:DismLogArgs['LogPath']) }
    & dism.exe @all | ForEach-Object { if ($_ -and $_.Trim()) { Write-Log $_ } }
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        if ($AllowPending -and (($code -eq -2146498554) -or ($code -eq 0x800F0806))) {
            Write-Log "Cleanup reported CBS_E_PENDING ($code); continuing." 'WARN'
        } else { throw "$Description failed with exit code $code." }
    }
}
function Test-DismHostVersion {
    param([string]$ImageVersion)
    try {
        $cmd = Get-Command dism.exe -ErrorAction Stop
        $hostVer = [version]$cmd.Version
        $imgVer  = [version]$ImageVersion
        Write-Log "Host DISM $hostVer; image $imgVer"
        if ($imgVer.Build -gt $hostVer.Build) {
            Write-Log "Host DISM build $($hostVer.Build) is older than the image build $($imgVer.Build). Servicing may fail; use the ADK's DISM or a newer host." 'WARN'
        }
    } catch { Write-Log "Could not compare host DISM and image versions: $($_.Exception.Message)" 'WARN' }
}

# ---------- change log helpers ----------
function ConvertTo-SafeFileName { param([string]$Name) return ($Name -replace '[\\/:*?"<>|]', '_').Trim() }
function Get-KbFromName {
    param([string]$Name)
    $m = [regex]::Match([string]$Name, '(?i)KB[0-9]{6,8}')
    if ($m.Success) { return $m.Value.ToUpperInvariant() } else { return '' }
}
function Test-PatchTuesday {
    # $true for the second Tuesday of a month (Microsoft's monthly release day).
    param([datetime]$Date)
    return ($Date.DayOfWeek -eq [DayOfWeek]::Tuesday -and $Date.Day -ge 8 -and $Date.Day -le 14)
}
function Format-CatalogPick {
    # "<title> (<KB>)" for the dry-run dialog and log - but catalog titles already end in "(KBnnnnnnn)", so the KB is only
    # added when the title does not contain it (Terry, 2026-09-24: every KB was listed twice).
    # The release date and classification follow in brackets, so an out-of-band release ("Updates", mid-month) is told
    # apart from the Patch Tuesday one ("Security Updates") before anything is downloaded (Terry, 2026-09-24).
    # -Release (LCU only) names Patch Tuesday vs out-of-band from the date: Microsoft classed the September 2026 Win11
    # out-of-band LCU "Security Updates", so the classification alone does not tell them apart.
    param([string]$Title, [string]$Kb, [datetime]$Date = [datetime]::MinValue, [string]$Classification = '', [switch]$Release)
    $text = if ($Kb -and $Title -notmatch [regex]::Escape($Kb)) { "$Title ($Kb)" } else { $Title }
    $extra = @()
    if ($Date -ne [datetime]::MinValue) { $extra += 'released ' + $Date.ToString('yyyy-MM-dd') }
    if ($Release -and $Date -ne [datetime]::MinValue) { $extra += $(if (Test-PatchTuesday $Date) { 'Patch Tuesday' } else { 'out-of-band' }) }
    if ($Classification) { $extra += $Classification }
    if ($extra.Count -gt 0) { $text += ' [' + ($extra -join ', ') + ']' }
    return $text
}
function Get-EventCategory {
    # Maps an Add-Packages -Label to a Section A category, without touching every call site.
    param([string]$Label)
    switch -Regex ($Label) {
        '^SSU$'              { return 'SSU' }
        '^LCU'                { return 'LCU' }
        '^Safe OS DU$'        { return 'SafeOS' }
        '^Setup DU$'          { return 'SetupDU' }
        '^\.NET CU$'          { return 'NetCU' }
        '^language pack '     { return 'LanguagePack' }
        '^WinPE '              { return 'WinPE' }
        default                { return 'Other' }
    }
}
function Add-ChangeEvent {
    # Section A: one row per change this run actually made, with the time it succeeded.
    param([Parameter(Mandatory)][string]$Category, [Parameter(Mandatory)][string]$Item, [Parameter(Mandatory)][string]$Target, [string]$Kb = '', [string]$Detail = '')
    if (-not $script:ChangeEvents) { $script:ChangeEvents = [System.Collections.Generic.List[object]]::new() }
    $script:ChangeEvents.Add([pscustomobject]@{ Time = (Get-Date); Category = $Category; Item = $Item; Kb = $Kb; Target = $Target; Detail = $Detail })
}

# ---------- acquisition (MSCatalogLTS) - step 5 ----------
# Fills PATCHES\<class> automatically from the Microsoft Update Catalog, per the OS profile's catalogSearch rules.
# PATCHES\SSU is never touched by any function in this section - legacy servicing-stack updates stay a manual,
# hand-placed file, exactly as ConvertTo-OsProfile refuses an SSU catalogSearch rule at the profile-validation level.
function Ensure-CatalogModule {
    # Installs (CurrentUser scope) and imports MSCatalogLTS on first use. Throws a plain-language error - never a bare
    # "command not found" - when the module cannot be obtained (offline machine, blocked PowerShell Gallery, etc.).
    if (Get-Module -Name MSCatalogLTS -ListAvailable -ErrorAction SilentlyContinue) {
        Import-Module MSCatalogLTS -ErrorAction Stop
        return
    }
    Write-Log 'MSCatalogLTS module not found locally; installing from the PowerShell Gallery (CurrentUser scope).'
    try {
        if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -Force -Scope CurrentUser -ErrorAction Stop | Out-Null
        }
        Install-Module -Name MSCatalogLTS -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
        Import-Module MSCatalogLTS -ErrorAction Stop
    } catch {
        throw "Could not install the MSCatalogLTS module (needed to search and download patches automatically): $($_.Exception.Message). Install it manually (Install-Module MSCatalogLTS -Scope CurrentUser) or check network access to the PowerShell Gallery, then try again."
    }
}
function Get-BaseWimBuild {
    # Mounts the OS ISO just long enough to read the base image's build number (Get-WindowsImage .Version), then
    # dismounts. Used to fill {build}/{version} in catalogSearch strings. Returns $null (logs a WARN) rather than
    # throwing when the build cannot be determined - the search still runs, just without that substitution.
    param([Parameter(Mandatory)][string]$IsoFolder, [Parameter(Mandatory)][pscustomobject]$Definition)
    $isoFiles = @(Get-ChildItem -LiteralPath $IsoFolder -Filter '*.iso' -File -ErrorAction SilentlyContinue)
    if ($isoFiles.Count -eq 0) { Write-Log "No ISO in $IsoFolder to read the base build from." 'WARN'; return $null }
    foreach ($f in $isoFiles) {
        try {
            $drive = Mount-IsoFile $f.FullName
            $wimPath = Join-Chain $drive @('sources', 'install.wim')
            if (-not (Test-Path -LiteralPath $wimPath)) { $wimPath = Join-Chain $drive @('sources', 'install.esd') }
            if (-not (Test-Path -LiteralPath $wimPath)) { continue }
            $idx = if ($Definition.ServiceAllIndexes) { 1 } elseif ($Definition.PreferredIndex -gt 0) { $Definition.PreferredIndex } else { 1 }
            $img = Get-WindowsImage -ImagePath $wimPath -Index $idx -ErrorAction Stop
            if ($img.Version) { return [string]$img.Version }
        } catch { Write-Log "Could not read the base build from $($f.Name): $($_.Exception.Message)" 'WARN' }
        finally { Dismount-AllIso }
    }
    return $null
}
function Resolve-CatalogSearch {
    # Substitutes {build} (and the {version} alias) in a catalogSearch.search string with the base image's build
    # number. Left as literal text when no build could be determined - still a usable (just less precise) search.
    param([string]$Search, [string]$Build)
    if (-not $Search) { return $Search }
    if ($Build) { return ($Search -replace '\{build\}', $Build -replace '\{version\}', $Build) }
    return $Search
}
function Get-ArchFromText {
    # Architecture named in a catalog title or a downloaded file name ('x64', 'x86', 'arm64'), or '' when none is.
    # Catalog titles: "... for x64-based Systems", "... for x64", "... for ARM64-based Systems"; file names:
    # "windows10.0-kb5126043-x64.msu". The combined .NET CU's x86 entry names no architecture in its title at all.
    param([string]$Text)
    if ($Text -match '(?i)(?<![a-z0-9])(arm64|aarch64)(?![a-z0-9])') { return 'arm64' }
    if ($Text -match '(?i)(?<![a-z0-9])(x64|amd64)(?![a-z0-9])') { return 'x64' }
    if ($Text -match '(?i)(?<![a-z0-9])(x86|i386)(?![a-z0-9])') { return 'x86' }
    return ''
}
function Test-ArchMatch {
    # $true when $Found (from Get-ArchFromText or a result property) satisfies the rule's architecture. amd64 = x64.
    param([string]$Wanted, [string]$Found)
    $norm = { param($a) switch -Regex ([string]$a) { '(?i)^(x64|amd64)$' { 'x64' } '(?i)^(arm64|aarch64)$' { 'arm64' } '(?i)^(x86|i386)$' { 'x86' } default { ([string]$a).ToLowerInvariant() } } }
    return ((& $norm $Wanted) -eq (& $norm $Found))
}
function Test-CatalogCandidate {
    # Filters one Get-MSCatalogUpdate result against a resolved catalogSearch rule. Reads whatever property names the
    # installed module version actually exposes (via Get-ProfileValue, which is name-tolerant) instead of assuming one.
    # Architecture: real MSCatalogLTS results have no Architecture property (confirmed on Terry's machine), and the
    # catalog search matches words loosely ("for x64" in the search still returns the x86 entry), so when the result
    # has no such property the title must name the wanted architecture - a title naming none is rejected too,
    # because that is exactly how the combined .NET CU's x86 entry looks. Set architecture to '' in the profile to
    # switch the check off for a product whose titles never name one.
    param([Parameter(Mandatory)]$Result, [Parameter(Mandatory)]$Rule)
    $title = [string](Get-ProfileValue $Result 'Title' '')
    $arch = [string](Get-ProfileValue $Result 'Architecture' (Get-ProfileValue $Result 'Arch' ''))
    if (-not $arch) { $arch = Get-ArchFromText $title }
    if ($Rule.architecture -and -not (Test-ArchMatch $Rule.architecture $arch)) { return $false }
    if ($Rule.excludePreview -and $title -match '(?i)preview') { return $false }
    if ($Rule.buildFilter -and $title -notmatch $Rule.buildFilter) { return $false }
    # Products (a string such as "Windows 10, Windows 10 LTSB", or a list): some classes can only be told apart here.
    # The 1809 Safe OS DU is titled plain "Dynamic Update for Windows 10 Version 1809 ..." - its Products entry
    # "Windows Safe OS Dynamic Update" is what marks it (Terry, 2026-09-23). Read by name so a rule object without
    # these keys still works under StrictMode.
    $productFilter = [string](Get-ProfileValue $Rule 'productFilter' '')
    $productExclude = [string](Get-ProfileValue $Rule 'productExclude' '')
    if ($productFilter -or $productExclude) {
        $products = (@(Get-ProfileValue $Result 'Products' '') | ForEach-Object { [string]$_ }) -join ', '
        if ($productFilter -and $products -notmatch $productFilter) { return $false }
        if ($productExclude -and $products -match $productExclude) { return $false }
    }
    return $true
}
function Get-CatalogDate {
    param($Result)
    $raw = Get-ProfileValue $Result 'LastUpdated' (Get-ProfileValue $Result 'Date' $null)
    if (-not $raw) { return [datetime]::MinValue }
    $dt = [datetime]::MinValue
    if ([datetime]::TryParse([string]$raw, [ref]$dt)) { return $dt }
    return [datetime]::MinValue
}
function Invoke-CatalogUpdateSearch {
    # Calls Get-MSCatalogUpdate, passing -ExcludePreview/-Architecture only when the installed module version actually
    # declares them (confirmed real parameters of the MSCatalogLTS/MSCatalog family, per its source on GitHub - but the
    # exact surface can still drift between module versions, so this checks rather than assumes). Test-CatalogCandidate
    # below still re-checks everything in PowerShell as a backstop, and is what applies buildFilter either way.
    # Checked against the installed MSCatalogLTS 2.1.0.1 on Terry's PC (2026-09-24), which differs from the upstream source:
    # - every title containing "Dynamic" is dropped unless -IncludeDynamic is passed (Safe OS / Setup DU found nothing);
    # - only the first page (25 rows) is read unless -AllPages is passed (the 1809 Setup DU is well past page 1);
    # - previews are left out unless -IncludePreview is passed; there is no -ExcludePreview;
    # - a search starting with "Dynamic Update for ..." (or another update-type phrase) is rewritten by the module's
    #   "smart search" into its own "Cumulative Update for <OS>" query, which can never return a Dynamic Update.
    #   A leading space stops that parser matching, so the search reaches the catalog as written (the catalog trims it).
    param([string]$Search, [pscustomobject]$Rule)
    $cmd = Get-Command Get-MSCatalogUpdate -ErrorAction Stop
    $params = @{ Search = ' ' + $Search.Trim() }
    if ($cmd.Parameters.ContainsKey('IncludeDynamic')) { $params['IncludeDynamic'] = $true }
    if ($cmd.Parameters.ContainsKey('AllPages')) { $params['AllPages'] = $true }
    if ($Rule.excludePreview -and $cmd.Parameters.ContainsKey('ExcludePreview')) { $params['ExcludePreview'] = $true }
    if (-not $Rule.excludePreview -and $cmd.Parameters.ContainsKey('IncludePreview')) { $params['IncludePreview'] = $true }
    if ($Rule.architecture -and $cmd.Parameters.ContainsKey('Architecture')) { $params['Architecture'] = $Rule.architecture }
    return @(Get-MSCatalogUpdate @params -ErrorAction Stop)
}
function Search-CatalogCandidates {
    # Runs one catalogSearch rule through Get-MSCatalogUpdate, filters and sorts newest-first. Returns @() (with a
    # logged WARN) when nothing matches after filtering; a search/module failure still throws to the caller.
    param([Parameter(Mandatory)][pscustomobject]$Rule, [string]$Build)
    $search = Resolve-CatalogSearch -Search $Rule.search -Build $Build
    if (-not $search) { return @() }
    Write-Log "Catalog search: $search"
    $raw = @(Invoke-CatalogUpdateSearch -Search $search -Rule $Rule)
    $filtered = @($raw | Where-Object { Test-CatalogCandidate -Result $_ -Rule $Rule })
    if ($filtered.Count -eq 0) { Write-Log "No catalog results matched for '$search' after filtering ($($raw.Count) raw result(s))." 'WARN'; return @() }
    return @($filtered | Sort-Object { Get-CatalogDate $_ } -Descending)
}
function Save-CatalogCandidate {
    # Downloads one catalog result into $Destination via Save-MSCatalogUpdate and returns the full path of EVERY file
    # it produced. One catalog entry can carry several files: the combined .NET CU for 1809 ("3.5, 4.7.2 and 4.8",
    # KB5126144) downloads windows10.0-kb5126043-x64.msu (3.5/4.7.2) and windows10.0-kb5126048-x64-ndp48.msu (4.8),
    # each named after its own component KB, not the entry's KB. The real cmdlet names files from the download URL,
    # so no renaming is needed. -DownloadAll / -AcceptMultiFileUpdates / -Confirm are passed only when the installed
    # module declares them (-DownloadAll confirmed on Terry's machine); without them a multi-file entry would need
    # interactive input, which a background run can never provide. Returns $null when no new or re-written file
    # appeared; the caller then logs a WARN and leaves the folder unpruned rather than guessing which file is current.
    param([Parameter(Mandatory)]$Result, [Parameter(Mandatory)][string]$Destination)
    Ensure-Directory $Destination
    $before = @{}
    foreach ($f in @(Get-ChildItem -LiteralPath $Destination -File -ErrorAction SilentlyContinue)) { $before[$f.Name] = $f.LastWriteTimeUtc }
    $cmd = Get-Command Save-MSCatalogUpdate -ErrorAction Stop
    $params = @{ Update = $Result; Destination = $Destination }
    if ($cmd.Parameters.ContainsKey('DownloadAll')) { $params['DownloadAll'] = $true }
    if ($cmd.Parameters.ContainsKey('AcceptMultiFileUpdates')) { $params['AcceptMultiFileUpdates'] = $true }
    if ($cmd.Parameters.ContainsKey('Confirm')) { $params['Confirm'] = $false }
    # MSCatalogLTS 2.1.0.1 skips a file that already exists unless -Force is passed. A skipped file is neither new nor
    # re-written, so it would not be recognised as this run's download and the pruning below would delete it (Terry's
    # Win11 24H2 run 2026-09-24 deleted the LCU it had just picked). Re-downloading is the price of always knowing.
    if ($cmd.Parameters.ContainsKey('Force')) { $params['Force'] = $true }
    Save-MSCatalogUpdate @params -ErrorAction Stop | Out-Null
    $after = @(Get-ChildItem -LiteralPath $Destination -File -ErrorAction SilentlyContinue)
    # New or re-written (same name, newer timestamp) files are this download's output.
    $new = @($after | Where-Object { -not $before.ContainsKey($_.Name) -or $_.LastWriteTimeUtc -gt $before[$_.Name] } | Sort-Object Name)
    if ($new.Count -gt 0) { return @($new | ForEach-Object { $_.FullName }) }
    return $null
}
function Update-PatchCache {
    # Prunes a PATCHES\<class> folder after a download: keeps $NewestFile and/or every file in $KeepFiles, plus any
    # .cab/.msu whose KB is in $KeepChain (the checkpoint chain), removes everything else superseded. $NewestFile
    # stays as the single-file form (most classes only ever download one file per run); $KeepFiles is for a class
    # with more than one search term - e.g. .NET CU on Windows 10 1809, which needs both its "3.5 and 4.7.2" and
    # "3.5 and 4.8" downloads kept side by side, not pruned down to just the newest of the two. Never called for the
    # SSU folder.
    # Safety net: $KeepKbs are the KBs picked in this run. A file with one of those KBs is never removed unless this run
    # also saved a file with the same KB (then the older copy, e.g. the long "_<hash>" name, is a true duplicate).
    param([Parameter(Mandatory)][string]$Folder, [string]$NewestFile = '', [string[]]$KeepFiles = @(), [string[]]$KeepChain = @(), [string[]]$KeepKbs = @())
    if (-not (Test-Path -LiteralPath $Folder)) { return @() }
    $keepNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($NewestFile) { [void]$keepNames.Add([System.IO.Path]::GetFileName($NewestFile)) }
    foreach ($kf in $KeepFiles) { if ($kf) { [void]$keepNames.Add([System.IO.Path]::GetFileName($kf)) } }
    $savedKbs = @($keepNames | ForEach-Object { Get-KbFromName $_ } | Where-Object { $_ })
    $pickedKbs = @($KeepKbs | Where-Object { $_ } | ForEach-Object { ([string]$_).ToUpperInvariant() })
    $removed = @()
    $exts = @('.cab', '.msu')
    foreach ($f in @(Get-ChildItem -LiteralPath $Folder -File -ErrorAction SilentlyContinue | Where-Object { $exts -contains $_.Extension.ToLowerInvariant() })) {
        if ($keepNames.Contains($f.Name)) { continue }
        $kb = Get-KbFromName $f.Name
        if ($kb -and ($KeepChain -contains $kb)) { continue }
        if ($kb -and ($pickedKbs -contains $kb) -and ($savedKbs -notcontains $kb)) {
            Write-Log "Kept $($f.Name) in $Folder - it is $kb, picked in this run, although this run did not re-write it." 'WARN'
            continue
        }
        try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $removed += $f.Name; Write-Log "Removed superseded file $($f.Name) from $Folder" }
        catch { Write-Log "Could not remove superseded file $($f.Name): $($_.Exception.Message)" 'WARN' }
    }
    return $removed
}
function Invoke-PatchAcquisition {
    # Entry point for the "Download patches..." action. $Options.DryRun=$true only searches and reports what WOULD be
    # downloaded/kept/removed - nothing is written or deleted. See TODO.md step 5 for the open points (checkpoint-CU
    # chain discovery is profile-supplied, not derived automatically; catalog search strings need spot-checking).
    param([Parameter(Mandatory)][pscustomobject]$Options, [Parameter(Mandatory)][pscustomobject]$Definition, [Parameter(Mandatory)][hashtable]$Paths)
    $dryRun = [bool](Get-ProfileValue $Options 'DryRun' $false)
    Set-Phase -OsName $Definition.Name -Phase $(if ($dryRun) { 'Checking for updates (dry run)' } else { 'Acquiring patches' })
    Write-Log "Starting patch acquisition for $($Definition.Name)$(if ($dryRun) { ' (dry run - nothing will be downloaded or removed)' } else { '' })"
    if (-not $Definition.CatalogSearch -or $Definition.CatalogSearch.Count -eq 0) {
        throw "This profile has no 'catalogSearch' rules yet (see $($Definition.SourceFile)). Add search rules for at least one package class, or fill PATCHES manually."
    }
    Set-Progress 2 'Preparing the catalog module'
    Ensure-CatalogModule

    Set-Progress 5 'Reading the base image build'
    $build = Get-BaseWimBuild -IsoFolder $Paths.ISO -Definition $Definition
    if ($build) { Write-Log "Base image build: $build" } else { Write-Log 'Base image build could not be determined; catalog searches with {build} will use the literal placeholder text.' 'WARN' }

    $classes = @('LCU', 'NetCU', 'SafeOS', 'SetupDU')   # SSU is deliberately excluded - always manual
    $wanted = @{ LCU = [bool]$Options.LCU; NetCU = [bool]$Options.NetCU; SafeOS = [bool]$Options.SafeOS; SetupDU = [bool]$Options.SetupDU }
    $folders = [ordered]@{ LCU = 'LCU'; NetCU = 'NETCU'; SafeOS = 'SAFEOSDU'; SetupDU = 'SETUPDU' }
    $plan = [System.Collections.Generic.List[object]]::new()
    $downloaded = [System.Collections.Generic.List[object]]::new()
    $removed = [System.Collections.Generic.List[object]]::new()
    $skippedClasses = [System.Collections.Generic.List[string]]::new()
    $n = 0
    foreach ($class in $classes) {
        $n++
        Set-Progress ([int](10 + ($n / $classes.Count) * 80)) "Checking $class"
        if (-not $wanted[$class]) { continue }
        $rule = Get-ProfileValue $Definition.CatalogSearch $class $null
        if (-not $rule -or -not (Get-ProfileValue $rule 'search' '')) { $skippedClasses.Add("$class (no catalogSearch rule in the profile)"); continue }
        Assert-NotCancelled
        $searchTerms = @(@(Get-ProfileValue $rule 'searches' @()) | Where-Object { $_ })
        if ($searchTerms.Count -eq 0) { $single = [string](Get-ProfileValue $rule 'search' ''); if ($single) { $searchTerms = @($single) } }
        $ruleArch = [string](Get-ProfileValue $rule 'architecture' 'x64')
        $ruleExcludePreview = [bool](Get-ProfileValue $rule 'excludePreview' $true)
        $ruleBuildFilter = [string](Get-ProfileValue $rule 'buildFilter' '')
        $ruleProductFilter = [string](Get-ProfileValue $rule 'productFilter' '')
        $ruleProductExclude = [string](Get-ProfileValue $rule 'productExclude' '')
        $chainKbs = @(@(Get-ProfileValue $rule 'checkpointKBs' @()) | Where-Object { $_ } | ForEach-Object { ([string]$_).ToUpperInvariant() })
        if ($chainKbs.Count -gt 0) {
            Write-Log "$class checkpoint chain from the profile: $($chainKbs -join ', ') - kept alongside the downloaded file(s) when already present, not fetched separately (open point, TODO.md step 5)." 'INFO'
        }
        # Most classes have exactly one search term. A class with several (e.g. NetCU on Windows 10 1809, which needs
        # both its "3.5 and 4.7.2" and "3.5 and 4.8" updates) searches and downloads each term independently, and all
        # of this run's downloads for the class are kept together when pruning - not just the single newest.
        $classFilesKept = [System.Collections.Generic.List[string]]::new()
        $classPickedKbs = [System.Collections.Generic.List[string]]::new()
        foreach ($term in $searchTerms) {
            Assert-NotCancelled
            $ruleObj = [pscustomobject]@{ search = $term; architecture = $ruleArch; excludePreview = $ruleExcludePreview; buildFilter = $ruleBuildFilter; productFilter = $ruleProductFilter; productExclude = $ruleProductExclude }
            # @() is required: a function returning an empty array hands the caller $null, and on Windows PowerShell 5.1 a
            # single result comes back as a bare object - under StrictMode .Count on either throws (seen on Terry's first
            # real dry run, LTSC 2019, when the Safe OS DU search returned nothing).
            try { $candidates = @(Search-CatalogCandidates -Rule $ruleObj -Build $build) }
            catch { Write-Log "Catalog search failed for $class ('$term'): $($_.Exception.Message)" 'ERROR'; $skippedClasses.Add("$class (search failed for '$term': $($_.Exception.Message))"); continue }
            if ($candidates.Count -eq 0) { $skippedClasses.Add("$class (no catalog result matched '$term')"); continue }
            $best = $candidates[0]
            $title = [string](Get-ProfileValue $best 'Title' '(untitled catalog result)')
            $kb = Get-KbFromName $title
            $released = Get-CatalogDate $best; $classification = [string](Get-ProfileValue $best 'Classification' '')
            $plan.Add([pscustomobject]@{ Class = $class; Title = $title; Kb = $kb; Date = $released; Classification = $classification })
            if ($kb) { $classPickedKbs.Add($kb) }
            Write-Log "$class`: selected '$(Format-CatalogPick -Title $title -Kb $kb -Date $released -Classification $classification -Release:($class -eq 'LCU'))'$(if ($searchTerms.Count -gt 1) { " [search: $term]" })"
            if ($dryRun) { continue }

            $folder = Join-Path $Paths.Patches $folders[$class]
            $savedFiles = @(Save-CatalogCandidate -Result $best -Destination $folder | Where-Object { $_ })
            if ($savedFiles.Count -eq 0) { Write-Log "$class`: download reported success but no file could be located in $folder (search '$term')." 'WARN'; continue }
            if ($savedFiles.Count -gt 1) { Write-Log "$class`: catalog entry$(if ($kb) { " $kb" }) downloaded $($savedFiles.Count) files: $(($savedFiles | ForEach-Object { Split-Path $_ -Leaf }) -join ', ')" }
            foreach ($saved in $savedFiles) {
                $leaf = Split-Path $saved -Leaf
                # Backstop for the title check: never keep a file whose name says it is for another architecture.
                $fileArch = Get-ArchFromText $leaf
                if ($ruleArch -and $fileArch -and -not (Test-ArchMatch $ruleArch $fileArch)) {
                    Write-Log "$class`: removing $leaf - its name says $fileArch but the profile asks for $ruleArch." 'WARN'
                    Remove-Item -LiteralPath $saved -Force -ErrorAction SilentlyContinue
                    continue
                }
                $fileKb = Get-KbFromName $leaf
                $detail = if ($kb -and $fileKb -and $fileKb -ne $kb) { "downloaded by acquisition layer (part of catalog entry $kb)" } else { 'downloaded by acquisition layer' }
                Add-ChangeEvent -Category $class -Item $leaf -Target $folder -Kb $(if ($fileKb) { $fileKb } else { $kb }) -Detail $detail
                $downloaded.Add([pscustomobject]@{ Class = $class; File = $saved; Kb = $(if ($fileKb) { $fileKb } else { $kb }); EntryKb = $kb })
                $classFilesKept.Add($saved)
            }
        }
        if (-not $dryRun -and $classFilesKept.Count -gt 0) {
            $folder = Join-Path $Paths.Patches $folders[$class]
            $removedNow = Update-PatchCache -Folder $folder -KeepFiles @($classFilesKept) -KeepChain $chainKbs -KeepKbs @($classPickedKbs)
            foreach ($r in $removedNow) { $removed.Add([pscustomobject]@{ Class = $class; File = $r }) }
        }
    }
    foreach ($s in $skippedClasses) { Write-Log "Skipped $s" 'WARN' }
    Set-Progress 95 'Acquisition done'
    Set-Phase 'Done'
    return [pscustomobject]@{
        Mode = 'Download'; DryRun = $dryRun; OsName = $Definition.Name; Plan = @($plan)
        Downloaded = @($downloaded); Removed = @($removed); SkippedClasses = @($skippedClasses)
        NewWim = ''; Preflight = $false; VerifyIssues = $null; Gate = $null
    }
}

# ---------- packages ----------
function Get-PackageFiles {
    # $Order: optional wildcard file-name patterns from the profile's packageOrder. Matches are applied in pattern order,
    # everything else follows in name order.
    param([string]$Path, [string[]]$Extensions = @('.cab', '.msu'), [string[]]$Order = @())
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $files = @(Get-ChildItem -LiteralPath $Path -File -Recurse | Where-Object { $Extensions -contains $_.Extension.ToLowerInvariant() })
    $pats = @($Order | Where-Object { $_ })
    if ($pats.Count -eq 0) { return @($files | Sort-Object FullName) }
    foreach ($pat in $pats) {
        if (@($files | Where-Object { $_.Name -like $pat }).Count -eq 0) { Write-Log "Order manifest pattern '$pat' matched no file in $Path." 'WARN' }
    }
    return @($files | Sort-Object -Property @{ Expression = { $n = $_.Name; $r = $pats.Count; for ($i = 0; $i -lt $pats.Count; $i++) { if ($n -like $pats[$i]) { $r = $i; break } }; $r } }, FullName)
}
function Get-PackageSet {
    param([string]$PatchRoot, [hashtable]$Enabled, [hashtable]$Order = @{})
    $folders = [ordered]@{ LCU = 'LCU'; SSU = 'SSU'; NetCU = 'NETCU'; SafeOS = 'SAFEOSDU'; SetupDU = 'SETUPDU' }
    $set = @{}
    foreach ($k in $folders.Keys) {
        $ext = if ($k -eq 'SetupDU') { @('.cab') } else { @('.cab', '.msu') }
        $set[$k] = @( if ($Enabled[$k]) { Get-PackageFiles -Path (Join-Path $PatchRoot $folders[$k]) -Extensions $ext -Order @($Order[$k]) } )
    }
    $lcu = Resolve-LcuTarget -Files $set.LCU
    $set.LCU = $lcu.Install; $set.LcuCheckpoints = $lcu.Checkpoints
    return $set
}
function Resolve-LcuTarget {
    # Checkpoint cumulative updates (Win11 24H2+, Server 2025): Microsoft's method for offline media is to put the target
    # LCU and every earlier checkpoint .msu in one folder and add ONLY the target; DISM finds and installs the checkpoints
    # the image still needs (learn.microsoft.com "Checkpoint cumulative updates and the Microsoft Update Catalog").
    # Adding a checkpoint directly is never needed and may fail on an image already past it. So when PATCHES\LCU holds
    # more than one .msu, the one with the highest KB number is the target and the rest stay in the folder, uninstalled.
    # One file (every Win10 / Server 2022 profile) or no KB numbers to go by: unchanged, everything is installed.
    param([object[]]$Files)
    $all = @($Files | Where-Object { $_ })
    $msu = @($all | Where-Object { $_.Extension -ieq '.msu' -and (Get-KbFromName $_.Name) })
    if ($all.Count -le 1 -or $msu.Count -eq 0) { return @{ Install = $all; Checkpoints = @() } }
    $target = $msu | Sort-Object { [int64]((Get-KbFromName $_.Name) -replace '\D', '') } -Descending | Select-Object -First 1
    return @{ Install = @($target); Checkpoints = @($all | Where-Object { $_.FullName -ne $target.FullName }) }
}
function Test-PackageSet {
    param([pscustomobject]$Definition, [hashtable]$Packages, [hashtable]$Enabled, [bool]$DoWinRe, [bool]$BuildMedia)
    foreach ($k in @('SSU', 'LCU', 'NetCU', 'SafeOS', 'SetupDU')) {
        $state = if ($Enabled[$k]) { 'selected' } else { 'not selected' }
        Write-Log "$k packages: $(@($Packages[$k]).Count) ($state)"
        if (@($Packages[$k]).Count -gt 1) { Write-Log "$k order: $((@($Packages[$k]) | ForEach-Object { $_.Name }) -join ' -> ')" }
    }
    if ($Enabled.LCU -and @($Packages.LCU).Count -eq 0) { throw 'Latest Cumulative Update is selected but PATCHES\LCU is empty. Add the LCU or untick it.' }
    $cps = @($Packages['LcuCheckpoints'] | Where-Object { $_ })
    if ($Enabled.LCU -and $cps.Count -gt 0) {
        $target = @($Packages.LCU)[0]
        Write-Log "LCU: only $($target.Name) is installed; $(($cps | ForEach-Object { $_.Name }) -join ', ') stay in the folder for DISM to apply as checkpoint(s) where the image needs them. PATCHES\LCU must hold only this LCU and its checkpoints."
        foreach ($cp in $cps) {
            if ($cp.DirectoryName -ne $target.DirectoryName) { Write-Log "LCU checkpoint $($cp.Name) is not in the same folder as $($target.Name); DISM only looks beside the target. Move it next to the target." 'WARN' }
        }
    }
    if ($Enabled.SSU -and $Definition.SsuRequired -and @($Packages.SSU).Count -eq 0) { throw 'This OS needs its servicing stack update in PATCHES\SSU. Add it or untick Servicing Stack Update.' }
    if ($DoWinRe -and $Enabled.SafeOS -and @($Packages.SafeOS).Count -eq 0) { Write-Log 'WinRE servicing is on but PATCHES\SAFEOSDU is empty; WinRE will not get the Safe OS update.' 'WARN' }
    if ($BuildMedia -and $Enabled.SetupDU -and @($Packages.SetupDU).Count -eq 0) { Write-Log 'Refreshed media is requested but PATCHES\SETUPDU is empty; Setup files will not be updated.' 'WARN' }
}
function Get-PackageFingerprint {
    # One string for the mounted image's packages and their states, to tell whether an Add-WindowsPackage changed anything.
    param([string]$MountPath)
    return ((@(Get-WindowsPackage -Path $MountPath -ErrorAction Stop) | ForEach-Object { "$($_.PackageName)|$($_.PackageState)" } | Sort-Object) -join "`n")
}
function Add-Packages {
    param(
        [Parameter(Mandatory)][string]$MountPath,
        [AllowNull()][object[]]$Packages,
        [Parameter(Mandatory)][string]$Target,
        [string]$Label = 'package',
        [switch]$IgnoreCombinedLcu7007e,
        [switch]$SkipNotApplicable
    )
    $dl = $script:DismLogArgs
    $list = @($Packages | Where-Object { $_ })
    if ($list.Count -eq 0) { Write-Log "No $Label packages to add to $Target (skipped)."; return }
    foreach ($pkg in $list) {
        Assert-NotCancelled
        Write-Log "Adding $Label $($pkg.FullName) to $Target"
        try {
            # For a .MSU, DISM can decide "not applicable" (0x800f081e) internally and still return success - Terry's
            # LTSC 2019 run (2026-09-25) logged the .NET 4.8 part as added although DISM skipped it. So where skipping is
            # allowed, the image's package list is compared before and after: no change means nothing was installed.
            $before = if ($SkipNotApplicable) { Get-PackageFingerprint $MountPath } else { $null }
            Add-WindowsPackage -Path $MountPath -PackagePath $pkg.FullName @dl -ErrorAction Stop | Out-Null
            $pkgName = Split-Path $pkg.FullName -Leaf
            if ($null -ne $before -and (Get-PackageFingerprint $MountPath) -eq $before) {
                Write-Log "Skipped $Label ${pkgName}: DISM found it not applicable to $Target and installed nothing (the image's package list is unchanged)." 'WARN'
                Add-ChangeEvent -Category (Get-EventCategory $Label) -Item $pkgName -Target $Target -Kb (Get-KbFromName $pkgName) -Detail "$Label - skipped, not applicable to this image"
                continue
            }
            Add-ChangeEvent -Category (Get-EventCategory $Label) -Item $pkgName -Target $Target -Kb (Get-KbFromName $pkgName) -Detail $Label
        }
        catch {
            if ($IgnoreCombinedLcu7007e -and $_.Exception.Message -match '0x8007007e') {
                Write-Log 'Known combined-LCU error 0x8007007e encountered; continuing.' 'WARN'
            } elseif ($SkipNotApplicable -and $_.Exception.Message -match '(?i)0x800f081e|not applicable') {
                # CBS_E_NOT_APPLICABLE: e.g. the .NET 4.8 part of a combined .NET CU on an image that only has 4.7.2.
                Write-Log "Skipped $Label $(Split-Path $pkg.FullName -Leaf): not applicable to $Target (0x800f081e)." 'WARN'
                Add-ChangeEvent -Category (Get-EventCategory $Label) -Item (Split-Path $pkg.FullName -Leaf) -Target $Target -Kb (Get-KbFromName $pkg.FullName) -Detail "$Label - skipped, not applicable to this image"
            } else { throw }
        }
    }
}

# ---------- ISO handling ----------
function Mount-IsoFile {
    param([string]$ImagePath)
    Write-Log "Mounting ISO $ImagePath"
    $disk = Mount-DiskImage -ImagePath $ImagePath -PassThru -ErrorAction Stop
    $script:MountedIsoPaths.Add($ImagePath)
    $volume = $disk | Get-Volume | Where-Object DriveLetter | Select-Object -First 1
    if (-not $volume) { throw "Mounted ISO has no drive letter: $ImagePath" }
    return ($volume.DriveLetter + ':\')
}
function Dismount-AllIso {
    foreach ($path in @($script:MountedIsoPaths)) {
        try { Dismount-DiskImage -ImagePath $path -ErrorAction Stop | Out-Null; Write-Log "Dismounted ISO $path" }
        catch { Write-Log "Could not dismount ISO ${path}: $($_.Exception.Message)" 'WARN' }
    }
    $script:MountedIsoPaths.Clear()
}
function Get-IsoRoleMap {
    # $Mounted: objects with .Path (ISO file) and .Drive (mounted root). Roles come from CONTENT, not file names.
    param([object[]]$Mounted)
    $os = @(); $lp = @(); $fod = @(); $unknown = @()
    foreach ($m in @($Mounted)) {
        $root = $m.Drive
        $isOs = (Test-Path -LiteralPath (Join-Chain $root @('sources', 'install.wim'))) -or (Test-Path -LiteralPath (Join-Chain $root @('sources', 'install.esd')))
        $isLp = $false; $isFod = $false
        if (-not $isOs) {
            $isLp = [bool](Get-ChildItem -LiteralPath $root -Filter 'Microsoft-Windows-*-Language-Pack_x64_*.cab' -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1)
            # A FOD ISO without language features (1809 "FOD part 2") still carries DISM's FOD catalogue (metadata\*CompDB*)
            # and package-identity cabs (..~31bf3856ad364e35~..); it is then an extra capability source, not "unrecognised".
            $isFod = (Test-Path -LiteralPath (Join-Path $root 'LanguagesAndOptionalFeatures')) -or
                     [bool](Get-ChildItem -LiteralPath $root -Filter 'Microsoft-Windows-LanguageFeatures-*.cab' -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1) -or
                     [bool](Get-ChildItem -LiteralPath (Join-Path $root 'metadata') -Filter '*CompDB*' -File -ErrorAction SilentlyContinue | Select-Object -First 1) -or
                     [bool](Get-ChildItem -LiteralPath $root -Filter '*~31bf3856ad364e35~*.cab' -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1)
        }
        if ($isOs)  { $os  += $m }
        if ($isLp)  { $lp  += $m }
        if ($isFod) { $fod += $m }
        if (-not ($isOs -or $isLp -or $isFod)) { $unknown += $m }
    }
    if ($os.Count -ne 1) { throw "Expected exactly one OS ISO (one containing sources\install.wim or install.esd); found $($os.Count)." }
    if ($lp.Count -gt 1) {
        # An ISO that carries language packs AND FODs is only chosen as the LP source when no LP-only ISO exists.
        $lpOnly = @($lp | Where-Object { $fod -notcontains $_ })
        if ($lpOnly.Count -eq 1) { $lp = @($lpOnly[0]) }
        else { throw "More than one Language Pack ISO found: $((@($lp | ForEach-Object { Split-Path $_.Path -Leaf })) -join ', '). Keep only one." }
    }
    $fodDrives = @($fod | ForEach-Object { $_.Drive })
    return [pscustomobject]@{
        OsDrive      = $os[0].Drive
        LpDrive      = $(if ($lp.Count) { $lp[0].Drive } else { $null })
        FodDrives    = $fodDrives
        FodDrive     = $(if ($fodDrives.Count) { $fodDrives[0] } else { $null })
        Unclassified = @($unknown | ForEach-Object { $_.Path })
    }
}
function Get-FodSource {
    # Returns one capability source folder per FOD-bearing ISO (DISM searches all of them).
    param([string[]]$FodDrives)
    $out = @()
    foreach ($d in @($FodDrives | Where-Object { $_ })) {
        $candidate = Join-Path $d 'LanguagesAndOptionalFeatures'
        if (Test-Path -LiteralPath $candidate) { $out += $candidate } else { $out += $d }
    }
    return $out
}
function Resolve-LanguagePacks {
    # Finds every requested language pack cab BEFORE any image is mounted. Throws if any are missing.
    param([string]$LpRoot, [string]$Pattern, [string[]]$Languages = @())
    $byName = @{}
    foreach ($f in @(Get-ChildItem -LiteralPath $LpRoot -Filter '*Language-Pack_x64_*.cab' -File -Recurse -ErrorAction SilentlyContinue)) {
        $byName[$f.Name.ToLowerInvariant()] = $f.FullName
    }
    $found = @{}; $missing = @()
    foreach ($lang in @($Languages)) {
        $key = ($Pattern -f $lang).ToLowerInvariant()
        if ($byName.ContainsKey($key)) { $found[$lang] = $byName[$key] } else { $missing += $lang }
    }
    if ($missing.Count -gt 0) { throw "Language pack cab not found for: $($missing -join ', ') (looked for $($Pattern -f '<lang>') in $LpRoot). Check that the correct Language Pack ISO is in the ISO folder." }
    return $found
}

# ---------- languages ----------
function Add-OfflineLanguages {
    param([string]$MountPath, [hashtable]$LpFiles, [string[]]$FodSource = @(), [string[]]$Languages = @(), [string]$Target)
    $dl = $script:DismLogArgs
    if (@($Languages).Count -eq 0) { return }
    $fontsDone = @{}
    foreach ($lang in @($Languages)) {
        Assert-NotCancelled
        Add-Packages $MountPath @([pscustomobject]@{ FullName = $LpFiles[$lang] }) $Target -Label "language pack $lang"
        if (@($FodSource).Count -eq 0) { continue }
        $caps = @("Language.Basic~~~$lang~0.0.1.0", "Language.OCR~~~$lang~0.0.1.0", "Language.Handwriting~~~$lang~0.0.1.0",
                  "Language.TextToSpeech~~~$lang~0.0.1.0", "Language.Speech~~~$lang~0.0.1.0")
        if ($script:LangFontScripts.ContainsKey($lang)) {
            $fs = $script:LangFontScripts[$lang]
            if (-not $fontsDone.ContainsKey($fs)) { $caps = @("Language.Fonts.$fs~~~und-$($fs.ToUpperInvariant())~0.0.1.0") + $caps; $fontsDone[$fs] = $true }
        }
        foreach ($cap in $caps) {
            try {
                Write-Log "Adding capability $cap to $Target"
                Add-WindowsCapability -Name $cap -Path $MountPath -Source $FodSource -LimitAccess @dl -ErrorAction Stop | Out-Null
                $capCategory = if ($cap -like 'Language.Fonts.*') { 'Font' } else { 'Capability' }
                Add-ChangeEvent -Category $capCategory -Item $cap -Target $Target
            } catch { Write-Log "Capability $cap was unavailable or not applicable: $($_.Exception.Message)" 'WARN' }
        }
    }
}

# ---------- servicing ----------
function Service-WinRe {
    # Extracts winre.wim from the currently mounted OS image, services it, and exports the result to $OutputPath.
    # No languages: they go into install.wim only; WinRE and boot.wim stay English-only (Terry, 2026-09-26).
    param([string]$OsMount, [string]$WinReMount, [string]$Temp, [string]$OutputPath, [hashtable]$Packages)
    Assert-NotCancelled
    $dl = $script:DismLogArgs
    $embedded = Join-Chain $OsMount @('Windows', 'System32', 'Recovery', 'winre.wim')
    if (-not (Test-Path -LiteralPath $embedded)) { Write-Log "No WinRE image found at $embedded" 'WARN'; return $false }
    Remove-DirectoryContents $WinReMount
    $working = Join-Path $Temp 'winre.wim'
    $optimized = Join-Path $Temp 'winre.optimized.wim'
    Remove-Item -LiteralPath $working, $optimized -Force -ErrorAction SilentlyContinue
    Copy-Item -LiteralPath $embedded -Destination $working -Force
    Write-Log 'Servicing WinRE (done once and reused for every index).'
    try {
        Mount-WindowsImage -ImagePath $working -Index 1 -Path $WinReMount -CheckIntegrity @dl -ErrorAction Stop | Out-Null
        Add-Packages $WinReMount $Packages.SSU 'WinRE' -Label 'SSU' -IgnoreCombinedLcu7007e
        Add-Packages $WinReMount $Packages.LCU 'WinRE' -Label 'LCU' -IgnoreCombinedLcu7007e
        Add-Packages $WinReMount $Packages.SafeOS 'WinRE' -Label 'Safe OS DU'
        Invoke-DismExe -Arguments @("/Image:$WinReMount", '/Cleanup-Image', '/StartComponentCleanup', '/ResetBase', '/Defer') -Description 'Cleaning WinRE'
        Dismount-WindowsImage -Path $WinReMount -Save -CheckIntegrity @dl -ErrorAction Stop | Out-Null
        Remove-Item -LiteralPath $OutputPath -Force -ErrorAction SilentlyContinue
        Export-WindowsImage -SourceImagePath $working -SourceIndex 1 -DestinationImagePath $OutputPath -CompressionType Max -CheckIntegrity @dl -ErrorAction Stop | Out-Null
        Add-ChangeEvent -Category 'WinRE' -Item 'WinRE image serviced (once, reused for every index)' -Target 'WinRE'
        return $true
    } catch {
        Dismount-IfMounted $WinReMount
        throw
    }
}
function Service-InstallIndex {
    param([string]$ImagePath, [int]$Index, [hashtable]$Paths, [hashtable]$Packages, [string]$OsDrive,
          [hashtable]$LpFiles, [string[]]$FodSource = @(), [string[]]$Languages = @(), [bool]$DoWinRe, [bool]$DoNetFx3)
    Assert-NotCancelled
    $dl = $script:DismLogArgs
    $target = "install.wim index $Index"
    $hasLang = (@($Languages).Count -gt 0)
    Remove-DirectoryContents $Paths.MainMount
    Write-Log "Mounting $target"
    try {
        Mount-WindowsImage -ImagePath $ImagePath -Index $Index -Path $Paths.MainMount -CheckIntegrity @dl -ErrorAction Stop | Out-Null

        # 1. WinRE: serviced once (from the first index processed), then reused for every index.
        if ($DoWinRe) {
            $cache = Join-Path $Paths.WinRE 'winre.serviced.wim'
            if (-not (Test-Path -LiteralPath $cache)) {
                [void](Service-WinRe -OsMount $Paths.MainMount -WinReMount $Paths.WinReMount -Temp $Paths.Temp -OutputPath $cache -Packages $Packages)
            }
            if (Test-Path -LiteralPath $cache) {
                Write-Log "Applying serviced WinRE to $target"
                Copy-Item -LiteralPath $cache -Destination (Join-Chain $Paths.MainMount @('Windows', 'System32', 'Recovery', 'winre.wim')) -Force
            }
        } else { Write-Log 'WinRE servicing is OFF (box unticked); WinRE is left as shipped.' 'WARN' }

        # 2. Servicing stack, then (only when adding languages) LCU pass 1 so the newest stack is in place.
        Add-Packages $Paths.MainMount $Packages.SSU $target -Label 'SSU'
        if ($hasLang) {
            Add-Packages $Paths.MainMount $Packages.LCU $target -Label 'LCU (pass 1)'
            # 3. Language packs, then FODs and fonts.
            Add-OfflineLanguages -MountPath $Paths.MainMount -LpFiles $LpFiles -FodSource $FodSource -Languages $Languages -Target $target
        }
        # 4. Final LCU, applied after all languages/FODs so they are brought to the current level.
        Add-Packages $Paths.MainMount $Packages.LCU $target -Label 'LCU (final)'

        # 5. Cleanup BEFORE NetFx3 (NetFx3 creates pending operations that make cleanup fail with 0x800F0806).
        Invoke-DismExe -Arguments @("/Image:$($Paths.MainMount)", '/Cleanup-Image', '/StartComponentCleanup') -Description "Component cleanup on $target" -AllowPending
        Add-ChangeEvent -Category 'Cleanup' -Item 'Component cleanup' -Target $target

        # 6. .NET Framework 3.5, then the .NET cumulative update(s).
        if ($DoNetFx3) {
            $sxs = Join-Chain $OsDrive @('sources', 'sxs')
            Write-Log "Enabling NetFX3 from $sxs on $target"
            Enable-WindowsOptionalFeature -Path $Paths.MainMount -FeatureName NetFx3 -All -Source $sxs -LimitAccess @dl -ErrorAction Stop | Out-Null
            Add-ChangeEvent -Category 'NetFx3' -Item 'NetFx3 enabled' -Target $target
        }
        Add-Packages $Paths.MainMount $Packages.NetCU $target -Label '.NET CU' -SkipNotApplicable

        Dismount-WindowsImage -Path $Paths.MainMount -Save -CheckIntegrity @dl -ErrorAction Stop | Out-Null
    } catch {
        Dismount-IfMounted $Paths.MainMount
        throw
    }
}
function Export-OptimizedWim {
    param([string]$Source, [string]$Destination)
    Assert-NotCancelled
    $dl = $script:DismLogArgs
    Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
    foreach ($image in @(Get-WindowsImage -ImagePath $Source)) {
        Write-Log "Final optimized export: index $($image.ImageIndex), $($image.ImageName)"
        Export-WindowsImage -SourceImagePath $Source -SourceIndex $image.ImageIndex -DestinationImagePath $Destination -DestinationName $image.ImageName -CompressionType Max -CheckIntegrity @dl -ErrorAction Stop | Out-Null
    }
}
function Service-BootWim {
    # No languages: boot.wim (WinPE / Setup) stays English-only (Terry, 2026-09-26).
    param([string]$SourceBoot, [string]$Destination, [hashtable]$Paths, [hashtable]$Packages)
    $dl = $script:DismLogArgs
    $working = Join-Path $Paths.Working 'boot.working.wim'
    $optimized = Join-Path $Paths.Temp 'boot.optimized.wim'
    Copy-Item -LiteralPath $SourceBoot -Destination $working -Force
    Set-ItemProperty -LiteralPath $working -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
    foreach ($image in @(Get-WindowsImage -ImagePath $working)) {
        $target = "boot.wim index $($image.ImageIndex)"
        Remove-DirectoryContents $Paths.WinPeMount
        Write-Log "Mounting $target"
        try {
            Mount-WindowsImage -ImagePath $working -Index $image.ImageIndex -Path $Paths.WinPeMount -CheckIntegrity @dl -ErrorAction Stop | Out-Null
            Add-Packages $Paths.WinPeMount $Packages.SSU $target -Label 'SSU' -IgnoreCombinedLcu7007e
            Add-Packages $Paths.WinPeMount $Packages.LCU $target -Label 'LCU' -IgnoreCombinedLcu7007e
            Invoke-DismExe -Arguments @("/Image:$($Paths.WinPeMount)", '/Cleanup-Image', '/StartComponentCleanup', '/ResetBase', '/Defer') -Description "Cleaning $target"
            Dismount-WindowsImage -Path $Paths.WinPeMount -Save -CheckIntegrity @dl -ErrorAction Stop | Out-Null
        } catch {
            Dismount-IfMounted $Paths.WinPeMount
            throw
        }
    }
    Remove-Item -LiteralPath $optimized -Force -ErrorAction SilentlyContinue
    foreach ($image in @(Get-WindowsImage -ImagePath $working)) {
        Export-WindowsImage -SourceImagePath $working -SourceIndex $image.ImageIndex -DestinationImagePath $optimized -DestinationName $image.ImageName -CompressionType Max -CheckIntegrity @dl -ErrorAction Stop | Out-Null
    }
    Copy-Item -LiteralPath $optimized -Destination $Destination -Force
}

# ---------- verification ----------
function Test-OutputWim {
    # Read-only mounts each index of the final WIM, logs what is really in it, returns the number of issues, and (as a side
    # effect, in $script:VerifyInventory / $script:VerifyBuildAfter) collects the change log's Section B: the image's final state.
    param([string]$WimPath, [hashtable]$Paths, [string[]]$Languages = @(), [bool]$ExpectLcu)
    $dl = $script:DismLogArgs
    $issues = 0
    $script:VerifyInventory = [System.Collections.Generic.List[object]]::new()
    $script:VerifyBuildAfter = $null
    foreach ($img in @(Get-WindowsImage -ImagePath $WimPath)) {
        Assert-NotCancelled
        $detail = Get-WindowsImage -ImagePath $WimPath -Index $img.ImageIndex
        Write-Log ("VERIFY index {0} '{1}': image version {2}" -f $img.ImageIndex, $img.ImageName, $detail.Version)
        if (-not $script:VerifyBuildAfter) { $script:VerifyBuildAfter = [string]$detail.Version }
        Remove-DirectoryContents $Paths.MainMount
        try {
            Mount-WindowsImage -ImagePath $WimPath -Index $img.ImageIndex -Path $Paths.MainMount -ReadOnly @dl -ErrorAction Stop | Out-Null
            $pk = @(Get-WindowsPackage -Path $Paths.MainMount @dl)
            $roll = @($pk | Where-Object { $_.PackageName -like 'Package_for_RollupFix*' -and $_.PackageState -eq 'Installed' })
            if ($roll.Count -gt 0) { Write-Log ('VERIFY   RollupFix installed: ' + ((@($roll | ForEach-Object { $_.PackageName })) -join '; ')) }
            elseif ($ExpectLcu) { Write-Log 'VERIFY   NO RollupFix (cumulative update) package is installed in this image.' 'WARN'; $issues++ }
            $pending = @($pk | Where-Object { $_.PackageState -match 'Pending' })
            if ($pending.Count -gt 0) { Write-Log ("VERIFY   {0} package(s) are in a pending state (normal for offline-serviced images; first boot completes them)." -f $pending.Count) }
            foreach ($lang in @($Languages)) {
                $lp = @($pk | Where-Object { $_.PackageName -like "*LanguagePack-Package*~$lang~*" -and $_.PackageState -eq 'Installed' })
                if ($lp.Count -gt 0) { Write-Log "VERIFY   language pack $lang present" }
                else { Write-Log "VERIFY   language pack $lang is MISSING" 'WARN'; $issues++ }
            }
            $allCaps = @(Get-WindowsCapability -Path $Paths.MainMount @dl | Where-Object { $_.State -eq 'Installed' })
            if (@($Languages).Count -gt 0) {
                $langCaps = @($allCaps | Where-Object { $_.Name -like 'Language.*' })
                Write-Log "VERIFY   language capabilities installed: $($langCaps.Count)"
                foreach ($lang in @($Languages)) {
                    if ($script:LangFontScripts.ContainsKey($lang)) {
                        $fs = $script:LangFontScripts[$lang]
                        if (-not @($langCaps | Where-Object { $_.Name -like "Language.Fonts.$fs~*" })) { Write-Log "VERIFY   font capability for $lang ($fs) is MISSING" 'WARN'; $issues++ }
                    }
                }
            }

            # ---- Section B: final-state inventory (read from this same read-only mount, not tracked during the run) ----
            foreach ($p in $pk) {
                $script:VerifyInventory.Add([pscustomobject]@{ Index = $img.ImageIndex; Category = 'Package'; Item = $p.PackageName; Version = ''; Kb = (Get-KbFromName $p.PackageName); State = [string]$p.PackageState })
            }
            foreach ($c in $allCaps) {
                $capCategory = if ($c.Name -like 'Language.Fonts.*') { 'Font' } elseif ($c.Name -like 'Language.*') { 'Language capability' } else { 'Capability' }
                $script:VerifyInventory.Add([pscustomobject]@{ Index = $img.ImageIndex; Category = $capCategory; Item = $c.Name; Version = ''; Kb = ''; State = [string]$c.State })
            }
            foreach ($f in @(Get-WindowsOptionalFeature -Path $Paths.MainMount -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Enabled' })) {
                $script:VerifyInventory.Add([pscustomobject]@{ Index = $img.ImageIndex; Category = 'Optional feature'; Item = $f.FeatureName; Version = ''; Kb = ''; State = 'Enabled' })
            }
            foreach ($a in @(Get-AppxProvisionedPackage -Path $Paths.MainMount -ErrorAction SilentlyContinue)) {
                $script:VerifyInventory.Add([pscustomobject]@{ Index = $img.ImageIndex; Category = 'Provisioned appx'; Item = $a.DisplayName; Version = [string]$a.Version; Kb = ''; State = 'Provisioned' })
            }
            # No per-user appx exists offline; the closest offline equivalent is what is actually staged under WindowsApps.
            $appxFolder = Join-Chain $Paths.MainMount @('Program Files', 'WindowsApps')
            if (Test-Path -LiteralPath $appxFolder) {
                foreach ($d in @(Get-ChildItem -LiteralPath $appxFolder -Directory -ErrorAction SilentlyContinue | Where-Object { Test-AppxPackageFolder $_.Name })) {
                    $script:VerifyInventory.Add([pscustomobject]@{ Index = $img.ImageIndex; Category = 'Appx package (staged)'; Item = $d.Name; Version = ''; Kb = ''; State = 'Present' })
                }
            }
            # Get-HotFix only works on a running system; offline, a hotfix is a servicing package that names a KB.
            foreach ($h in @($pk | Where-Object { $_.PackageState -eq 'Installed' -and (Get-KbFromName $_.PackageName) })) {
                $script:VerifyInventory.Add([pscustomobject]@{ Index = $img.ImageIndex; Category = 'Hotfix'; Item = (Get-KbFromName $h.PackageName); Version = ''; Kb = (Get-KbFromName $h.PackageName); State = 'Installed' })
            }

            Dismount-WindowsImage -Path $Paths.MainMount -Discard @dl -ErrorAction Stop | Out-Null
        } catch {
            Dismount-IfMounted $Paths.MainMount
            throw
        }
    }
    Write-Log "VERIFY complete: $issues issue(s)."
    return $issues
}

# ---------- change log ----------
function Test-AppxPackageFolder {
    # Package folders under WindowsApps are named <Name>_<Version>_<Arch>_<ResourceId>_<PublisherId>; Windows' own
    # housekeeping folders there ("Deleted", "Merged", "MovedPackages", ...) are not packages (Terry's 2026-09-25 change log).
    param([string]$Name)
    return ($Name -match '^[^_]+_\d+(\.\d+){1,3}_')
}
function Write-ChangeLog {
    # Writes the per-image change log (HTML + CSV) built from $script:ChangeEvents (Section A) and $script:VerifyInventory
    # (Section B, only populated when Test-OutputWim ran). Returns the file paths, or $null if it could not be written.
    param(
        [Parameter(Mandatory)][string]$OsName, [Parameter(Mandatory)][hashtable]$Paths, [Parameter(Mandatory)][string]$Stamp,
        [string]$ToolVersion, [string]$BuildBefore, [string]$BuildAfter, [string[]]$Languages = @(),
        [bool]$ServiceAllIndexes, [pscustomobject]$Selected, [object[]]$IsoSources, [object[]]$Events, [object[]]$Inventory,
        [Nullable[int]]$VerifyIssues, [string]$Gate, [bool]$VerifyRan
    )
    try {
        $safe = ConvertTo-SafeFileName $OsName
        $buildTag = ConvertTo-SafeFileName ($(if ($BuildAfter) { $BuildAfter } elseif ($BuildBefore) { $BuildBefore } else { 'unknown' }))
        $base = "ChangeLog_{0}_{1}_{2}" -f $safe, $buildTag, $Stamp
        $htmlPath = Join-Path $Paths.Logs "$base.html"
        $csvPath = Join-Path $Paths.Logs "$base.csv"
        $runDate = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $edition = if ($ServiceAllIndexes) { 'All indexes (serviced and recombined)' } elseif ($Selected) { "[$($Selected.ImageIndex)] $($Selected.ImageName)" } else { 'n/a' }
        $langText = if (@($Languages).Count -gt 0) { $Languages -join ', ' } else { '(none - English only)' }
        $verifyText = if (-not $VerifyRan) { 'Skipped (Verify was not selected for this run)' } elseif ($null -eq $VerifyIssues) { 'n/a' } else { "$VerifyIssues issue(s) found" }

        # ---- one row list feeds both the CSV and the HTML tables, so they can never drift apart ----
        $rows = [System.Collections.Generic.List[object]]::new()
        $addRow = { param($Section, $Item, $Ver, $State, $Source, $Index, $When = '')
            $rows.Add([pscustomobject]@{ Date = $(if ($When) { $When } else { $runDate }); Section = $Section; Item = $Item; VerKb = $Ver; State = $State; Source = $Source; Index = $Index })
        }
        & $addRow 'Header' 'Operating system' $OsName '' '' ''
        & $addRow 'Header' 'Build before patching' $(if ($BuildBefore) { $BuildBefore } else { 'n/a' }) '' '' ''
        & $addRow 'Header' 'Build after patching' $(if ($BuildAfter) { $BuildAfter } else { 'n/a' }) '' '' ''
        & $addRow 'Header' 'Edition / index serviced' $edition '' '' ''
        & $addRow 'Header' 'Languages' $langText '' '' ''
        & $addRow 'Header' 'Tool version' $ToolVersion '' '' ''
        & $addRow 'Header' 'Validation gate' $Gate '' '' ''
        & $addRow 'Header' 'Verification' $verifyText '' '' ''
        foreach ($src in @($IsoSources | Where-Object { $_ })) { & $addRow 'Header' "Source ISO ($($src.Role))" $src.File '' '' '' }
        foreach ($e in @($Events | Sort-Object Time)) {
            $ver = if ($e.Kb) { $e.Kb } else { $e.Detail }
            # Each Section A row carries the time its step succeeded, not the time the log was written (Terry, 2026-09-25).
            $when = if ($e.Time -is [datetime]) { $e.Time.ToString('yyyy-MM-dd HH:mm:ss') } else { '' }
            & $addRow 'A' $e.Item $ver 'Added' $e.Target '' $when
        }
        foreach ($r in @($Inventory | Sort-Object Index, Category, Item)) {
            $ver = if ($r.Kb) { $r.Kb } elseif ($r.Version) { $r.Version } else { '' }
            & $addRow 'B' $r.Item $ver $r.State $r.Category $r.Index
        }

        # ---- CSV: Date | Section | Item | Version / KB | State | Source | Index ----
        $csvRows = @($rows | ForEach-Object { [pscustomobject]@{ Date = $_.Date; Section = $_.Section; Item = $_.Item; 'Version / KB' = $_.VerKb; State = $_.State; Source = $_.Source; Index = $_.Index } })
        $csvRows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8

        # ---- HTML ----
        $enc = { param($t) [System.Net.WebUtility]::HtmlEncode([string]$t) }
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine('<!DOCTYPE html><html><head><meta charset="utf-8"><title>' + (& $enc "$OsName change log") + '</title><style>')
        [void]$sb.AppendLine('body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#1a1a1a}h1{margin-bottom:2px}h2{margin-top:28px;border-bottom:2px solid #0078D4;padding-bottom:4px}')
        [void]$sb.AppendLine('table{border-collapse:collapse;width:100%;margin-top:8px;font-size:13px}th,td{border:1px solid #ddd;padding:5px 8px;text-align:left;vertical-align:top}th{background:#0078D4;color:#fff;position:sticky;top:0}tr:nth-child(even){background:#f6f8fa}')
        [void]$sb.AppendLine('.meta td:first-child{font-weight:600;width:220px;background:#f6f8fa}.gate-passed{color:#0a7d27;font-weight:700}.gate-failed{color:#c0271e;font-weight:700}.note{color:#555}</style></head><body>')
        [void]$sb.AppendLine('<h1>' + (& $enc $OsName) + '</h1><p class="note">Build ' + (& $enc $(if ($BuildAfter) { $BuildAfter } elseif ($BuildBefore) { $BuildBefore } else { 'unknown' })) + ' &nbsp;|&nbsp; run ' + (& $enc $runDate) + ' &nbsp;|&nbsp; WimForge ' + (& $enc $ToolVersion) + '</p>')
        if (-not $VerifyRan) { [void]$sb.AppendLine('<p class="note"><strong>Note:</strong> Verify was not selected for this run, so Section B (final-state inventory) and the validation gate are not available below.</p>') }
        [void]$sb.AppendLine('<table class="meta">')
        foreach ($h in @($rows | Where-Object { $_.Section -eq 'Header' })) {
            $cls = if ($h.Item -eq 'Validation gate') { if ($h.VerKb -eq 'PASSED') { ' class="gate-passed"' } elseif ($h.VerKb -eq 'FAILED') { ' class="gate-failed"' } else { '' } } else { '' }
            [void]$sb.AppendLine("<tr><td>$(& $enc $h.Item)</td><td$cls>$(& $enc $h.VerKb)</td></tr>")
        }
        [void]$sb.AppendLine('</table>')
        [void]$sb.AppendLine('<h2>Section A - what this tool changed</h2>')
        $aRows = @($rows | Where-Object { $_.Section -eq 'A' })
        if ($aRows.Count -eq 0) { [void]$sb.AppendLine('<p class="note">No changes were recorded (Preflight, or nothing needed adding).</p>') }
        else {
            [void]$sb.AppendLine('<table><tr><th>Date</th><th>Item</th><th>KB / version</th><th>Target</th></tr>')
            foreach ($r in $aRows) { [void]$sb.AppendLine("<tr><td>$(& $enc $r.Date)</td><td>$(& $enc $r.Item)</td><td>$(& $enc $r.VerKb)</td><td>$(& $enc $r.Source)</td></tr>") }
            [void]$sb.AppendLine('</table>')
        }
        [void]$sb.AppendLine('<h2>Section B - final state of the image</h2>')
        $bAll = @($rows | Where-Object { $_.Section -eq 'B' })
        if ($bAll.Count -eq 0) { [void]$sb.AppendLine('<p class="note">Not available (Verify was not selected for this run).</p>') }
        else {
            foreach ($idx in @($bAll | Select-Object -ExpandProperty Index -Unique | Sort-Object)) {
                [void]$sb.AppendLine("<h3>Index $idx</h3><table><tr><th>Date</th><th>Category</th><th>Item</th><th>Version / KB</th><th>State</th></tr>")
                foreach ($r in @($bAll | Where-Object { $_.Index -eq $idx })) { [void]$sb.AppendLine("<tr><td>$(& $enc $r.Date)</td><td>$(& $enc $r.Source)</td><td>$(& $enc $r.Item)</td><td>$(& $enc $r.VerKb)</td><td>$(& $enc $r.State)</td></tr>") }
                [void]$sb.AppendLine('</table>')
            }
        }
        [void]$sb.AppendLine('</body></html>')
        Set-Content -LiteralPath $htmlPath -Value $sb.ToString() -Encoding UTF8
        Write-Log "Change log written: $htmlPath"
        return [pscustomobject]@{ Html = $htmlPath; Csv = $csvPath }
    } catch {
        Write-Log "Change log could not be written: $($_.Exception.Message)" 'WARN'
        return $null
    }
}

# ---------- refreshed media ----------
function New-RefreshedMedia {
    param([string]$OsDrive, [hashtable]$Paths, [string]$InstallWim, [string]$BootWim, [object[]]$SetupDu)
    $media = Join-Path $Paths.NewWim 'Media'
    Remove-DirectoryContents $media
    Write-Log "Copying mounted OS media to $media"
    Copy-Item -Path (Join-Path $OsDrive '*') -Destination $media -Recurse -Force
    Get-ChildItem -LiteralPath $media -Recurse -File -Force | ForEach-Object { $_.IsReadOnly = $false }
    Copy-Item -LiteralPath $InstallWim -Destination (Join-Chain $media @('sources', 'install.wim')) -Force
    $esd = Join-Chain $media @('sources', 'install.esd'); if (Test-Path -LiteralPath $esd) { Remove-Item -LiteralPath $esd -Force }
    if ($BootWim -and (Test-Path -LiteralPath $BootWim)) { Copy-Item -LiteralPath $BootWim -Destination (Join-Chain $media @('sources', 'boot.wim')) -Force }
    foreach ($du in @($SetupDu | Where-Object { $_ })) {
        Write-Log "Expanding Setup DU $($du.FullName)"
        & "$env:SystemRoot\System32\expand.exe" $du.FullName '-F:*' (Join-Path $media 'sources') | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Setup DU expansion failed with exit code $LASTEXITCODE." }
        $duName = Split-Path $du.FullName -Leaf
        Add-ChangeEvent -Category 'SetupDU' -Item $duName -Target 'Media\sources' -Kb (Get-KbFromName $duName) -Detail 'Setup DU expanded into the refreshed media'
    }
    Write-Log "Refreshed media folder ready: $media"
    return $media
}
function Build-IsoFromMedia {
    param([string]$MediaFolder, [hashtable]$Paths)
    $oscdimg = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools" -Filter oscdimg.exe -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $oscdimg) { throw 'Oscdimg.exe was not found. Install the Windows ADK Deployment Tools.' }
    $bios = Join-Chain $MediaFolder @('boot', 'etfsboot.com'); $uefi = Join-Chain $MediaFolder @('efi', 'microsoft', 'boot', 'efisys.bin')
    if (-not (Test-Path -LiteralPath $bios) -or -not (Test-Path -LiteralPath $uefi)) { throw 'Required BIOS or UEFI boot sector files were not found in the media.' }
    $isoOut = Join-Path $Paths.NewWim ("UpdatedMedia_{0}.iso" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $bootData = "-bootdata:2#p0,e,b$bios#pEF,e,b$uefi"
    Write-Log "Building ISO $isoOut"
    & $oscdimg.FullName '-m' '-o' '-u2' '-udfver102' $bootData $MediaFolder $isoOut | ForEach-Object { Write-Log $_ }
    if ($LASTEXITCODE -ne 0) { throw "Oscdimg failed with exit code $LASTEXITCODE." }
}

# ---------- output safety ----------
function Backup-PreviousOutput {
    # Moves whatever is in NEWWIM (previous install.wim, boot.wim, Media, ISO, change logs) into NEWWIM\Archive\<stamp> the first time
    # this run is about to write output, so a run never silently overwrites the last good result. Runs once per run.
    param([Parameter(Mandatory)][hashtable]$Paths, [Parameter(Mandatory)][string]$Stamp, [int]$Keep = 3)
    if ($script:OutputArchived) { return }
    $script:OutputArchived = $true
    $items = @(Get-ChildItem -LiteralPath $Paths.NewWim -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'Archive' })
    if ($items.Count -eq 0) { return }
    $archiveRoot = Join-Path $Paths.NewWim 'Archive'
    $dest = Join-Path $archiveRoot $Stamp
    Ensure-Directory $dest
    foreach ($i in $items) { Move-Item -LiteralPath $i.FullName -Destination $dest -Force }
    Write-Log "Previous output ($($items.Count) item(s)) archived to $dest"
    if ($Keep -gt 0) {
        $dirs = @(Get-ChildItem -LiteralPath $archiveRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
        foreach ($old in @($dirs | Select-Object -Skip $Keep)) {
            Remove-Item -LiteralPath $old.FullName -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "Removed old archive $($old.Name) (keeping the newest $Keep)."
        }
    }
}
function Get-FreeSpaceGB {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($Path))
        return [Math]::Round(([System.IO.DriveInfo]::new($root)).AvailableFreeSpace / 1GB, 1)
    } catch { return $null }
}
function Test-FreeSpace {
    # Rough estimate: the source WIM is copied to OLDWIM and WORKING and exported to NEWWIM (about 3 copies) plus scratch space;
    # media / ISO output each add about one OS ISO. The profile's minFreeGB is a floor.
    param([Parameter(Mandatory)]$Definition, [Parameter(Mandatory)][hashtable]$Paths, [string]$SourceWim, [string]$OsIsoPath, $Options)
    if ($Definition.SpaceCheck -eq 'off') { return }
    $wimGB = 0.0; $isoGB = 0.0
    if ($SourceWim -and (Test-Path -LiteralPath $SourceWim)) {
        $wimGB = (Get-Item -LiteralPath $SourceWim).Length / 1GB
        if ($SourceWim -like '*.esd') { $wimGB = $wimGB * 2.5 }   # ESD is heavily compressed
    }
    if ($OsIsoPath -and (Test-Path -LiteralPath $OsIsoPath)) { $isoGB = (Get-Item -LiteralPath $OsIsoPath).Length / 1GB }
    $need = $wimGB * 3 + 6
    if ($Options.BuildMedia -or $Options.BuildIso) { $need += $isoGB }
    if ($Options.BuildIso) { $need += $isoGB }
    $need = [Math]::Max([Math]::Ceiling($need), $Definition.MinFreeGB)
    $free = Get-FreeSpaceGB -Path $Paths.Root
    if ($null -eq $free) { Write-Log 'Free disk space could not be read; skipping the space check.' 'WARN'; return }
    $driveName = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($Paths.Root))
    $msg = "Free space on $driveName is $free GB; this run needs about $need GB (profile minimum $($Definition.MinFreeGB) GB)."
    if ($free -ge $need) { Write-Log $msg; return }
    if ($Definition.SpaceCheck -eq 'warn') { Write-Log "$msg Continuing because spaceCheck is 'warn'." 'WARN'; return }
    throw "Not enough free disk space. $msg Free up space, or set spaceCheck to 'warn' or 'off' in the profile file $($Definition.SourceFile)."
}

# ---------- repository ----------
function Initialize-Repository {
    param([string]$Root, [pscustomobject]$Definition)
    $leaf = $Definition.Folder
    if (-not (Test-Path -LiteralPath (Join-Path $Root $leaf))) {
        foreach ($alt in @($Definition.AltFolders)) { if (Test-Path -LiteralPath (Join-Path $Root $alt)) { $leaf = $alt; break } }
    }
    $osRoot = Join-Path $Root $leaf
    $p = @{
        Root = $osRoot; ISO = (Join-Path $osRoot 'ISO'); Patches = (Join-Path $osRoot 'PATCHES')
        OldWim = (Join-Path $osRoot 'OLDWIM'); NewWim = (Join-Path $osRoot 'NEWWIM')
        Working = (Join-Path $osRoot 'WORKING'); Temp = (Join-Path $osRoot 'TEMP')
        Logs = (Join-Path $osRoot 'LOGS'); MainMount = (Join-Path $osRoot 'MOUNT\MainOS')
        WinReMount = (Join-Path $osRoot 'MOUNT\WinRE'); WinPeMount = (Join-Path $osRoot 'MOUNT\WinPE')
        WinRE = (Join-Path $osRoot 'WINRE'); WinPE = (Join-Path $osRoot 'WINPE')
    }
    foreach ($dir in @($p.Values) + @('LCU', 'SSU', 'NETCU', 'SAFEOSDU', 'SETUPDU' | ForEach-Object { Join-Path $p.Patches $_ })) { Ensure-Directory $dir }
    return $p
}

# ---------- main run ----------
function Invoke-MediaRefresh {
    param([Parameter(Mandatory)][pscustomobject]$Options)
    $script:Cancelled = $false
    $script:LastResult = $null
    $script:OutputArchived = $false
    $script:ChangeEvents = [System.Collections.Generic.List[object]]::new()
    $script:IsoSources = [System.Collections.Generic.List[object]]::new()
    $script:VerifyInventory = [System.Collections.Generic.List[object]]::new()
    $script:VerifyBuildAfter = $null
    $script:BuildBefore = $null
    if ($Options.PSObject.Properties['ProfilesDir'] -and $Options.ProfilesDir) { $script:OsDefinitions = Import-OsProfiles -Directory ([string]$Options.ProfilesDir) }
    $name = [string]$Options.OsName
    if (-not $name) { throw 'Select an operating system.' }
    $definition = $script:OsDefinitions[$name]
    if (-not $definition) { throw "Unknown OS profile '$name'." }
    if ([string](Get-ProfileValue $Options 'Mode' 'Service') -eq 'Download') {
        # Step 5: acquisition-layer run instead of a servicing run. Everything below this branch (mount/service/verify)
        # is untouched and only reached when Mode is absent or 'Service'.
        $paths = Initialize-Repository -Root $Options.Root.Trim() -Definition $definition
        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $script:LogFile = Join-Path $paths.Logs ("MediaRefresh_{0}.log" -f $stamp)
        Write-Log "Starting WimForge v$($script:ToolVersion) patch acquisition for $name"
        Write-ProfileMessages
        $result = Invoke-PatchAcquisition -Options $Options -Definition $definition -Paths $paths
        $script:LastResult = $result
        return $result
    }
    Set-Phase -OsName $name -Phase $(if ($Options.PreflightOnly) { 'Preflight' } else { 'Starting' })
    $paths = Initialize-Repository -Root $Options.Root.Trim() -Definition $definition
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $script:LogFile = Join-Path $paths.Logs ("MediaRefresh_{0}.log" -f $stamp)
    $script:DismLogArgs = @{ LogPath = (Join-Path $paths.Logs ("DISM_{0}.log" -f $stamp)) }
    Write-Log "Starting WimForge v$($script:ToolVersion) for $name"
    Write-ProfileMessages
    Write-Log "Profile: $($definition.SourceFile)"
    Write-SupportStatus -Definition $definition
    Write-Log "Repository: $($paths.Root)"
    Write-Log "DISM log: $($script:DismLogArgs['LogPath'])"
    $dl = $script:DismLogArgs

    try {
        Set-Phase 'Clearing stale mounts'
        Clear-StaleMounts $paths.Root
        foreach ($d in @($paths.Working, $paths.Temp, $paths.WinRE, $paths.MainMount, $paths.WinReMount, $paths.WinPeMount)) { Remove-DirectoryContents $d }

        $languages = @($Options.Languages | Where-Object { $_ } | ForEach-Object { ([string]$_).ToLowerInvariant() })
        $hasLang = ($languages.Count -gt 0)
        Write-Log ('Languages: ' + $(if ($hasLang) { $languages -join ', ' } else { '(none - English only)' }))
        $enabled = @{ LCU = [bool]$Options.LCU; SSU = [bool]$Options.SSU; NetCU = [bool]$Options.NetCU; SafeOS = [bool]$Options.SafeOS; SetupDU = [bool]$Options.SetupDU }
        $packages = Get-PackageSet -PatchRoot $paths.Patches -Enabled $enabled -Order $definition.PackageOrder
        Test-PackageSet -Definition $definition -Packages $packages -Enabled $enabled -DoWinRe ([bool]$Options.WinRE) -BuildMedia ([bool]$Options.BuildMedia)

        # ISO discovery by content
        Set-Phase 'Mounting ISOs'
        Set-Progress 3 'Mounting source media'
        $isoFiles = @(Get-ChildItem -LiteralPath $paths.ISO -Filter '*.iso' -File)
        if ($isoFiles.Count -eq 0) { throw "No ISO files found in $($paths.ISO)." }
        $mounted = @()
        foreach ($f in $isoFiles) { $mounted += [pscustomobject]@{ Path = $f.FullName; Drive = (Mount-IsoFile $f.FullName) } }
        $roles = Get-IsoRoleMap $mounted
        Write-Log "ISO roles - OS: $($roles.OsDrive)  LanguagePack: $($roles.LpDrive)  FOD: $(@($roles.FodDrives) -join ', ')"
        foreach ($u in $roles.Unclassified) { Write-Log "ISO not recognised as OS, Language Pack or FOD (ignored): $u" 'WARN' }
        $osDrive = $roles.OsDrive
        $fodSource = @(Get-FodSource $roles.FodDrives)
        $driveToFile = @{}
        foreach ($m in $mounted) { $driveToFile[$m.Drive] = (Split-Path $m.Path -Leaf) }
        $script:IsoSources.Add([pscustomobject]@{ Role = 'OS'; File = $driveToFile[$osDrive] })
        if ($roles.LpDrive) { $script:IsoSources.Add([pscustomobject]@{ Role = 'Language Pack'; File = $driveToFile[$roles.LpDrive] }) }
        foreach ($fd in @($roles.FodDrives)) { $script:IsoSources.Add([pscustomobject]@{ Role = 'FOD'; File = $driveToFile[$fd] }) }

        $lpFiles = @{}
        if ($hasLang) {
            if (-not $roles.LpDrive) { throw "Languages are selected but no Language Pack ISO (containing $($definition.LpPattern -f '<lang>')) is in $($paths.ISO)." }
            if (@($roles.FodDrives).Count -eq 0) { throw "Languages are selected but no Features on Demand ISO is in $($paths.ISO); language features and fonts need it. Add it or untick the languages." }
            $lpFiles = Resolve-LanguagePacks -LpRoot $roles.LpDrive -Pattern $definition.LpPattern -Languages $languages
            Write-Log "All $($languages.Count) language packs located."
            if ([bool]$Options.WinRE -or [bool]$Options.Boot) { Write-Log 'Languages are added to install.wim only; WinRE and boot.wim stay English-only.' }
        }

        $sourceWim = if (Test-Path -LiteralPath (Join-Chain $osDrive @('sources', 'install.wim'))) { Join-Chain $osDrive @('sources', 'install.wim') } else { Join-Chain $osDrive @('sources', 'install.esd') }
        $inventory = @(Get-WindowsImage -ImagePath $sourceWim)
        Write-Log ('Detected indexes: ' + (($inventory | ForEach-Object { "[$($_.ImageIndex)] $($_.ImageName)" }) -join '; '))
        $selected = $null
        if (-not $definition.ServiceAllIndexes) {
            $edMatches = @($inventory | Where-Object { $_.ImageName -match $definition.EditionRegex })
            if ($edMatches.Count -gt 1) { throw "Edition pattern '$($definition.EditionRegex)' matched more than one image: $((@($edMatches | ForEach-Object { "[$($_.ImageIndex)] $($_.ImageName)" })) -join '; '). Tighten EditionRegex for '$name' in OsDefinitions, or set PreferredIndex." }
            $selected = if ($edMatches.Count -eq 1) { $edMatches[0] } else { $inventory | Where-Object { $_.ImageIndex -eq $definition.PreferredIndex } | Select-Object -First 1 }
            if (-not $selected) { throw "No edition matched '$($definition.EditionRegex)' and preferred index $($definition.PreferredIndex) is unavailable. Images found: $((@($inventory | ForEach-Object { "[$($_.ImageIndex)] $($_.ImageName)" })) -join '; ')" }
            if ($edMatches.Count -eq 0) { Write-Log "No image name matched '$($definition.EditionRegex)'; falling back to preferred index $($definition.PreferredIndex). Check the detected indexes above." 'WARN' }
            Write-Log "Selected client image index $($selected.ImageIndex): $($selected.ImageName)"
        } else { Write-Log "All $($inventory.Count) indexes will be serviced and recombined." }
        $osIsoPath = @($mounted | Where-Object { $_.Drive -eq $osDrive } | Select-Object -First 1 | ForEach-Object { $_.Path })[0]
        Test-FreeSpace -Definition $definition -Paths $paths -SourceWim $sourceWim -OsIsoPath $osIsoPath -Options $Options
        if ($Options.PreflightOnly) {
            Set-Progress 100 'Preflight passed'
            Set-Phase 'Done'
            Write-Log 'PREFLIGHT OK: ISO roles, patch folders, language packs, edition selection and free space all check out. No image was changed.'
            $script:LastResult = [pscustomobject]@{ NewWim = $paths.NewWim; Install = $null; Boot = $null; Media = $null; VerifyIssues = $null; Preflight = $true; Gate = 'Skipped'; ChangeLogHtml = $null; ChangeLogCsv = $null }
            return
        }
        Set-Phase 'Exporting image'
        $old = Join-Path $paths.OldWim 'install.wim'; Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue
        if ($definition.ServiceAllIndexes) {
            foreach ($img in $inventory) { Export-WindowsImage -SourceImagePath $sourceWim -SourceIndex $img.ImageIndex -DestinationImagePath $old -DestinationName $img.ImageName -CompressionType Max -CheckIntegrity @dl -ErrorAction Stop | Out-Null }
        } else {
            Export-WindowsImage -SourceImagePath $sourceWim -SourceIndex $selected.ImageIndex -DestinationImagePath $old -DestinationName $selected.ImageName -CompressionType Max -CheckIntegrity @dl -ErrorAction Stop | Out-Null
        }
        $first = Get-WindowsImage -ImagePath $old -Index (@(Get-WindowsImage -ImagePath $old)[0].ImageIndex)
        Test-DismHostVersion -ImageVersion $first.Version
        $script:BuildBefore = [string]$first.Version

        $workingInstall = Join-Path $paths.Working 'install.working.wim'; Copy-Item -LiteralPath $old -Destination $workingInstall -Force
        $finalInstall = $null; $finalBoot = $null; $verifyIssues = $null; $mediaFolder = $null; $gate = 'Skipped'
        if ($Options.Install) {
            $workImages = @(Get-WindowsImage -ImagePath $workingInstall)
            $n = 0
            foreach ($img in $workImages) {
                $n++
                $indexLabel = if ($workImages.Count -gt 1) { "index $($img.ImageIndex) of $($workImages.Count)" } else { "index $($img.ImageIndex)" }
                Set-Progress (15 + [int](45 * $n / $workImages.Count)) "Servicing install.wim $indexLabel"
                Set-Phase "Servicing install.wim ($indexLabel)"
                Service-InstallIndex -ImagePath $workingInstall -Index $img.ImageIndex -Paths $paths -Packages $packages -OsDrive $osDrive `
                    -LpFiles $lpFiles -FodSource $fodSource -Languages $languages -DoWinRe ([bool]$Options.WinRE) -DoNetFx3 ([bool]$Options.NetFx3)
            }
            Backup-PreviousOutput -Paths $paths -Stamp $stamp -Keep $definition.KeepArchives
            $finalInstall = Join-Path $paths.NewWim 'install.wim'
            Set-Phase 'Exporting install.wim'
            Set-Progress 65 'Optimizing final install.wim'
            Export-OptimizedWim $workingInstall $finalInstall
            $finalCount = @(Get-WindowsImage -ImagePath $finalInstall).Count
            if ((-not $definition.ServiceAllIndexes) -and $finalCount -ne 1) { throw "Client output validation failed: expected one index, found $finalCount." }
            Write-Log "Import-ready install.wim created: $finalInstall ($finalCount index(es))"
            if ($Options.Verify) {
                Set-Phase 'Verifying image'
                Set-Progress 68 'Verifying final install.wim'
                $verifyIssues = Test-OutputWim -WimPath $finalInstall -Paths $paths -Languages $languages -ExpectLcu $enabled.LCU
                $gate = if ($verifyIssues -eq 0) { 'PASSED' } else { 'FAILED' }
                if ($gate -eq 'FAILED') { Write-Log "VALIDATION GATE: FAILED ($verifyIssues issue(s)). Review the VERIFY lines above before importing this image into SCCM." 'ERROR' }
                else { Write-Log 'VALIDATION GATE: PASSED.' }
            } else {
                Write-Log 'Verify was not selected, so the validation gate and the change log Section B (final-state inventory) are not available for this run.' 'WARN'
            }
        }

        if ($Options.Boot) {
            $sourceBoot = Join-Chain $osDrive @('sources', 'boot.wim')
            if (-not (Test-Path -LiteralPath $sourceBoot)) { throw "boot.wim not found at $sourceBoot" }
            Set-Phase 'Servicing boot.wim'
            Set-Progress 75 'Servicing boot.wim'
            Backup-PreviousOutput -Paths $paths -Stamp $stamp -Keep $definition.KeepArchives
            $finalBoot = Join-Path $paths.NewWim 'boot.wim'
            Service-BootWim -SourceBoot $sourceBoot -Destination $finalBoot -Paths $paths -Packages $packages
            Write-Log "Import-ready boot.wim created: $finalBoot"
        }
        if ($Options.BuildMedia -or $Options.BuildIso) {
            if (-not $finalInstall) { throw 'Refreshed media requires Create updated install.wim.' }
            Set-Phase 'Building refreshed media folder'
            Set-Progress 88 'Building refreshed media folder'
            Backup-PreviousOutput -Paths $paths -Stamp $stamp -Keep $definition.KeepArchives
            $mediaFolder = New-RefreshedMedia -OsDrive $osDrive -Paths $paths -InstallWim $finalInstall -BootWim $finalBoot -SetupDu $packages.SetupDU
            if ($Options.BuildIso) { Set-Phase 'Building ISO'; Set-Progress 94 'Building ISO'; Build-IsoFromMedia -MediaFolder $mediaFolder -Paths $paths }
        }
        $changeLogPaths = $null
        if ($Options.Install) {
            Set-Phase 'Writing change log'
            $changeLogPaths = Write-ChangeLog -OsName $name -Paths $paths -Stamp $stamp -ToolVersion $script:ToolVersion -BuildBefore $script:BuildBefore -BuildAfter $script:VerifyBuildAfter `
                -Languages $languages -ServiceAllIndexes $definition.ServiceAllIndexes -Selected $selected -IsoSources @($script:IsoSources) -Events @($script:ChangeEvents) `
                -Inventory @($script:VerifyInventory) -VerifyIssues $verifyIssues -Gate $gate -VerifyRan ([bool]$Options.Verify)
            if ($changeLogPaths) {
                foreach ($f in @($changeLogPaths.Html, $changeLogPaths.Csv)) { Copy-Item -LiteralPath $f -Destination $paths.NewWim -Force -ErrorAction SilentlyContinue }
            }
        }
        Set-Progress 100 'Completed successfully'
        Set-Phase 'Done'
        if ($null -ne $verifyIssues -and $verifyIssues -gt 0) { Write-Log "Media refresh finished, but verification reported $verifyIssues issue(s). Review the VERIFY lines above." 'WARN' }
        else { Write-Log 'Media refresh completed successfully.' }
        $script:LastResult = [pscustomobject]@{
            NewWim = $paths.NewWim; Install = $finalInstall; Boot = $finalBoot; Media = $mediaFolder; VerifyIssues = $verifyIssues; Preflight = $false
            Gate = $gate; ChangeLogHtml = $(if ($changeLogPaths) { $changeLogPaths.Html } else { $null }); ChangeLogCsv = $(if ($changeLogPaths) { $changeLogPaths.Csv } else { $null })
        }
    } finally { Dismount-AllIso }
}
#endregion ENGINE

#region GUI
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="WimForge v2.4" Height="780" Width="1040" WindowStartupLocation="CenterScreen" Background="#F4F6F8">
 <Grid Margin="18"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
  <Grid Grid.Row="0" Margin="0,0,0,12"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
   <StackPanel Grid.Column="0"><TextBlock Text="WimForge" FontSize="25" FontWeight="SemiBold"/><TextBlock Text="Create cleaned, optimized, verified install.wim files (and optional boot.wim, refreshed media folder and ISO)." Foreground="#555" Margin="0,4,0,0"/></StackPanel>
   <StackPanel Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" MinWidth="220"><TextBlock x:Name="HeaderOs" Text="" FontSize="16" FontWeight="SemiBold" TextAlignment="Right" HorizontalAlignment="Right"/><TextBlock x:Name="HeaderPhase" Text="Idle" FontSize="13" Foreground="#555" TextAlignment="Right" HorizontalAlignment="Right" Margin="0,2,0,0"/></StackPanel>
  </Grid>
  <TabControl Grid.Row="1">
   <TabItem Header="Source and targets"><Grid Margin="18"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions><Grid.ColumnDefinitions><ColumnDefinition Width="220"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
    <TextBlock Grid.Row="0" Grid.Column="0" Text="Repository root" Margin="0,8"/><TextBox x:Name="RootText" Grid.Row="0" Grid.Column="1" Text="F:\mediaRefresh" Height="30" Padding="6"/>
    <TextBlock Grid.Row="1" Grid.Column="0" Text="Operating system" Margin="0,14,0,8"/><StackPanel Grid.Row="1" Grid.Column="1" Margin="0,8"><DockPanel><Button x:Name="ReloadProfilesButton" DockPanel.Dock="Right" Content="Reload profiles" Margin="8,0,0,0" Padding="12,0" ToolTip="Re-read the JSON files in the Profiles folder"/><Button x:Name="AcquirePatchesButton" DockPanel.Dock="Right" Content="Download patches..." Margin="8,0,0,0" Padding="12,0" ToolTip="Search the Microsoft Update Catalog (MSCatalogLTS) for the selected OS. Shows a dry-run preview first and requires confirmation; never touches PATCHES\SSU."/><ComboBox x:Name="OsCombo" Height="32"/></DockPanel><TextBlock x:Name="ProfileInfo" Margin="2,6,0,0" Foreground="#555" TextWrapping="Wrap"/></StackPanel>
    <GroupBox Grid.Row="2" Grid.ColumnSpan="2" Header="Outputs" Margin="0,14,0,0"><StackPanel Margin="12"><CheckBox x:Name="ChkPreflight" Content="Preflight check only (about a minute: checks ISOs, patch folders, language packs and edition; changes nothing)" IsChecked="False" Margin="0,3"/><CheckBox x:Name="ChkInstall" Content="Create updated install.wim" IsChecked="True" Margin="0,3"/><CheckBox x:Name="ChkWinRE" Content="Service embedded WinRE (once, reused for every index)" IsChecked="True" Margin="0,3"/><CheckBox x:Name="ChkVerify" Content="Verify the final install.wim (read-only mount, logs RollupFix, language packs, fonts)" IsChecked="True" Margin="0,3"/><CheckBox x:Name="ChkBoot" Content="Create updated boot.wim (usually only needed per major CM update)" IsChecked="False" Margin="0,3"/><CheckBox x:Name="ChkBuildMedia" Content="Create refreshed media folder for an OS Upgrade Package (NEWWIM\Media)" IsChecked="False" Margin="0,3"/><CheckBox x:Name="ChkBuildIso" Content="Also build an ISO from that media (requires Windows ADK Oscdimg)" IsChecked="False" Margin="0,3"/></StackPanel></GroupBox>
    <TextBlock Grid.Row="3" Grid.ColumnSpan="2" Margin="0,18" TextWrapping="Wrap" Foreground="#555" Text="ISO roles (OS, Language Pack, Features on Demand) are detected from ISO content, so file names do not matter. Keep one ISO per role in the ISO folder. Client operating systems export a single index; Windows Server 2022 preserves and services every index."/>
   </Grid></TabItem>
   <TabItem Header="Updates and features"><Grid Margin="18"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
    <GroupBox Grid.Column="0" Header="Patch selection" Margin="0,0,10,0"><StackPanel Margin="12"><CheckBox x:Name="ChkSSU" Content="Servicing Stack Update (PATCHES\SSU)" IsChecked="True" Margin="0,5"/><CheckBox x:Name="ChkLCU" Content="Latest Cumulative Update (PATCHES\LCU)" IsChecked="True" Margin="0,5"/><CheckBox x:Name="ChkSafeOS" Content="Safe OS Dynamic Update (PATCHES\SAFEOSDU, used for WinRE)" IsChecked="True" Margin="0,5"/><CheckBox x:Name="ChkNetCU" Content=".NET Cumulative Update (PATCHES\NETCU)" IsChecked="True" Margin="0,5"/><CheckBox x:Name="ChkSetupDU" Content="Setup Dynamic Update (PATCHES\SETUPDU, used for refreshed media)" IsChecked="True" Margin="0,5"/></StackPanel></GroupBox>
    <GroupBox Grid.Column="1" Header="Optional content" Margin="10,0,0,0"><StackPanel Margin="12"><CheckBox x:Name="ChkNetFx3" Content="Enable .NET Framework 3.5 from OS ISO sources\sxs" IsChecked="False" Margin="0,5"/><TextBlock Text="Ticked patch types with an empty folder are logged and skipped, except LCU (and the SSU on legacy OSes), which stop the run so you never get an unpatched image by accident." TextWrapping="Wrap" Foreground="#555" Margin="0,16,0,0"/></StackPanel></GroupBox>
   </Grid></TabItem>
   <TabItem Header="Languages"><Grid Margin="18"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions><TextBlock Text="Language packs, language features and fonts to add to install.wim (WinRE and boot.wim stay English-only). Requires a Language Pack ISO and a Features on Demand ISO. Leave empty for English only. Defaults follow the selected operating system. The list comes from Profiles\Languages.json." TextWrapping="Wrap"/><ListBox x:Name="LanguageList" Grid.Row="1" SelectionMode="Multiple" Margin="0,12,0,0"/></Grid></TabItem>
   <TabItem Header="Log"><TextBox x:Name="LogBox" Margin="12" IsReadOnly="True" AcceptsReturn="True" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" FontFamily="Consolas" FontSize="12" Background="#111827" Foreground="#E5E7EB"/></TabItem>
  </TabControl>
  <Grid Grid.Row="2" Margin="0,14,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><StackPanel><TextBlock x:Name="Status" Text="Ready"/><ProgressBar x:Name="Progress" Height="18" Minimum="0" Maximum="100" Margin="0,5,14,0"/></StackPanel><Button x:Name="SaveSettingsButton" Grid.Column="1" Content="Save settings" Width="110" Height="38" Margin="0,0,8,0" ToolTip="Save the ticked options and languages for the selected operating system (Settings folder beside Profiles). They are loaded whenever this OS is selected."/><Button x:Name="ResetSettingsButton" Grid.Column="2" Content="Reset to defaults" Width="120" Height="38" Margin="0,0,14,0" ToolTip="Delete the saved settings for the selected operating system and go back to the defaults."/><Button x:Name="RunButton" Grid.Column="3" Content="Start refresh" Width="130" Height="38" Margin="0,0,8,0" Background="#0078D4" Foreground="White" FontWeight="SemiBold"/><Button x:Name="CancelButton" Grid.Column="4" Content="Cancel" Width="90" Height="38" IsEnabled="False"/></Grid>
 </Grid>
</Window>
'@
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
foreach ($ctl in @('HeaderOs','HeaderPhase','RootText','OsCombo','ReloadProfilesButton','AcquirePatchesButton','ProfileInfo','ChkPreflight','ChkInstall','ChkBoot','ChkWinRE','ChkVerify','ChkBuildMedia','ChkBuildIso','ChkSSU','ChkLCU','ChkSafeOS','ChkNetCU','ChkSetupDU','ChkNetFx3','LanguageList','LogBox','Status','Progress','RunButton','CancelButton','SaveSettingsButton','ResetSettingsButton')) {
    Set-Variable -Name $ctl -Value $window.FindName($ctl) -Scope Script
}
# Profiles: JSON files in a Profiles folder beside the script (or under LOCALAPPDATA when the script has no file path).
$script:ProfilesDir = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'Profiles' } else { Join-Path $env:LOCALAPPDATA 'MediaRefreshStudio\Profiles' }
# Saved GUI choices (step 10c): Settings\<OS folder>.json per OS and Settings\General.json, beside Profiles.
$script:SettingsDir = Join-Path (Split-Path $script:ProfilesDir -Parent) 'Settings'
# The window's own checkbox defaults, restored when an OS without saved settings is selected.
$script:DefaultChecks = @{}
foreach ($n in $script:SettingOptionNames) { $script:DefaultChecks[$n] = [bool](Get-Variable -Name "Chk$n" -Scope Script -ValueOnly).IsChecked }
$script:LanguageOptions = @(Import-LanguageList)   # built-in list until the Profiles folder is loaded
function Update-LanguageItems {
    # One entry per Languages.json row, shown as "German (Germany) - de-de"; the code is kept in Tag and is what runs use.
    $script:LanguageList.Items.Clear()
    foreach ($l in @($script:LanguageOptions)) {
        $li = New-Object System.Windows.Controls.ListBoxItem
        $li.Content = $l.Display; $li.Tag = $l.Code
        [void]$script:LanguageList.Items.Add($li)
    }
}
function Set-DefaultLanguages {
    $def = $script:OsDefinitions[[string]$script:OsCombo.SelectedItem]
    if (-not $def) { return }
    $sel = Get-DefaultLanguageSelection -Definition $def -LanguageList $script:LanguageOptions
    foreach ($item in $script:LanguageList.Items) { $item.IsSelected = (@($sel.Select) -contains [string]$item.Tag) }
    if (@($sel.Missing).Count -gt 0) { Write-Log "Default language(s) $(@($sel.Missing) -join ', ') of $($def.Name) are not in $($script:LanguagesFileName) and were not selected." 'WARN' }
}
function Set-OsSettings {
    # Applies the selected OS's saved settings, or the defaults (window defaults + the profile's default languages).
    $def = $script:OsDefinitions[[string]$script:OsCombo.SelectedItem]
    if (-not $def) { return }
    $saved = Read-OsSettings -Directory $script:SettingsDir -Definition $def -LanguageList $script:LanguageOptions
    foreach ($n in $script:SettingOptionNames) {
        $value = if ($saved -and $saved.Options.ContainsKey($n)) { $saved.Options[$n] } else { $script:DefaultChecks[$n] }
        (Get-Variable -Name "Chk$n" -Scope Script -ValueOnly).IsChecked = [bool]$value
    }
    if ($saved) {
        foreach ($item in $script:LanguageList.Items) { $item.IsSelected = (@($saved.Languages) -contains [string]$item.Tag) }
        if (@($saved.MissingLanguages).Count -gt 0) { Write-Log "Saved language(s) $(@($saved.MissingLanguages) -join ', ') for $($def.Name) are not in $($script:LanguagesFileName) and were not selected." 'WARN' }
        Write-Log "Settings for $($def.Name) loaded from $($saved.File)"
    } else { Set-DefaultLanguages }
}
function Get-SelectedSettings {
    $opts = @{}
    foreach ($n in $script:SettingOptionNames) { $opts[$n] = [bool](Get-Variable -Name "Chk$n" -Scope Script -ValueOnly).IsChecked }
    $langs = @(foreach ($item in $script:LanguageList.Items) { if ($item.IsSelected) { [string]$item.Tag } })
    return [pscustomobject]@{ Options = $opts; Languages = $langs }
}
function Save-CurrentOsSettings {
    $def = $script:OsDefinitions[[string]$script:OsCombo.SelectedItem]
    if (-not $def) { return $null }
    $sel = Get-SelectedSettings
    $file = Save-OsSettings -Directory $script:SettingsDir -Definition $def -Options $sel.Options -Languages $sel.Languages
    Save-GeneralSettings -Directory $script:SettingsDir -Root ([string]$script:RootText.Text)
    Write-Log "Settings for $($def.Name) saved to $file ($(@($sel.Languages).Count) language(s)); repository root saved."
    return $file
}
function Reset-CurrentOsSettings {
    $def = $script:OsDefinitions[[string]$script:OsCombo.SelectedItem]
    if (-not $def) { return }
    if (Remove-OsSettings -Directory $script:SettingsDir -Definition $def) { Write-Log "Saved settings for $($def.Name) removed; defaults restored." }
    else { Write-Log "No saved settings for $($def.Name); defaults restored." }
    Set-OsSettings
}
function Update-ProfileInfo {
    $def = $script:OsDefinitions[[string]$script:OsCombo.SelectedItem]
    if (-not $def) { $script:ProfileInfo.Text = ''; return }
    $st = Get-SupportStatus -Definition $def
    $script:ProfileInfo.Text = "Profile file: $($def.SourceFile)   |   $($st.Text)"
    $script:ProfileInfo.Foreground = if ($st.Level -in @('Past', 'Soon')) { [System.Windows.Media.Brushes]::Firebrick } else { [System.Windows.Media.Brushes]::DimGray }
}
function Update-HeaderIdle {
    # Shows the selected OS in the header while nothing is running. During a run, Update-RunUi overwrites this from the queue.
    if (-not $script:RunButton.IsEnabled) { return }
    $script:HeaderOs.Text = [string]$script:OsCombo.SelectedItem
    $script:HeaderPhase.Text = 'Idle'
}
function Update-ProfileList {
    $previous = [string]$script:OsCombo.SelectedItem
    $script:OsDefinitions = Import-OsProfiles -Directory $script:ProfilesDir
    $script:LanguageOptions = @(Import-LanguageList -Directory $script:ProfilesDir)
    Write-ProfileMessages
    Update-LanguageItems
    $script:OsCombo.Items.Clear()
    foreach ($osName in $script:OsDefinitions.Keys) { [void]$script:OsCombo.Items.Add($osName) }
    $script:OsCombo.SelectedIndex = if ($previous -and $script:OsCombo.Items.Contains($previous)) { $script:OsCombo.Items.IndexOf($previous) } else { 0 }
}
function Get-UiOptions {
    $langs = @(foreach ($item in $script:LanguageList.Items) { if ($item.IsSelected) { [string]$item.Tag } })
    return [pscustomobject]@{
        OsName = [string]$script:OsCombo.SelectedItem; Root = [string]$script:RootText.Text
        PreflightOnly = [bool]$script:ChkPreflight.IsChecked; Install = [bool]$script:ChkInstall.IsChecked; Boot = [bool]$script:ChkBoot.IsChecked; WinRE = [bool]$script:ChkWinRE.IsChecked
        Verify = [bool]$script:ChkVerify.IsChecked; BuildMedia = [bool]$script:ChkBuildMedia.IsChecked; BuildIso = [bool]$script:ChkBuildIso.IsChecked
        SSU = [bool]$script:ChkSSU.IsChecked; LCU = [bool]$script:ChkLCU.IsChecked; SafeOS = [bool]$script:ChkSafeOS.IsChecked
        NetCU = [bool]$script:ChkNetCU.IsChecked; SetupDU = [bool]$script:ChkSetupDU.IsChecked; NetFx3 = [bool]$script:ChkNetFx3.IsChecked
        Languages = $langs; ProfilesDir = $script:ProfilesDir
    }
}
$script:OsCombo.Add_SelectionChanged({ Set-OsSettings; Update-ProfileInfo; Update-HeaderIdle })
$script:SaveSettingsButton.Add_Click({
    if (-not $script:RunButton.IsEnabled) { return }
    try { if (Save-CurrentOsSettings) { $script:Status.Text = "Settings saved for $([string]$script:OsCombo.SelectedItem)" } }
    catch { [System.Windows.MessageBox]::Show("Could not save the settings: $($_.Exception.Message)", 'WimForge', 'OK', 'Error') | Out-Null }
})
$script:ResetSettingsButton.Add_Click({
    if (-not $script:RunButton.IsEnabled) { return }
    $os = [string]$script:OsCombo.SelectedItem
    $answer = [System.Windows.MessageBox]::Show("Delete the saved settings for $os and go back to the defaults?", 'WimForge - reset settings', 'YesNo', 'Question')
    if ($answer -ne 'Yes') { return }
    try { Reset-CurrentOsSettings; $script:Status.Text = "Defaults restored for $os" }
    catch { [System.Windows.MessageBox]::Show("Could not reset the settings: $($_.Exception.Message)", 'WimForge', 'OK', 'Error') | Out-Null }
})
$script:ReloadProfilesButton.Add_Click({
    if (-not $script:RunButton.IsEnabled) { return }
    Update-ProfileList
    Write-Log "Profiles reloaded from $($script:ProfilesDir)"
})
$savedRoot = Read-GeneralSettings -Directory $script:SettingsDir
if ($savedRoot) { $script:RootText.Text = $savedRoot; Write-Log "Repository root loaded from saved settings: $savedRoot" }
Update-ProfileList
Set-OsSettings
Update-ProfileInfo
Update-HeaderIdle

# ---- Background execution: the engine runs on its own runspace so the window never blocks on DISM ----
# The engine text is read from this file (the ENGINE region) and loaded into a fresh runspace. It talks to the window through a
# thread-safe queue (log lines and progress) and a synchronized hashtable (Cancel flag, final result).
$script:EngineText = $null
try {
    if ($PSCommandPath -and (Test-Path -LiteralPath $PSCommandPath)) {
        $selfText = [System.IO.File]::ReadAllText($PSCommandPath)
        $em = [regex]::Match($selfText, '(?s)#region ENGINE(.*?)#endregion ENGINE')
        if ($em.Success) { $script:EngineText = $em.Groups[1].Value }
    }
} catch { $script:EngineText = $null }

$script:RunnerScript = @'
param($RunEngineText, $RunQueue, $RunShared, $RunOptions)
# Parameter names are deliberately unlike the engine's $script:UiQueue / $script:Shared: on a runspace the script scope
# IS the global scope, and the engine initialises its own variables when it is loaded.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try {
    Import-Module Dism -ErrorAction Stop
    . ([scriptblock]::Create($RunEngineText))
    $script:UiQueue = $RunQueue
    $script:Shared  = $RunShared
    try {
        Invoke-MediaRefresh -Options $RunOptions | Out-Null
        $RunShared['Result'] = $script:LastResult
        $RunShared['Ok'] = $true
    } catch {
        $RunShared['Ok'] = $false
        $RunShared['Message'] = $_.Exception.Message
        try {
            Write-Log $_.Exception.ToString() 'ERROR'
            Write-Log ('At line {0}: {1}' -f $_.InvocationInfo.ScriptLineNumber, $_.InvocationInfo.Line.Trim()) 'ERROR'
            Set-Progress 0 'Failed'
        } catch { }
    } finally {
        try { Dismount-AllIso } catch { }
    }
} catch {
    $RunShared['Ok'] = $false
    $RunShared['Message'] = 'Background runner failed to start: ' + $_.Exception.Message
} finally {
    $RunShared['Done'] = $true
}
'@

$script:RunQueue = $null; $script:RunShared = $null; $script:RunPs = $null; $script:RunRs = $null; $script:RunHandle = $null; $script:PendingDownloadOptions = $null
$script:RunStatus = 'Ready'; $script:RunStarted = $null
$script:UiTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:UiTimer.Interval = [TimeSpan]::FromMilliseconds(250)

function Update-RunUi {
    # Runs on the GUI thread every 250 ms: drains log/progress messages, refreshes the elapsed time, detects completion.
    $sb = New-Object System.Text.StringBuilder
    $item = $null; $n = 0
    while ($n -lt 400 -and $script:RunQueue.TryDequeue([ref]$item)) {
        $n++
        $parts = ([string]$item) -split "`t", 3
        if ($parts[0] -eq 'L' -and $parts.Count -ge 2) { [void]$sb.AppendLine($parts[1]) }
        elseif ($parts[0] -eq 'P' -and $parts.Count -ge 3) {
            $v = 0; if ([int]::TryParse($parts[1], [ref]$v)) { $script:Progress.Value = $v }
            $script:RunStatus = $parts[2]
        }
        elseif ($parts[0] -eq 'H' -and $parts.Count -ge 3) {
            if ($script:HeaderOs)    { $script:HeaderOs.Text = $parts[1] }
            if ($script:HeaderPhase) { $script:HeaderPhase.Text = $parts[2] }
        }
    }
    if ($sb.Length -gt 0) { $script:LogBox.AppendText($sb.ToString()); $script:LogBox.ScrollToEnd() }
    if ($script:RunStarted) {
        $el = [DateTime]::Now - $script:RunStarted
        $script:Status.Text = ('{0}   (elapsed {1:00}:{2:00}:{3:00})' -f $script:RunStatus, [int][Math]::Floor($el.TotalHours), $el.Minutes, $el.Seconds)
    }
    if ($script:RunHandle -and $script:RunHandle.IsCompleted -and $script:RunQueue.IsEmpty) { Complete-BackgroundRun }
}

function Complete-BackgroundRun {
    $script:UiTimer.Stop()
    $shared = $script:RunShared
    $engineErrors = @()
    try { [void]$script:RunPs.EndInvoke($script:RunHandle) } catch { $engineErrors += $_.Exception.Message }
    try { $engineErrors += @($script:RunPs.Streams.Error | ForEach-Object { $_.ToString() }) } catch { }
    try { $script:RunPs.Dispose() } catch { }
    try { $script:RunRs.Close(); $script:RunRs.Dispose() } catch { }
    $script:RunHandle = $null; $script:RunPs = $null; $script:RunRs = $null; $script:RunStarted = $null
    $ok = ($shared.ContainsKey('Ok') -and $shared['Ok'])
    $wasCancelled = ($script:Cancelled -or ($shared.ContainsKey('Cancel') -and $shared['Cancel']))
    $res = if ($shared.ContainsKey('Result')) { $shared['Result'] } else { $null }
    $isDownload = ($ok -and $res -and ([string](Get-ProfileValue $res 'Mode' '')) -eq 'Download')

    # Step 5: a dry-run search finished. Show what it found and ask before really downloading, instead of unlocking
    # the buttons - the user's answer either restarts the background run for real, or returns everything to Ready.
    if ($isDownload -and [bool](Get-ProfileValue $res 'DryRun' $false) -and -not $wasCancelled) {
        $script:Status.Text = 'Ready'; $script:Progress.Value = 0
        if ($script:HeaderPhase) { $script:HeaderPhase.Text = 'Idle' }
        $plan = @($res.Plan)
        if ($plan.Count -eq 0) {
            $skip = @($res.SkippedClasses) -join "`n - "
            $msg = "No catalog results to download.$(if ($skip) { "`n`nSkipped:`n - $skip" })"
            [System.Windows.MessageBox]::Show($msg, 'WimForge', 'OK', 'Information') | Out-Null
            $script:RunButton.IsEnabled = $true; $script:AcquirePatchesButton.IsEnabled = $true; $script:CancelButton.IsEnabled = $false
        } else {
            $lines = @($plan | ForEach-Object { "  $($_.Class): $(Format-CatalogPick -Title $_.Title -Kb $_.Kb -Date $_.Date -Classification $_.Classification -Release:($_.Class -eq 'LCU'))" })
            $msg = "This would download and keep the following (older files already in the same PATCHES class are removed; PATCHES\SSU is never touched):`n`n$($lines -join "`n")`n`nThe newest cumulative release is picked, out-of-band included. The LCU line says whether its release date is Patch Tuesday (the second Tuesday) or out-of-band.`n`nDownload these now?"
            $answer = [System.Windows.MessageBox]::Show($msg, 'WimForge - confirm download', 'YesNo', 'Question')
            if ($answer -eq 'Yes' -and $script:PendingDownloadOptions) {
                $go = $script:PendingDownloadOptions
                $go | Add-Member -NotePropertyName DryRun -NotePropertyValue $false -Force
                try { Start-BackgroundRun -Options $go; return }
                catch {
                    [System.Windows.MessageBox]::Show("Could not start the download: $($_.Exception.Message)", 'WimForge', 'OK', 'Error') | Out-Null
                    $script:RunButton.IsEnabled = $true; $script:AcquirePatchesButton.IsEnabled = $true; $script:CancelButton.IsEnabled = $false
                }
            } else {
                $script:RunButton.IsEnabled = $true; $script:AcquirePatchesButton.IsEnabled = $true; $script:CancelButton.IsEnabled = $false
            }
        }
        return
    }

    $script:RunButton.IsEnabled = $true; $script:AcquirePatchesButton.IsEnabled = $true; $script:CancelButton.IsEnabled = $false
    if ($ok) {
        $script:Status.Text = 'Done'; $script:Progress.Value = 100
        if ($script:HeaderPhase) { $script:HeaderPhase.Text = 'Done' }
        if ($isDownload) {
            $dl = @($res.Downloaded); $rm = @($res.Removed); $skip = @($res.SkippedClasses)
            $msg = "Downloaded $($dl.Count) file(s)."
            if ($dl.Count -gt 0) { $msg += "`n`n" + (($dl | ForEach-Object { "  $($_.Class): $(Split-Path $_.File -Leaf)" }) -join "`n") }
            if ($rm.Count -gt 0) { $msg += "`n`nRemoved $($rm.Count) superseded file(s)." }
            if ($skip.Count -gt 0) { $msg += "`n`nSkipped: " + ($skip -join '; ') }
            [System.Windows.MessageBox]::Show($msg, 'WimForge', 'OK', 'Information') | Out-Null
            return
        }
        if ($null -eq $res) { $res = [pscustomobject]@{ NewWim = ''; Preflight = $false; VerifyIssues = $null; Gate = $null } }
        $msg = "Completed successfully.`n`nOutput: $($res.NewWim)"
        if ($res.Preflight) { $msg = 'Preflight passed. No image was changed. See the Log tab for the ISO roles, patch counts and selected edition.' }
        if ($null -ne $res.VerifyIssues -and $res.VerifyIssues -gt 0) { $msg = "Completed with $($res.VerifyIssues) verification issue(s). Review the Log tab.`n`nOutput: $($res.NewWim)" }
        if ($res.Gate -eq 'FAILED') {
            $msg = "Completed, but the VALIDATION GATE FAILED (build, edition or applied-patch check did not pass). Review the change log and Log tab before importing this image into SCCM.`n`nOutput: $($res.NewWim)"
            [System.Windows.MessageBox]::Show($msg, 'WimForge', 'OK', 'Warning') | Out-Null
        } else {
            [System.Windows.MessageBox]::Show($msg, 'WimForge', 'OK', 'Information') | Out-Null
        }
    } else {
        $script:Status.Text = if ($wasCancelled) { 'Cancelled' } else { 'Failed' }
        $script:Progress.Value = 0
        if ($script:HeaderPhase) { $script:HeaderPhase.Text = if ($wasCancelled) { 'Cancelled' } else { 'Failed' } }
        $m = if ($wasCancelled -and -not ($shared.ContainsKey('Message') -and $shared['Message'])) { 'The run was cancelled.' } elseif ($shared.ContainsKey('Message') -and $shared['Message']) { [string]$shared['Message'] } elseif ($engineErrors.Count -gt 0) { [string]$engineErrors[0] } else { 'The run ended unexpectedly. See the Log tab.' }
        $script:LogBox.AppendText("[$(if ($wasCancelled) { 'CANCELLED' } else { 'ERROR' })] $m" + [Environment]::NewLine)
        [System.Windows.MessageBox]::Show($m, 'WimForge', 'OK', $(if ($wasCancelled) { 'Warning' } else { 'Error' })) | Out-Null
    }
}

function Start-BackgroundRun {
    param($Options)
    $script:RunQueue  = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
    $script:RunShared = [hashtable]::Synchronized(@{ Cancel = $false; Done = $false })
    $script:RunStatus = 'Starting...'; $script:RunStarted = [DateTime]::Now
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'; $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript($script:RunnerScript, $true).AddArgument($script:EngineText).AddArgument($script:RunQueue).AddArgument($script:RunShared).AddArgument($Options)
    $script:RunRs = $rs; $script:RunPs = $ps
    $script:RunHandle = $ps.BeginInvoke()
    $script:UiTimer.Start()
}
$script:UiTimer.Add_Tick({ try { Update-RunUi } catch { $script:UiTimer.Stop(); [System.Windows.MessageBox]::Show("Display update failed: $($_.Exception.Message)`nThe run may still be active; check the log file in the OS LOGS folder.", 'WimForge') | Out-Null } })

$script:RunButton.Add_Click({
    $script:RunButton.IsEnabled = $false; $script:AcquirePatchesButton.IsEnabled = $false; $script:CancelButton.IsEnabled = $true
    $script:Cancelled = $false
    $opts = Get-UiOptions
    if ($script:EngineText) {
        try { Start-BackgroundRun -Options $opts }
        catch {
            $script:RunButton.IsEnabled = $true; $script:AcquirePatchesButton.IsEnabled = $true; $script:CancelButton.IsEnabled = $false
            [System.Windows.MessageBox]::Show("Could not start the background run: $($_.Exception.Message)", 'WimForge', 'OK', 'Error') | Out-Null
        }
        return
    }
    # Fallback (script was not started from a file, so the engine text is unavailable): run on the GUI thread as v2.0 did.
    try {
        Invoke-MediaRefresh -Options $opts
        $res = $script:LastResult
        $msg = "Completed successfully.`n`nOutput: $($res.NewWim)"
        if ($res.Preflight) { $msg = 'Preflight passed. No image was changed. See the Log tab for the ISO roles, patch counts and selected edition.' }
        if ($null -ne $res.VerifyIssues -and $res.VerifyIssues -gt 0) { $msg = "Completed with $($res.VerifyIssues) verification issue(s). Review the Log tab.`n`nOutput: $($res.NewWim)" }
        [System.Windows.MessageBox]::Show($msg, 'WimForge', 'OK', 'Information') | Out-Null
    } catch {
        Write-Log $_.Exception.ToString() 'ERROR'
        Write-Log "At line $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())" 'ERROR'
        Set-Progress 0 'Failed'
        [System.Windows.MessageBox]::Show($_.Exception.Message, 'WimForge', 'OK', 'Error') | Out-Null
    } finally { Dismount-AllIso; $script:RunButton.IsEnabled = $true; $script:AcquirePatchesButton.IsEnabled = $true; $script:CancelButton.IsEnabled = $false }
})
$script:AcquirePatchesButton.Add_Click({
    # Step 5: always starts with a dry run (search only). Complete-BackgroundRun shows the results and asks for
    # confirmation before a second background run actually downloads anything.
    if (-not $script:RunButton.IsEnabled) { return }
    $opts = Get-UiOptions
    $opts | Add-Member -NotePropertyName Mode -NotePropertyValue 'Download' -Force
    $opts | Add-Member -NotePropertyName DryRun -NotePropertyValue $true -Force
    $script:PendingDownloadOptions = $opts
    $script:RunButton.IsEnabled = $false; $script:AcquirePatchesButton.IsEnabled = $false; $script:CancelButton.IsEnabled = $true
    $script:Cancelled = $false
    if ($script:EngineText) {
        try { Start-BackgroundRun -Options $opts }
        catch {
            $script:RunButton.IsEnabled = $true; $script:AcquirePatchesButton.IsEnabled = $true; $script:CancelButton.IsEnabled = $false
            [System.Windows.MessageBox]::Show("Could not start the catalog search: $($_.Exception.Message)", 'WimForge', 'OK', 'Error') | Out-Null
        }
    } else {
        $script:RunButton.IsEnabled = $true; $script:AcquirePatchesButton.IsEnabled = $true; $script:CancelButton.IsEnabled = $false
        [System.Windows.MessageBox]::Show('Downloading patches needs the script running from a file (the background engine text is unavailable).', 'WimForge', 'OK', 'Error') | Out-Null
    }
})
$script:CancelButton.Add_Click({
    $script:Cancelled = $true
    if ($script:RunShared) { $script:RunShared['Cancel'] = $true }
    $script:RunStatus = 'Cancellation requested. Stops at the next safe point; a running DISM operation must finish first.'
    $script:Status.Text = $script:RunStatus
})
$window.Add_Closing({ if (-not $script:RunButton.IsEnabled) { $_.Cancel = $true; [System.Windows.MessageBox]::Show('A servicing operation is active. Use Cancel and allow the current DISM operation to finish.', 'WimForge') | Out-Null } })
[void]$window.ShowDialog()
#endregion GUI
