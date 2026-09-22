#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Media Refresh Studio v2.1 - GUI offline servicing for Configuration Manager OSD WIMs.
.DESCRIPTION
    Mounts the OS ISO (plus optional Language Pack and FOD ISOs, detected by CONTENT, not file name),
    exports the configured client edition or preserves all Server indexes, services install.wim
    (and optionally WinRE / boot.wim), verifies the result, and can build a refreshed media folder
    (for OS Upgrade Packages) and an optional ISO.

    Servicing order for install.wim follows Microsoft's media Dynamic Update guidance:
      WinRE (once)  ->  SSU  ->  [LCU pass 1 -> language packs -> FODs/fonts when languages are selected]
      ->  LCU (final)  ->  component cleanup  ->  NetFx3 -> .NET CU  ->  export -> verify

.NOTES
    Version 2.1.0 (draft - test against non-production images first)
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

$script:ClientLpPattern = 'Microsoft-Windows-Client-Language-Pack_x64_{0}.cab'
$script:ServerLpPattern = 'Microsoft-Windows-Server-Language-Pack_x64_{0}.cab'
# Language -> font script capability (Language.Fonts.<Script>~~~und-<SCRIPT>~0.0.1.0)
$script:LangFontScripts = @{ 'ja-jp' = 'Jpan'; 'ko-kr' = 'Kore'; 'zh-cn' = 'Hans'; 'zh-tw' = 'Hant' }
$script:DefaultLanguageSet = @('de-de','en-gb','es-es','fr-fr','it-it','ja-jp','ko-kr','pt-br','zh-cn','zh-tw')

# Client matching is name-first and index-fallback. Adjust if Microsoft changes media naming.
# SsuRequired: the separate SSU must be present in PATCHES\SSU (legacy OSes). AltFolders: accepted folder names.
$script:OsDefinitions = [ordered]@{
    'Windows 10 Enterprise LTSC 2019 (IoT)' = [pscustomobject]@{
        Folder = 'Win10_Enterprise_LTSC_2019'; AltFolders = @(); ServiceAllIndexes = $false
        EditionRegex = '(?i)^Windows 10 (IoT )?Enterprise LTSC( 2019)?$'; PreferredIndex = 1
        LpPattern = $script:ClientLpPattern; SsuRequired = $true; DefaultLanguages = $script:DefaultLanguageSet
    }
    'Windows 10 IoT Enterprise LTSC 2021' = [pscustomobject]@{
        Folder = 'Win10_IoT_Enterprise_LTSC_2021'; AltFolders = @('Win10_IOT_Enterprise_LTSC_2021'); ServiceAllIndexes = $false
        EditionRegex = '(?i)^Windows 10 IoT Enterprise LTSC( 2021)?$'; PreferredIndex = 1
        LpPattern = $script:ClientLpPattern; SsuRequired = $true; DefaultLanguages = $script:DefaultLanguageSet
    }
    'Windows 10 Enterprise LTSC 2021 (KMS)' = [pscustomobject]@{
        Folder = 'Win10_Enterprise_LTSC_2021_KMS'; AltFolders = @(); ServiceAllIndexes = $false
        EditionRegex = '(?i)^Windows 10 Enterprise LTSC( 2021)?$'; PreferredIndex = 1
        LpPattern = $script:ClientLpPattern; SsuRequired = $true; DefaultLanguages = $script:DefaultLanguageSet
    }
    'Windows 11 Enterprise 24H2' = [pscustomobject]@{
        Folder = 'Win11_Enterprise_24H2'; AltFolders = @('Win11Enterprise_24H2'); ServiceAllIndexes = $false
        EditionRegex = '(?i)^Windows 11 Enterprise$'; PreferredIndex = 3
        LpPattern = $script:ClientLpPattern; SsuRequired = $false; DefaultLanguages = @()
    }
    'Windows Server 2022' = [pscustomobject]@{
        Folder = 'Windows_Server_2022'; AltFolders = @(); ServiceAllIndexes = $true
        EditionRegex = ''; PreferredIndex = 0
        LpPattern = $script:ServerLpPattern; SsuRequired = $false; DefaultLanguages = @()
    }
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
    param([Parameter(Mandatory)][string[]]$Arguments, [Parameter(Mandatory)][string]$Description, [switch]$AllowPending)
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

# ---------- packages ----------
function Get-PackageFiles {
    param([string]$Path, [string[]]$Extensions = @('.cab', '.msu'))
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    return @(Get-ChildItem -LiteralPath $Path -File -Recurse | Where-Object { $Extensions -contains $_.Extension.ToLowerInvariant() } | Sort-Object FullName)
}
function Get-PackageSet {
    param([string]$PatchRoot, [hashtable]$Enabled)
    $folders = [ordered]@{ LCU = 'LCU'; SSU = 'SSU'; NetCU = 'NETCU'; SafeOS = 'SAFEOSDU'; SetupDU = 'SETUPDU' }
    $set = @{}
    foreach ($k in $folders.Keys) {
        $ext = if ($k -eq 'SetupDU') { @('.cab') } else { @('.cab', '.msu') }
        $set[$k] = @( if ($Enabled[$k]) { Get-PackageFiles -Path (Join-Path $PatchRoot $folders[$k]) -Extensions $ext } )
    }
    return $set
}
function Test-PackageSet {
    param([pscustomobject]$Definition, [hashtable]$Packages, [hashtable]$Enabled, [bool]$DoWinRe, [bool]$BuildMedia)
    foreach ($k in @('SSU', 'LCU', 'NetCU', 'SafeOS', 'SetupDU')) {
        $state = if ($Enabled[$k]) { 'selected' } else { 'not selected' }
        Write-Log "$k packages: $(@($Packages[$k]).Count) ($state)"
    }
    if ($Enabled.LCU -and @($Packages.LCU).Count -eq 0) { throw 'Latest Cumulative Update is selected but PATCHES\LCU is empty. Add the LCU or untick it.' }
    if ($Enabled.SSU -and $Definition.SsuRequired -and @($Packages.SSU).Count -eq 0) { throw 'This OS needs its servicing stack update in PATCHES\SSU. Add it or untick Servicing Stack Update.' }
    if ($DoWinRe -and $Enabled.SafeOS -and @($Packages.SafeOS).Count -eq 0) { Write-Log 'WinRE servicing is on but PATCHES\SAFEOSDU is empty; WinRE will not get the Safe OS update.' 'WARN' }
    if ($BuildMedia -and $Enabled.SetupDU -and @($Packages.SetupDU).Count -eq 0) { Write-Log 'Refreshed media is requested but PATCHES\SETUPDU is empty; Setup files will not be updated.' 'WARN' }
}
function Add-Packages {
    param(
        [Parameter(Mandatory)][string]$MountPath,
        [AllowNull()][object[]]$Packages,
        [Parameter(Mandatory)][string]$Target,
        [string]$Label = 'package',
        [switch]$IgnoreCombinedLcu7007e
    )
    $dl = $script:DismLogArgs
    $list = @($Packages | Where-Object { $_ })
    if ($list.Count -eq 0) { Write-Log "No $Label packages to add to $Target (skipped)."; return }
    foreach ($pkg in $list) {
        Assert-NotCancelled
        Write-Log "Adding $Label $($pkg.FullName) to $Target"
        try { Add-WindowsPackage -Path $MountPath -PackagePath $pkg.FullName @dl -ErrorAction Stop | Out-Null }
        catch {
            if ($IgnoreCombinedLcu7007e -and $_.Exception.Message -match '0x8007007e') {
                Write-Log 'Known combined-LCU error 0x8007007e encountered; continuing.' 'WARN'
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
            $isFod = (Test-Path -LiteralPath (Join-Path $root 'LanguagesAndOptionalFeatures')) -or
                     [bool](Get-ChildItem -LiteralPath $root -Filter 'Microsoft-Windows-LanguageFeatures-*.cab' -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1)
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
    param([string]$LpRoot, [string]$Pattern, [string[]]$Languages)
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
function Find-WinPeOcRoot {
    param([string[]]$Drives)
    foreach ($d in @($Drives | Where-Object { $_ })) {
        $p = Join-Chain $d @('Windows Preinstallation Environment', 'x64', 'WinPE_OCs')
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

# ---------- languages ----------
function Add-OfflineLanguages {
    param([string]$MountPath, [hashtable]$LpFiles, [string[]]$FodSource, [string[]]$Languages, [string]$Target)
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
            } catch { Write-Log "Capability $cap was unavailable or not applicable: $($_.Exception.Message)" 'WARN' }
        }
    }
}
function Add-WinPeLanguages {
    param([string]$MountPath, [string]$OcRoot, [string[]]$Languages, [string]$Target)
    if (-not $OcRoot -or @($Languages).Count -eq 0) { return }
    foreach ($lang in @($Languages)) {
        $langRoot = Join-Path $OcRoot $lang
        $lp = Join-Path $langRoot 'lp.cab'
        if (Test-Path -LiteralPath $lp) { Add-Packages $MountPath @(Get-Item -LiteralPath $lp) $Target -Label "WinPE language pack $lang" }
        else { Write-Log "WinPE lp.cab for $lang was not found." 'WARN'; continue }
        $installed = @(Get-WindowsPackage -Path $MountPath)
        $langCabs = @(Get-ChildItem -LiteralPath $langRoot -Filter '*.cab' -File -ErrorAction SilentlyContinue)
        foreach ($pkg in $installed) {
            if ($pkg.PackageState -eq 'Installed' -and $pkg.PackageName.StartsWith('WinPE-') -and $pkg.ReleaseType -eq 'FeaturePack') {
                $pos = $pkg.PackageName.IndexOf('-Package')
                if ($pos -ge 0) {
                    $cabName = $pkg.PackageName.Substring(0, $pos) + '_' + $lang + '.cab'
                    $cab = $langCabs | Where-Object Name -eq $cabName | Select-Object -First 1
                    if ($cab) { Add-Packages $MountPath @($cab) $Target -Label "WinPE component $cabName" }
                }
            }
        }
        foreach ($name in @("WinPE-FontSupport-$lang.cab", 'WinPE-Speech-TTS.cab', "WinPE-Speech-TTS-$lang.cab")) {
            $cab = Join-Path $OcRoot $name
            if (Test-Path -LiteralPath $cab) { Add-Packages $MountPath @(Get-Item -LiteralPath $cab) $Target -Label "WinPE component $name" }
        }
    }
}

# ---------- servicing ----------
function Service-WinRe {
    # Extracts winre.wim from the currently mounted OS image, services it, and exports the result to $OutputPath.
    param([string]$OsMount, [string]$WinReMount, [string]$Temp, [string]$OutputPath, [hashtable]$Packages, [string]$OcRoot, [string[]]$Languages)
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
        Add-WinPeLanguages $WinReMount $OcRoot $Languages 'WinRE'
        Add-Packages $WinReMount $Packages.SafeOS 'WinRE' -Label 'Safe OS DU'
        Invoke-DismExe -Arguments @("/Image:$WinReMount", '/Cleanup-Image', '/StartComponentCleanup', '/ResetBase', '/Defer') -Description 'Cleaning WinRE'
        Dismount-WindowsImage -Path $WinReMount -Save -CheckIntegrity @dl -ErrorAction Stop | Out-Null
        Remove-Item -LiteralPath $OutputPath -Force -ErrorAction SilentlyContinue
        Export-WindowsImage -SourceImagePath $working -SourceIndex 1 -DestinationImagePath $OutputPath -CompressionType Max -CheckIntegrity @dl -ErrorAction Stop | Out-Null
        return $true
    } catch {
        Dismount-IfMounted $WinReMount
        throw
    }
}
function Service-InstallIndex {
    param([string]$ImagePath, [int]$Index, [hashtable]$Paths, [hashtable]$Packages, [string]$OsDrive,
          [hashtable]$LpFiles, [string[]]$FodSource, [string]$OcRoot, [string[]]$Languages, [bool]$DoWinRe, [bool]$DoNetFx3)
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
                [void](Service-WinRe -OsMount $Paths.MainMount -WinReMount $Paths.WinReMount -Temp $Paths.Temp -OutputPath $cache -Packages $Packages -OcRoot $OcRoot -Languages $Languages)
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

        # 6. .NET Framework 3.5, then the .NET cumulative update(s).
        if ($DoNetFx3) {
            $sxs = Join-Chain $OsDrive @('sources', 'sxs')
            Write-Log "Enabling NetFX3 from $sxs on $target"
            Enable-WindowsOptionalFeature -Path $Paths.MainMount -FeatureName NetFx3 -All -Source $sxs -LimitAccess @dl -ErrorAction Stop | Out-Null
        }
        Add-Packages $Paths.MainMount $Packages.NetCU $target -Label '.NET CU'

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
    param([string]$SourceBoot, [string]$Destination, [hashtable]$Paths, [hashtable]$Packages, [string]$OcRoot, [string[]]$Languages)
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
            if (@($Languages).Count -gt 0 -and $OcRoot) {
                Add-WinPeLanguages $Paths.WinPeMount $OcRoot $Languages $target
                if (Test-Path -LiteralPath (Join-Chain $Paths.WinPeMount @('sources', 'lang.ini'))) {
                    Invoke-DismExe -Arguments @("/Image:$($Paths.WinPeMount)", '/Gen-LangINI', "/Distribution:$($Paths.WinPeMount)") -Description "Regenerating lang.ini in $target"
                }
            }
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
    # Read-only mounts each index of the final WIM and logs what is really in it. Returns the number of issues.
    param([string]$WimPath, [hashtable]$Paths, [string[]]$Languages, [bool]$ExpectLcu)
    $dl = $script:DismLogArgs
    $issues = 0
    foreach ($img in @(Get-WindowsImage -ImagePath $WimPath)) {
        Assert-NotCancelled
        $detail = Get-WindowsImage -ImagePath $WimPath -Index $img.ImageIndex
        Write-Log ("VERIFY index {0} '{1}': image version {2}" -f $img.ImageIndex, $img.ImageName, $detail.Version)
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
            if (@($Languages).Count -gt 0) {
                $caps = @(Get-WindowsCapability -Path $Paths.MainMount @dl | Where-Object { $_.State -eq 'Installed' -and $_.Name -like 'Language.*' })
                Write-Log "VERIFY   language capabilities installed: $($caps.Count)"
                foreach ($lang in @($Languages)) {
                    if ($script:LangFontScripts.ContainsKey($lang)) {
                        $fs = $script:LangFontScripts[$lang]
                        if (-not @($caps | Where-Object { $_.Name -like "Language.Fonts.$fs~*" })) { Write-Log "VERIFY   font capability for $lang ($fs) is MISSING" 'WARN'; $issues++ }
                    }
                }
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
    $name = [string]$Options.OsName
    if (-not $name) { throw 'Select an operating system.' }
    $definition = $script:OsDefinitions[$name]
    if (-not $definition) { throw "Unknown OS profile '$name'." }
    $paths = Initialize-Repository -Root $Options.Root.Trim() -Definition $definition
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $script:LogFile = Join-Path $paths.Logs ("MediaRefresh_{0}.log" -f $stamp)
    $script:DismLogArgs = @{ LogPath = (Join-Path $paths.Logs ("DISM_{0}.log" -f $stamp)) }
    Write-Log "Starting Media Refresh Studio v2.1 for $name"
    Write-Log "Repository: $($paths.Root)"
    Write-Log "DISM log: $($script:DismLogArgs['LogPath'])"
    $dl = $script:DismLogArgs

    try {
        Clear-StaleMounts $paths.Root
        foreach ($d in @($paths.Working, $paths.Temp, $paths.WinRE, $paths.MainMount, $paths.WinReMount, $paths.WinPeMount)) { Remove-DirectoryContents $d }

        $languages = @($Options.Languages | Where-Object { $_ } | ForEach-Object { ([string]$_).ToLowerInvariant() })
        $hasLang = ($languages.Count -gt 0)
        Write-Log ('Languages: ' + $(if ($hasLang) { $languages -join ', ' } else { '(none - English only)' }))
        $enabled = @{ LCU = [bool]$Options.LCU; SSU = [bool]$Options.SSU; NetCU = [bool]$Options.NetCU; SafeOS = [bool]$Options.SafeOS; SetupDU = [bool]$Options.SetupDU }
        $packages = Get-PackageSet -PatchRoot $paths.Patches -Enabled $enabled
        Test-PackageSet -Definition $definition -Packages $packages -Enabled $enabled -DoWinRe ([bool]$Options.WinRE) -BuildMedia ([bool]$Options.BuildMedia)

        # ISO discovery by content
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
        $ocRoot = Find-WinPeOcRoot (@($roles.LpDrive) + @($roles.FodDrives))

        $lpFiles = @{}
        if ($hasLang) {
            if (-not $roles.LpDrive) { throw "Languages are selected but no Language Pack ISO (containing $($definition.LpPattern -f '<lang>')) is in $($paths.ISO)." }
            if (@($roles.FodDrives).Count -eq 0) { throw "Languages are selected but no Features on Demand ISO is in $($paths.ISO); language features and fonts need it. Add it or untick the languages." }
            $lpFiles = Resolve-LanguagePacks -LpRoot $roles.LpDrive -Pattern $definition.LpPattern -Languages $languages
            Write-Log "All $($languages.Count) language packs located."
            if (-not $ocRoot -and ([bool]$Options.WinRE -or [bool]$Options.Boot)) { Write-Log 'WinPE language cabs (Windows Preinstallation Environment\x64\WinPE_OCs) were not found on the LP/FOD ISOs; WinRE/boot.wim will not get languages.' 'WARN' }
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
        if ($Options.PreflightOnly) {
            Set-Progress 100 'Preflight passed'
            Write-Log 'PREFLIGHT OK: ISO roles, patch folders, language packs and edition selection all check out. No image was changed.'
            $script:LastResult = [pscustomobject]@{ NewWim = $paths.NewWim; Install = $null; Boot = $null; Media = $null; VerifyIssues = $null; Preflight = $true }
            return
        }
        $old = Join-Path $paths.OldWim 'install.wim'; Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue
        if ($definition.ServiceAllIndexes) {
            foreach ($img in $inventory) { Export-WindowsImage -SourceImagePath $sourceWim -SourceIndex $img.ImageIndex -DestinationImagePath $old -DestinationName $img.ImageName -CompressionType Max -CheckIntegrity @dl -ErrorAction Stop | Out-Null }
        } else {
            Export-WindowsImage -SourceImagePath $sourceWim -SourceIndex $selected.ImageIndex -DestinationImagePath $old -DestinationName $selected.ImageName -CompressionType Max -CheckIntegrity @dl -ErrorAction Stop | Out-Null
        }
        $first = Get-WindowsImage -ImagePath $old -Index (@(Get-WindowsImage -ImagePath $old)[0].ImageIndex)
        Test-DismHostVersion -ImageVersion $first.Version

        $workingInstall = Join-Path $paths.Working 'install.working.wim'; Copy-Item -LiteralPath $old -Destination $workingInstall -Force
        $finalInstall = $null; $finalBoot = $null; $verifyIssues = $null; $mediaFolder = $null
        if ($Options.Install) {
            $workImages = @(Get-WindowsImage -ImagePath $workingInstall)
            $n = 0
            foreach ($img in $workImages) {
                $n++; Set-Progress (15 + [int](45 * $n / $workImages.Count)) "Servicing install.wim index $($img.ImageIndex)"
                Service-InstallIndex -ImagePath $workingInstall -Index $img.ImageIndex -Paths $paths -Packages $packages -OsDrive $osDrive `
                    -LpFiles $lpFiles -FodSource $fodSource -OcRoot $ocRoot -Languages $languages -DoWinRe ([bool]$Options.WinRE) -DoNetFx3 ([bool]$Options.NetFx3)
            }
            $finalInstall = Join-Path $paths.NewWim 'install.wim'
            Set-Progress 65 'Optimizing final install.wim'
            Export-OptimizedWim $workingInstall $finalInstall
            $finalCount = @(Get-WindowsImage -ImagePath $finalInstall).Count
            if ((-not $definition.ServiceAllIndexes) -and $finalCount -ne 1) { throw "Client output validation failed: expected one index, found $finalCount." }
            Write-Log "Import-ready install.wim created: $finalInstall ($finalCount index(es))"
            if ($Options.Verify) {
                Set-Progress 68 'Verifying final install.wim'
                $verifyIssues = Test-OutputWim -WimPath $finalInstall -Paths $paths -Languages $languages -ExpectLcu $enabled.LCU
            }
        }

        if ($Options.Boot) {
            $sourceBoot = Join-Chain $osDrive @('sources', 'boot.wim')
            if (-not (Test-Path -LiteralPath $sourceBoot)) { throw "boot.wim not found at $sourceBoot" }
            Set-Progress 75 'Servicing boot.wim'
            $finalBoot = Join-Path $paths.NewWim 'boot.wim'
            Service-BootWim -SourceBoot $sourceBoot -Destination $finalBoot -Paths $paths -Packages $packages -OcRoot $ocRoot -Languages $languages
            Write-Log "Import-ready boot.wim created: $finalBoot"
        }
        if ($Options.BuildMedia -or $Options.BuildIso) {
            if (-not $finalInstall) { throw 'Refreshed media requires Create updated install.wim.' }
            Set-Progress 88 'Building refreshed media folder'
            $mediaFolder = New-RefreshedMedia -OsDrive $osDrive -Paths $paths -InstallWim $finalInstall -BootWim $finalBoot -SetupDu $packages.SetupDU
            if ($Options.BuildIso) { Set-Progress 94 'Building ISO'; Build-IsoFromMedia -MediaFolder $mediaFolder -Paths $paths }
        }
        Set-Progress 100 'Completed successfully'
        if ($null -ne $verifyIssues -and $verifyIssues -gt 0) { Write-Log "Media refresh finished, but verification reported $verifyIssues issue(s). Review the VERIFY lines above." 'WARN' }
        else { Write-Log 'Media refresh completed successfully.' }
        $script:LastResult = [pscustomobject]@{ NewWim = $paths.NewWim; Install = $finalInstall; Boot = $finalBoot; Media = $mediaFolder; VerifyIssues = $verifyIssues; Preflight = $false }
    } finally { Dismount-AllIso }
}
#endregion ENGINE

#region GUI
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="Media Refresh Studio v2.1" Height="780" Width="1040" WindowStartupLocation="CenterScreen" Background="#F4F6F8">
 <Grid Margin="18"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
  <StackPanel Grid.Row="0" Margin="0,0,0,12"><TextBlock Text="Configuration Manager OSD Media Refresh" FontSize="25" FontWeight="SemiBold"/><TextBlock Text="Create cleaned, optimized, verified install.wim files (and optional boot.wim, refreshed media folder and ISO)." Foreground="#555" Margin="0,4,0,0"/></StackPanel>
  <TabControl Grid.Row="1">
   <TabItem Header="Source and targets"><Grid Margin="18"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions><Grid.ColumnDefinitions><ColumnDefinition Width="220"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
    <TextBlock Grid.Row="0" Grid.Column="0" Text="Repository root" Margin="0,8"/><TextBox x:Name="RootText" Grid.Row="0" Grid.Column="1" Text="F:\mediaRefresh" Height="30" Padding="6"/>
    <TextBlock Grid.Row="1" Grid.Column="0" Text="Operating system" Margin="0,14,0,8"/><ComboBox x:Name="OsCombo" Grid.Row="1" Grid.Column="1" Height="32" Margin="0,8"/>
    <GroupBox Grid.Row="2" Grid.ColumnSpan="2" Header="Outputs" Margin="0,14,0,0"><StackPanel Margin="12"><CheckBox x:Name="ChkPreflight" Content="Preflight check only (about a minute: checks ISOs, patch folders, language packs and edition; changes nothing)" IsChecked="False" Margin="0,3"/><CheckBox x:Name="ChkInstall" Content="Create updated install.wim" IsChecked="True" Margin="0,3"/><CheckBox x:Name="ChkWinRE" Content="Service embedded WinRE (once, reused for every index)" IsChecked="True" Margin="0,3"/><CheckBox x:Name="ChkVerify" Content="Verify the final install.wim (read-only mount, logs RollupFix, language packs, fonts)" IsChecked="True" Margin="0,3"/><CheckBox x:Name="ChkBoot" Content="Create updated boot.wim (usually only needed per major CM update)" IsChecked="False" Margin="0,3"/><CheckBox x:Name="ChkBuildMedia" Content="Create refreshed media folder for an OS Upgrade Package (NEWWIM\Media)" IsChecked="False" Margin="0,3"/><CheckBox x:Name="ChkBuildIso" Content="Also build an ISO from that media (requires Windows ADK Oscdimg)" IsChecked="False" Margin="0,3"/></StackPanel></GroupBox>
    <TextBlock Grid.Row="3" Grid.ColumnSpan="2" Margin="0,18" TextWrapping="Wrap" Foreground="#555" Text="ISO roles (OS, Language Pack, Features on Demand) are detected from ISO content, so file names do not matter. Keep one ISO per role in the ISO folder. Client operating systems export a single index; Windows Server 2022 preserves and services every index."/>
   </Grid></TabItem>
   <TabItem Header="Updates and features"><Grid Margin="18"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
    <GroupBox Grid.Column="0" Header="Patch selection" Margin="0,0,10,0"><StackPanel Margin="12"><CheckBox x:Name="ChkSSU" Content="Servicing Stack Update (PATCHES\SSU)" IsChecked="True" Margin="0,5"/><CheckBox x:Name="ChkLCU" Content="Latest Cumulative Update (PATCHES\LCU)" IsChecked="True" Margin="0,5"/><CheckBox x:Name="ChkSafeOS" Content="Safe OS Dynamic Update (PATCHES\SAFEOSDU, used for WinRE)" IsChecked="True" Margin="0,5"/><CheckBox x:Name="ChkNetCU" Content=".NET Cumulative Update (PATCHES\NETCU)" IsChecked="True" Margin="0,5"/><CheckBox x:Name="ChkSetupDU" Content="Setup Dynamic Update (PATCHES\SETUPDU, used for refreshed media)" IsChecked="True" Margin="0,5"/></StackPanel></GroupBox>
    <GroupBox Grid.Column="1" Header="Optional content" Margin="10,0,0,0"><StackPanel Margin="12"><CheckBox x:Name="ChkNetFx3" Content="Enable .NET Framework 3.5 from OS ISO sources\sxs" IsChecked="False" Margin="0,5"/><TextBlock Text="Ticked patch types with an empty folder are logged and skipped, except LCU (and the SSU on legacy OSes), which stop the run so you never get an unpatched image by accident." TextWrapping="Wrap" Foreground="#555" Margin="0,16,0,0"/></StackPanel></GroupBox>
   </Grid></TabItem>
   <TabItem Header="Languages"><Grid Margin="18"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions><TextBlock Text="Language packs, language features and fonts to add. Requires a Language Pack ISO and a Features on Demand ISO. Leave empty for English only. Defaults follow the selected operating system." TextWrapping="Wrap"/><ListBox x:Name="LanguageList" Grid.Row="1" SelectionMode="Multiple" Margin="0,12,0,0"><ListBoxItem Content="de-de"/><ListBoxItem Content="en-gb"/><ListBoxItem Content="es-es"/><ListBoxItem Content="fr-fr"/><ListBoxItem Content="it-it"/><ListBoxItem Content="ja-jp"/><ListBoxItem Content="ko-kr"/><ListBoxItem Content="pt-br"/><ListBoxItem Content="zh-cn"/><ListBoxItem Content="zh-tw"/></ListBox></Grid></TabItem>
   <TabItem Header="Log"><TextBox x:Name="LogBox" Margin="12" IsReadOnly="True" AcceptsReturn="True" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" FontFamily="Consolas" FontSize="12" Background="#111827" Foreground="#E5E7EB"/></TabItem>
  </TabControl>
  <Grid Grid.Row="2" Margin="0,14,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><StackPanel><TextBlock x:Name="Status" Text="Ready"/><ProgressBar x:Name="Progress" Height="18" Minimum="0" Maximum="100" Margin="0,5,14,0"/></StackPanel><Button x:Name="RunButton" Grid.Column="1" Content="Start refresh" Width="130" Height="38" Margin="0,0,8,0" Background="#0078D4" Foreground="White" FontWeight="SemiBold"/><Button x:Name="CancelButton" Grid.Column="2" Content="Cancel" Width="90" Height="38" IsEnabled="False"/></Grid>
 </Grid>
</Window>
'@
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
foreach ($ctl in @('RootText','OsCombo','ChkPreflight','ChkInstall','ChkBoot','ChkWinRE','ChkVerify','ChkBuildMedia','ChkBuildIso','ChkSSU','ChkLCU','ChkSafeOS','ChkNetCU','ChkSetupDU','ChkNetFx3','LanguageList','LogBox','Status','Progress','RunButton','CancelButton')) {
    Set-Variable -Name $ctl -Value $window.FindName($ctl) -Scope Script
}
function Set-DefaultLanguages {
    $def = $script:OsDefinitions[[string]$script:OsCombo.SelectedItem]
    if (-not $def) { return }
    foreach ($item in $script:LanguageList.Items) { $item.IsSelected = (@($def.DefaultLanguages) -contains [string]$item.Content) }
}
function Get-UiOptions {
    $langs = @(foreach ($item in $script:LanguageList.Items) { if ($item.IsSelected) { [string]$item.Content } })
    return [pscustomobject]@{
        OsName = [string]$script:OsCombo.SelectedItem; Root = [string]$script:RootText.Text
        PreflightOnly = [bool]$script:ChkPreflight.IsChecked; Install = [bool]$script:ChkInstall.IsChecked; Boot = [bool]$script:ChkBoot.IsChecked; WinRE = [bool]$script:ChkWinRE.IsChecked
        Verify = [bool]$script:ChkVerify.IsChecked; BuildMedia = [bool]$script:ChkBuildMedia.IsChecked; BuildIso = [bool]$script:ChkBuildIso.IsChecked
        SSU = [bool]$script:ChkSSU.IsChecked; LCU = [bool]$script:ChkLCU.IsChecked; SafeOS = [bool]$script:ChkSafeOS.IsChecked
        NetCU = [bool]$script:ChkNetCU.IsChecked; SetupDU = [bool]$script:ChkSetupDU.IsChecked; NetFx3 = [bool]$script:ChkNetFx3.IsChecked
        Languages = $langs
    }
}
foreach ($osName in $script:OsDefinitions.Keys) { [void]$script:OsCombo.Items.Add($osName) }
$script:OsCombo.Add_SelectionChanged({ Set-DefaultLanguages })
$script:OsCombo.SelectedIndex = 0
Set-DefaultLanguages

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

$script:RunQueue = $null; $script:RunShared = $null; $script:RunPs = $null; $script:RunRs = $null; $script:RunHandle = $null
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
    $script:RunButton.IsEnabled = $true; $script:CancelButton.IsEnabled = $false
    $ok = ($shared.ContainsKey('Ok') -and $shared['Ok'])
    if ($ok) {
        $script:Status.Text = 'Done'; $script:Progress.Value = 100
        $res = $shared['Result']
        if ($null -eq $res) { $res = [pscustomobject]@{ NewWim = ''; Preflight = $false; VerifyIssues = $null } }
        $msg = "Completed successfully.`n`nOutput: $($res.NewWim)"
        if ($res.Preflight) { $msg = 'Preflight passed. No image was changed. See the Log tab for the ISO roles, patch counts and selected edition.' }
        if ($null -ne $res.VerifyIssues -and $res.VerifyIssues -gt 0) { $msg = "Completed with $($res.VerifyIssues) verification issue(s). Review the Log tab.`n`nOutput: $($res.NewWim)" }
        [System.Windows.MessageBox]::Show($msg, 'Media Refresh Studio', 'OK', 'Information') | Out-Null
    } else {
        $script:Status.Text = 'Failed'; $script:Progress.Value = 0
        $m = if ($shared.ContainsKey('Message') -and $shared['Message']) { [string]$shared['Message'] } elseif ($engineErrors.Count -gt 0) { [string]$engineErrors[0] } else { 'The servicing run ended unexpectedly. See the Log tab.' }
        $script:LogBox.AppendText("[ERROR] $m" + [Environment]::NewLine)
        [System.Windows.MessageBox]::Show($m, 'Media Refresh Studio', 'OK', 'Error') | Out-Null
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
$script:UiTimer.Add_Tick({ try { Update-RunUi } catch { $script:UiTimer.Stop(); [System.Windows.MessageBox]::Show("Display update failed: $($_.Exception.Message)`nThe run may still be active; check the log file in the OS LOGS folder.", 'Media Refresh Studio') | Out-Null } })

$script:RunButton.Add_Click({
    $script:RunButton.IsEnabled = $false; $script:CancelButton.IsEnabled = $true
    $opts = Get-UiOptions
    if ($script:EngineText) {
        try { Start-BackgroundRun -Options $opts }
        catch {
            $script:RunButton.IsEnabled = $true; $script:CancelButton.IsEnabled = $false
            [System.Windows.MessageBox]::Show("Could not start the background run: $($_.Exception.Message)", 'Media Refresh Studio', 'OK', 'Error') | Out-Null
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
        [System.Windows.MessageBox]::Show($msg, 'Media Refresh Studio', 'OK', 'Information') | Out-Null
    } catch {
        Write-Log $_.Exception.ToString() 'ERROR'
        Write-Log "At line $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())" 'ERROR'
        Set-Progress 0 'Failed'
        [System.Windows.MessageBox]::Show($_.Exception.Message, 'Media Refresh Studio', 'OK', 'Error') | Out-Null
    } finally { Dismount-AllIso; $script:RunButton.IsEnabled = $true; $script:CancelButton.IsEnabled = $false }
})
$script:CancelButton.Add_Click({
    $script:Cancelled = $true
    if ($script:RunShared) { $script:RunShared['Cancel'] = $true }
    $script:RunStatus = 'Cancellation requested. Stops at the next safe point; a running DISM operation must finish first.'
    $script:Status.Text = $script:RunStatus
})
$window.Add_Closing({ if (-not $script:RunButton.IsEnabled) { $_.Cancel = $true; [System.Windows.MessageBox]::Show('A servicing operation is active. Use Cancel and allow the current DISM operation to finish.', 'Media Refresh Studio') | Out-Null } })
[void]$window.ShowDialog()
#endregion GUI
