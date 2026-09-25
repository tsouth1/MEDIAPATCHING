#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Media Refresh Studio v1.0 - GUI offline servicing for Configuration Manager OSD WIMs.
.DESCRIPTION
    Mounts the selected OS ISO, inventories install.wim/install.esd, exports the configured
    client edition or preserves all Server 2022 indexes, services install.wim/WinRE/boot.wim,
    performs component cleanup, and creates optimized import-ready WIMs. ISO creation is optional.

    Repository root defaults to C:\mediaRefresh and can be changed in the GUI.
    Required per-OS folders are created automatically:
      ISO, PATCHES\LCU, PATCHES\SSU, PATCHES\NETCU, PATCHES\SAFEOSDU,
      PATCHES\SETUPDU, OLDWIM, NEWWIM, WINRE, WINPE, LOGS, MOUNT,
      TEMP, WORKING

.NOTES
	Version 1.0.1
	Added second pass LCU injection to Service-InstallIndex function to fix missing LCU after OS installation.
	Version: 1.0.0
    	Run on a supported Windows/ADK servicing workstation as Administrator.
	Keep only one OS ISO and, if needed, one matching FOD/language ISO in each ISO folder.
	Test output WIMs in a non-production Configuration Manager environment before deployment.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
Import-Module Dism -ErrorAction Stop

$script:MountedIsoPaths = [System.Collections.Generic.List[string]]::new()
$script:LogFile = $null
$script:Cancelled = $false

# Client matching is name-first and index-fallback. Adjust these values if Microsoft changes media naming.
$script:OsDefinitions = [ordered]@{
    'Windows 10 Enterprise LTSC 2019' = [pscustomobject]@{
        Folder = 'Win10_Enterprise_LTSC_2019'; ServiceAllIndexes = $false
        EditionRegex = '(?i)^Windows 10 Enterprise LTSC( 2019)?$'; PreferredIndex = 1
    }
    'Windows 10 IoT Enterprise LTSC 2021' = [pscustomobject]@{
        Folder = 'Win10_IoT_Enterprise_LTSC_2021'; ServiceAllIndexes = $false
        EditionRegex = '(?i)Windows 10 IoT Enterprise LTSC'; PreferredIndex = 1
    }
    'Windows 10 Enterprise LTSC 2021 (KMS)' = [pscustomobject]@{
        Folder = 'Win10_Enterprise_LTSC_2021_KMS'; ServiceAllIndexes = $false
        EditionRegex = '(?i)^Windows 10 Enterprise LTSC( 2021)?$'; PreferredIndex = 1
    }
    'Windows 11 Enterprise 24H2' = [pscustomobject]@{
        Folder = 'Win11_Enterprise_24H2'; ServiceAllIndexes = $false
        EditionRegex = '(?i)^Windows 11 Enterprise$'; PreferredIndex = 3
    }
    'Windows Server 2022' = [pscustomobject]@{
        Folder = 'Windows_Server_2022'; ServiceAllIndexes = $true
        EditionRegex = ''; PreferredIndex = 0
    }
}

function Get-TS { Get-Date -Format 'HH:mm:ss' }
function Write-Log {
    param([Parameter(Mandatory)][string]$Message, [ValidateSet('INFO','WARN','ERROR')][string]$Level='INFO')
    $line = '{0} [{1}] {2}' -f (Get-TS), $Level, $Message
    if ($script:LogFile) { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 }
    if ($script:LogBox) {
        $script:LogBox.AppendText($line + [Environment]::NewLine)
        $script:LogBox.ScrollToEnd()
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, 'Background')
    }
    Write-Host $line
}
function Set-Progress {
    param([int]$Percent,[string]$Status)
    $script:Progress.Value = [Math]::Max(0,[Math]::Min(100,$Percent))
    $script:Status.Text = $Status
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, 'Background')
}
function Assert-NotCancelled { if ($script:Cancelled) { throw 'Operation cancelled by user.' } }
function Ensure-Directory { param([string]$Path) if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null } }
function Remove-DirectoryContents {
    param([string]$Path)
    Ensure-Directory $Path
    Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction Stop
}
function Invoke-DismExe {
    param([Parameter(Mandatory)][string[]]$Arguments,[Parameter(Mandatory)][string]$Description,[switch]$AllowPending)
    Write-Log $Description
    & dism.exe @Arguments | ForEach-Object { if ($_ -and $_.Trim()) { Write-Log $_ } }
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        if ($AllowPending -and (($code -eq -2146498554) -or ($code -eq 0x800F0806))) {
            Write-Log "Cleanup reported CBS_E_PENDING ($code); continuing." 'WARN'
        } else { throw "$Description failed with exit code $code." }
    }
}
function Get-SingleFile {
    param([string]$Path,[string[]]$Filter,[string]$Description,[switch]$Optional)
    $items = foreach ($f in $Filter) { Get-ChildItem -LiteralPath $Path -Filter $f -File -ErrorAction SilentlyContinue }
    $items = @($items | Sort-Object FullName -Unique)
    if ($items.Count -eq 0) { if ($Optional) { return $null }; throw "No $Description found in $Path." }
    if ($items.Count -gt 1) { throw "Multiple $Description files found in $Path. Leave only the intended file." }
    return $items[0].FullName
}
function Get-PackageFiles {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    return @(Get-ChildItem -LiteralPath $Path -File -Recurse | Where-Object Extension -in '.cab','.msu' | Sort-Object FullName)
}
function Add-Packages {
    param([string]$MountPath,[System.IO.FileInfo[]]$Packages,[string]$Target,[switch]$IgnoreCombinedLcu7007e)
    foreach ($pkg in @($Packages)) {
        Assert-NotCancelled
        Write-Log "Adding $($pkg.FullName) to $Target"
        try { Add-WindowsPackage -Path $MountPath -PackagePath $pkg.FullName -ErrorAction Stop | Out-Null }
        catch {
            if ($IgnoreCombinedLcu7007e -and $_.Exception.Message -match '0x8007007e') {
                Write-Log 'Known combined-LCU error 0x8007007e encountered; continuing.' 'WARN'
            } else { throw }
        }
    }
}
function Mount-IsoFile {
    param([string]$ImagePath)
    Write-Log "Mounting ISO $ImagePath"
    $disk = Mount-DiskImage -ImagePath $ImagePath -PassThru -ErrorAction Stop
    $script:MountedIsoPaths.Add($ImagePath)
    $volume = $disk | Get-Volume | Where-Object DriveLetter | Select-Object -First 1
    if (-not $volume) { throw "Mounted ISO has no drive letter: $ImagePath" }
    return ($volume.DriveLetter + ':')
}
function Dismount-AllIso {
    foreach ($path in @($script:MountedIsoPaths)) {
        try { Dismount-DiskImage -ImagePath $path -ErrorAction Stop | Out-Null; Write-Log "Dismounted ISO $path" }
        catch { Write-Log "Could not dismount ISO ${path}: $($_.Exception.Message)" 'WARN' }
    }
    $script:MountedIsoPaths.Clear()
}
#function Get-SelectedLanguages {
#    $result = @()
#    foreach ($item in $script:LanguageList.Items) { if ($item.IsSelected) { $result += [string]$item.Content } }
#    return $result
#}

function Get-SelectedLanguages {
    $result = foreach ($item in $script:LanguageList.Items) {
        if ($item.IsSelected) {
            [string]$item.Content
        }
    }

    return ,$result
}

function Add-OfflineLanguages {
    param([string]$MountPath,[string]$FodPath,[string[]]$Languages,[string]$Target)
    if (-not $FodPath -or $Languages.Count -eq 0) { return }
    foreach ($lang in $Languages) {
        $lp = Get-ChildItem -LiteralPath $FodPath -Filter "Microsoft-Windows-Client-Language-Pack_x64_$lang.cab" -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($lp) { Add-Packages -MountPath $MountPath -Packages @($lp) -Target $Target }
        else { Write-Log "Language pack for $lang was not found on the FOD ISO." 'WARN' }
        foreach ($cap in @("Language.Basic~~~$lang~0.0.1.0","Language.OCR~~~$lang~0.0.1.0","Language.Handwriting~~~$lang~0.0.1.0","Language.TextToSpeech~~~$lang~0.0.1.0","Language.Speech~~~$lang~0.0.1.0")) {
            try {
                Write-Log "Adding capability $cap to $Target"
                Add-WindowsCapability -Name $cap -Path $MountPath -Source $FodPath -LimitAccess -ErrorAction Stop | Out-Null
            } catch { Write-Log "Capability $cap was unavailable or not applicable: $($_.Exception.Message)" 'WARN' }
        }
    }
}
function Add-WinPeLanguages {
    param([string]$MountPath,[string]$FodDrive,[string[]]$Languages,[string]$Target)
    if (-not $FodDrive -or $Languages.Count -eq 0) { return }
    $ocRoot = Join-Path $FodDrive 'Windows Preinstallation Environment\x64\WinPE_OCs'
    foreach ($lang in $Languages) {
        $langRoot = Join-Path $ocRoot $lang
        $lp = Join-Path $langRoot 'lp.cab'
        if (Test-Path -LiteralPath $lp) { Add-Packages -MountPath $MountPath -Packages @(Get-Item -LiteralPath $lp) -Target $Target }
        else { Write-Log "WinPE lp.cab for $lang was not found." 'WARN'; continue }
        $installed = Get-WindowsPackage -Path $MountPath
        $langCabs = @(Get-ChildItem -LiteralPath $langRoot -Filter '*.cab' -File -ErrorAction SilentlyContinue)
        foreach ($pkg in $installed) {
            if ($pkg.PackageState -eq 'Installed' -and $pkg.PackageName.StartsWith('WinPE-') -and $pkg.ReleaseType -eq 'FeaturePack') {
                $pos = $pkg.PackageName.IndexOf('-Package')
                if ($pos -ge 0) {
                    $cabName = $pkg.PackageName.Substring(0,$pos) + '_' + $lang + '.cab'
                    $cab = $langCabs | Where-Object Name -eq $cabName | Select-Object -First 1
                    if ($cab) { Add-Packages -MountPath $MountPath -Packages @($cab) -Target $Target }
                }
            }
        }
        foreach ($pattern in @("WinPE-FontSupport-$lang.cab","WinPE-Speech-TTS.cab","WinPE-Speech-TTS-$lang.cab")) {
            $cab = Join-Path $ocRoot $pattern
            if (Test-Path -LiteralPath $cab) { Add-Packages -MountPath $MountPath -Packages @(Get-Item -LiteralPath $cab) -Target $Target }
        }
    }
}
function Service-WinRe {
    param([string]$OsMount,[string]$WinReMount,[string]$Temp,[System.IO.FileInfo[]]$Ssu,[System.IO.FileInfo[]]$Lcu,[System.IO.FileInfo[]]$SafeOs,[string]$FodDrive,[string[]]$Languages)
    $embedded = Join-Path $OsMount 'Windows\System32\Recovery\winre.wim'
    if (-not (Test-Path -LiteralPath $embedded)) { Write-Log "No WinRE image found at $embedded" 'WARN'; return }
    Remove-DirectoryContents $WinReMount
    $working = Join-Path $Temp 'winre.wim'
    $optimized = Join-Path $Temp 'winre.optimized.wim'
    Remove-Item -LiteralPath $working,$optimized -Force -ErrorAction SilentlyContinue
    Copy-Item -LiteralPath $embedded -Destination $working -Force
    try {
        Mount-WindowsImage -ImagePath $working -Index 1 -Path $WinReMount -CheckIntegrity -ErrorAction Stop | Out-Null
        Add-Packages $WinReMount $Ssu 'WinRE' -IgnoreCombinedLcu7007e
        Add-Packages $WinReMount $Lcu 'WinRE' -IgnoreCombinedLcu7007e
        Add-WinPeLanguages $WinReMount $FodDrive $Languages 'WinRE'
        Add-Packages $WinReMount $SafeOs 'WinRE'
        Invoke-DismExe -Arguments @("/Image:$WinReMount",'/Cleanup-Image','/StartComponentCleanup','/ResetBase','/Defer') -Description 'Cleaning WinRE'
        Dismount-WindowsImage -Path $WinReMount -Save -CheckIntegrity -ErrorAction Stop | Out-Null
        Export-WindowsImage -SourceImagePath $working -SourceIndex 1 -DestinationImagePath $optimized -CompressionType Max -CheckIntegrity -ErrorAction Stop | Out-Null
        Copy-Item -LiteralPath $optimized -Destination $embedded -Force
    } catch {
        if ((Get-WindowsImage -Mounted | Where-Object Path -eq $WinReMount)) { Dismount-WindowsImage -Path $WinReMount -Discard -ErrorAction SilentlyContinue | Out-Null }
        throw
    }
}
function Service-InstallIndex {
    param([string]$ImagePath,[int]$Index,[hashtable]$Paths,[hashtable]$Packages,[string]$OsDrive,[string]$FodDrive,[string]$FodPath,[string[]]$Languages,[bool]$DoWinRe,[bool]$DoNetFx3)
    Remove-DirectoryContents $Paths.MainMount
    Write-Log "Mounting install image index $Index"
    try {
        Mount-WindowsImage -ImagePath $ImagePath -Index $Index -Path $Paths.MainMount -CheckIntegrity -ErrorAction Stop | Out-Null
        if ($DoWinRe) { Service-WinRe -OsMount $Paths.MainMount -WinReMount $Paths.WinReMount -Temp $Paths.Temp -Ssu $Packages.SSU -Lcu $Packages.LCU -SafeOs $Packages.SafeOS -FodDrive $FodDrive -Languages $Languages }
        Add-Packages $Paths.MainMount $Packages.SSU "install.wim index $Index"
        Add-Packages $Paths.MainMount $Packages.LCU "install.wim index $Index"
        Add-OfflineLanguages $Paths.MainMount $FodPath $Languages "install.wim index $Index"
        if ($DoNetFx3) {
            $sxs = Join-Path $OsDrive 'sources\sxs'
            Write-Log "Enabling NetFX3 from $sxs on install.wim index $Index"
            Enable-WindowsOptionalFeature -Path $Paths.MainMount -FeatureName NetFx3 -All -Source $sxs -LimitAccess -ErrorAction Stop | Out-Null
        }
        Add-Packages $Paths.MainMount $Packages.NetCU "install.wim index $Index"
        Add-Packages $Paths.MainMount $Packages.LCU "install.wim index $Index"
        Invoke-DismExe -Arguments @("/Image:$($Paths.MainMount)",'/Cleanup-Image','/StartComponentCleanup') -Description "Component cleanup on install.wim index $Index" -AllowPending
        Dismount-WindowsImage -Path $Paths.MainMount -Save -CheckIntegrity -ErrorAction Stop | Out-Null
    } catch {
        if ((Get-WindowsImage -Mounted | Where-Object Path -eq $Paths.MainMount)) { Dismount-WindowsImage -Path $Paths.MainMount -Discard -ErrorAction SilentlyContinue | Out-Null }
        throw
    }
}
function Export-OptimizedWim {
    param([string]$Source,[string]$Destination)
    Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
    $images = @(Get-WindowsImage -ImagePath $Source)
    foreach ($image in $images) {
        Write-Log "Final optimized export: index $($image.ImageIndex), $($image.ImageName)"
        Export-WindowsImage -SourceImagePath $Source -SourceIndex $image.ImageIndex -DestinationImagePath $Destination -DestinationName $image.ImageName -CompressionType Max -CheckIntegrity -ErrorAction Stop | Out-Null
    }
}
function Service-BootWim {
    param([string]$SourceBoot,[string]$Destination,[hashtable]$Paths,[hashtable]$Packages,[string]$FodDrive,[string[]]$Languages)
    $working = Join-Path $Paths.Working 'boot.working.wim'
    $optimized = Join-Path $Paths.Temp 'boot.optimized.wim'
    Copy-Item -LiteralPath $SourceBoot -Destination $working -Force
    $images = @(Get-WindowsImage -ImagePath $working)
    foreach ($image in $images) {
        Remove-DirectoryContents $Paths.WinPeMount
        Write-Log "Mounting boot.wim index $($image.ImageIndex)"
        try {
            Mount-WindowsImage -ImagePath $working -Index $image.ImageIndex -Path $Paths.WinPeMount -CheckIntegrity -ErrorAction Stop | Out-Null
            Add-Packages $Paths.WinPeMount $Packages.SSU "boot.wim index $($image.ImageIndex)" -IgnoreCombinedLcu7007e
            Add-Packages $Paths.WinPeMount $Packages.LCU "boot.wim index $($image.ImageIndex)" -IgnoreCombinedLcu7007e
            Add-WinPeLanguages $Paths.WinPeMount $FodDrive $Languages "boot.wim index $($image.ImageIndex)"
            Invoke-DismExe -Arguments @("/Image:$($Paths.WinPeMount)",'/Cleanup-Image','/StartComponentCleanup','/ResetBase','/Defer') -Description "Cleaning boot.wim index $($image.ImageIndex)"
            Dismount-WindowsImage -Path $Paths.WinPeMount -Save -CheckIntegrity -ErrorAction Stop | Out-Null
        } catch {
            if ((Get-WindowsImage -Mounted | Where-Object Path -eq $Paths.WinPeMount)) { Dismount-WindowsImage -Path $Paths.WinPeMount -Discard -ErrorAction SilentlyContinue | Out-Null }
            throw
        }
    }
    Remove-Item -LiteralPath $optimized -Force -ErrorAction SilentlyContinue
    foreach ($image in @(Get-WindowsImage -ImagePath $working)) {
        Export-WindowsImage -SourceImagePath $working -SourceIndex $image.ImageIndex -DestinationImagePath $optimized -DestinationName $image.ImageName -CompressionType Max -CheckIntegrity -ErrorAction Stop | Out-Null
    }
    Copy-Item -LiteralPath $optimized -Destination $Destination -Force
}
function Build-UpdatedIso {
    param([string]$OsDrive,[hashtable]$Paths,[string]$InstallWim,[string]$BootWim,[System.IO.FileInfo[]]$SetupDu)
    $media = Join-Path $Paths.Working 'Media'
    Remove-DirectoryContents $media
    Write-Log 'Copying mounted OS media for optional ISO build.'
    Copy-Item -Path (Join-Path $OsDrive '*') -Destination $media -Recurse -Force
    Get-ChildItem -LiteralPath $media -Recurse -File | ForEach-Object { $_.IsReadOnly = $false }
    Copy-Item -LiteralPath $InstallWim -Destination (Join-Path $media 'sources\install.wim') -Force
    $esd = Join-Path $media 'sources\install.esd'; if (Test-Path -LiteralPath $esd) { Remove-Item -LiteralPath $esd -Force }
    if ($BootWim -and (Test-Path -LiteralPath $BootWim)) { Copy-Item -LiteralPath $BootWim -Destination (Join-Path $media 'sources\boot.wim') -Force }
    foreach ($du in @($SetupDu)) {
        Write-Log "Expanding Setup DU $($du.FullName)"
        & "$env:SystemRoot\System32\expand.exe" $du.FullName '-F:*' (Join-Path $media 'sources') | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Setup DU expansion failed with exit code $LASTEXITCODE." }
    }
    $oscdimg = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools" -Filter oscdimg.exe -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $oscdimg) { throw 'Oscdimg.exe was not found. Install the Windows ADK Deployment Tools.' }
    $bios = Join-Path $media 'boot\etfsboot.com'; $uefi = Join-Path $media 'efi\microsoft\boot\efisys.bin'
    if (-not (Test-Path $bios) -or -not (Test-Path $uefi)) { throw 'Required BIOS or UEFI boot sector files were not found in the media.' }
    $isoOut = Join-Path $Paths.NewWim ("UpdatedMedia_{0}.iso" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $bootData = "-bootdata:2#p0,e,b$bios#pEF,e,b$uefi"
    Write-Log "Building optional ISO $isoOut"
    & $oscdimg.FullName '-m' '-o' '-u2' '-udfver102' $bootData $media $isoOut | ForEach-Object { Write-Log $_ }
    if ($LASTEXITCODE -ne 0) { throw "Oscdimg failed with exit code $LASTEXITCODE." }
}
function Initialize-Repository {
    param([string]$Root,[pscustomobject]$Definition)
    $osRoot = Join-Path $Root $Definition.Folder
    $p = @{
        Root=$osRoot; ISO=(Join-Path $osRoot 'ISO'); Patches=(Join-Path $osRoot 'PATCHES')
        OldWim=(Join-Path $osRoot 'OLDWIM'); NewWim=(Join-Path $osRoot 'NEWWIM')
        Working=(Join-Path $osRoot 'WORKING'); Temp=(Join-Path $osRoot 'TEMP')
        Logs=(Join-Path $osRoot 'LOGS'); MainMount=(Join-Path $osRoot 'MOUNT\MainOS')
        WinReMount=(Join-Path $osRoot 'MOUNT\WinRE'); WinPeMount=(Join-Path $osRoot 'MOUNT\WinPE')
        WinRE=(Join-Path $osRoot 'WINRE'); WinPE=(Join-Path $osRoot 'WINPE')
    }
    foreach ($dir in @($p.Values) + @('LCU','SSU','NETCU','SAFEOSDU','SETUPDU' | ForEach-Object { Join-Path $p.Patches $_ })) { Ensure-Directory $dir }
    return $p
}
function Invoke-MediaRefresh {
    $script:Cancelled = $false
    $name = [string]$script:OsCombo.SelectedItem
    if (-not $name) { throw 'Select an operating system.' }
    $definition = $script:OsDefinitions[$name]
    $paths = Initialize-Repository -Root $script:RootText.Text.Trim() -Definition $definition
    $script:LogFile = Join-Path $paths.Logs ("MediaRefresh_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    Write-Log "Starting Media Refresh Studio v1.0 for $name"
    Write-Log "Repository: $($paths.Root)"
    Remove-DirectoryContents $paths.Working; Remove-DirectoryContents $paths.Temp
    foreach ($m in @($paths.MainMount,$paths.WinReMount,$paths.WinPeMount)) { Remove-DirectoryContents $m }

    $isoFiles = @(Get-ChildItem -LiteralPath $paths.ISO -Filter '*.iso' -File)
    $fodCandidates = @($isoFiles | Where-Object Name -match '(?i)(FOD|LOF|Language|Features.On.Demand)')
    $osCandidates = @($isoFiles | Where-Object FullName -notin $fodCandidates.FullName)
    if ($osCandidates.Count -ne 1) { throw "Expected exactly one OS ISO in $($paths.ISO); found $($osCandidates.Count)." }
    #$needFod = ((Get-SelectedLanguages).Count -gt 0)
    $needFod = @((Get-SelectedLanguages).Count -gt 0)
    if ($needFod -and $fodCandidates.Count -ne 1) { throw "Language servicing requires exactly one FOD/language ISO in $($paths.ISO)." }

    $packages = @{
        LCU = if ($script:ChkLCU.IsChecked) { Get-PackageFiles (Join-Path $paths.Patches 'LCU') } else { @() }
        SSU = if ($script:ChkSSU.IsChecked) { Get-PackageFiles (Join-Path $paths.Patches 'SSU') } else { @() }
        NetCU = if ($script:ChkNetCU.IsChecked) { Get-PackageFiles (Join-Path $paths.Patches 'NETCU') } else { @() }
        SafeOS = if ($script:ChkSafeOS.IsChecked) { Get-PackageFiles (Join-Path $paths.Patches 'SAFEOSDU') } else { @() }
        SetupDU = if ($script:ChkSetupDU.IsChecked) { Get-PackageFiles (Join-Path $paths.Patches 'SETUPDU') } else { @() }
    }
    foreach ($key in @('LCU','SSU','NetCU','SafeOS','SetupDU')) { Write-Log "$key package count: $(@($packages[$key]).Count)" }
    $languages = Get-SelectedLanguages
    Set-Progress 5 'Mounting source media'
    $osDrive = Mount-IsoFile $osCandidates[0].FullName
    $fodDrive = $null; $fodPath = $null
    if ($fodCandidates.Count -eq 1 -and ($needFod -or $script:ChkMountFod.IsChecked)) {
        $fodDrive = Mount-IsoFile $fodCandidates[0].FullName
        $candidate = Join-Path $fodDrive 'LanguagesAndOptionalFeatures'
        $fodPath = if (Test-Path -LiteralPath $candidate) { $candidate } else { $fodDrive }
    }
    try {
        $sourceWim = if (Test-Path (Join-Path $osDrive 'sources\install.wim')) { Join-Path $osDrive 'sources\install.wim' } elseif (Test-Path (Join-Path $osDrive 'sources\install.esd')) { Join-Path $osDrive 'sources\install.esd' } else { throw 'Neither sources\install.wim nor sources\install.esd exists on the OS ISO.' }
        $inventory = @(Get-WindowsImage -ImagePath $sourceWim)
        Write-Log ('Detected indexes: ' + (($inventory | ForEach-Object { "[$($_.ImageIndex)] $($_.ImageName)" }) -join '; '))
        $old = Join-Path $paths.OldWim 'install.wim'; Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue
        if ($definition.ServiceAllIndexes) {
            foreach ($img in $inventory) { Export-WindowsImage -SourceImagePath $sourceWim -SourceIndex $img.ImageIndex -DestinationImagePath $old -DestinationName $img.ImageName -CompressionType Max -CheckIntegrity -ErrorAction Stop | Out-Null }
        } else {
            $matches = @($inventory | Where-Object ImageName -match $definition.EditionRegex)
            if ($matches.Count -gt 1) { throw "Edition pattern matched multiple images: $($matches.ImageName -join ', '). Adjust OsDefinitions." }
            $selected = if ($matches.Count -eq 1) { $matches[0] } else { $inventory | Where-Object ImageIndex -eq $definition.PreferredIndex | Select-Object -First 1 }
            if (-not $selected) { throw "No edition matched '$($definition.EditionRegex)' and preferred index $($definition.PreferredIndex) is unavailable." }
            Write-Log "Selected client image index $($selected.ImageIndex): $($selected.ImageName)"
            Export-WindowsImage -SourceImagePath $sourceWim -SourceIndex $selected.ImageIndex -DestinationImagePath $old -DestinationName $selected.ImageName -CompressionType Max -CheckIntegrity -ErrorAction Stop | Out-Null
        }
        $workingInstall = Join-Path $paths.Working 'install.working.wim'; Copy-Item -LiteralPath $old -Destination $workingInstall -Force
        if ($script:ChkInstall.IsChecked) {
            $workImages = @(Get-WindowsImage -ImagePath $workingInstall)
            $n=0
            foreach ($img in $workImages) {
                $n++; Set-Progress (15 + [int](45*$n/$workImages.Count)) "Servicing install.wim index $($img.ImageIndex)"
                Service-InstallIndex -ImagePath $workingInstall -Index $img.ImageIndex -Paths $paths -Packages $packages -OsDrive $osDrive -FodDrive $fodDrive -FodPath $fodPath -Languages $languages -DoWinRe ([bool]$script:ChkWinRE.IsChecked) -DoNetFx3 ([bool]$script:ChkNetFx3.IsChecked)
            }
            $finalInstall = Join-Path $paths.NewWim 'install.wim'
            Set-Progress 65 'Optimizing final install.wim'
            Export-OptimizedWim $workingInstall $finalInstall
            $finalCount = @(Get-WindowsImage -ImagePath $finalInstall).Count
            if ((-not $definition.ServiceAllIndexes) -and $finalCount -ne 1) { throw "Client output validation failed: expected one index, found $finalCount." }
            Write-Log "Import-ready install.wim created: $finalInstall ($finalCount index(es))"
        } else { $finalInstall = $null }

        $finalBoot = $null
        if ($script:ChkBoot.IsChecked) {
            $sourceBoot = Join-Path $osDrive 'sources\boot.wim'
            if (-not (Test-Path -LiteralPath $sourceBoot)) { throw "boot.wim not found at $sourceBoot" }
            Set-Progress 70 'Servicing boot.wim'
            $finalBoot = Join-Path $paths.NewWim 'boot.wim'
            Service-BootWim -SourceBoot $sourceBoot -Destination $finalBoot -Paths $paths -Packages $packages -FodDrive $fodDrive -Languages $languages
            Write-Log "Import-ready boot.wim created: $finalBoot"
        }
        if ($script:ChkBuildIso.IsChecked) {
            if (-not $finalInstall) { throw 'Build ISO requires Create updated install.wim.' }
            Set-Progress 90 'Building optional ISO'
            Build-UpdatedIso -OsDrive $osDrive -Paths $paths -InstallWim $finalInstall -BootWim $finalBoot -SetupDu $packages.SetupDU
        }
        Set-Progress 100 'Completed successfully'
        Write-Log 'Media refresh completed successfully.'
        [System.Windows.MessageBox]::Show("Completed successfully.`n`nOutput: $($paths.NewWim)",'Media Refresh Studio','OK','Information') | Out-Null
    } finally { Dismount-AllIso }
}

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="Media Refresh Studio v1.0" Height="760" Width="1040" WindowStartupLocation="CenterScreen" Background="#F4F6F8">
 <Grid Margin="18"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
  <StackPanel Grid.Row="0" Margin="0,0,0,12"><TextBlock Text="Configuration Manager OSD Media Refresh" FontSize="25" FontWeight="SemiBold"/><TextBlock Text="Create cleaned, optimized, import-ready install.wim and boot.wim files. ISO creation is optional." Foreground="#555" Margin="0,4,0,0"/></StackPanel>
  <TabControl Grid.Row="1">
   <TabItem Header="Source and targets"><Grid Margin="18"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions><Grid.ColumnDefinitions><ColumnDefinition Width="220"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
    <TextBlock Grid.Row="0" Grid.Column="0" Text="Repository root" Margin="0,8"/><TextBox x:Name="RootText" Grid.Row="0" Grid.Column="1" Text="F:\mediaRefresh" Height="30" Padding="6"/>
    <TextBlock Grid.Row="1" Grid.Column="0" Text="Operating system" Margin="0,14,0,8"/><ComboBox x:Name="OsCombo" Grid.Row="1" Grid.Column="1" Height="32" Margin="0,8"/>
    <GroupBox Grid.Row="2" Grid.ColumnSpan="2" Header="Primary outputs" Margin="0,14,0,0"><StackPanel Margin="12"><CheckBox x:Name="ChkInstall" Content="Create updated install.wim" IsChecked="True" Margin="0,3"/><CheckBox x:Name="ChkBoot" Content="Create updated boot.wim" IsChecked="True" Margin="0,3"/><CheckBox x:Name="ChkWinRE" Content="Service embedded WinRE" IsChecked="True" Margin="0,3"/><CheckBox x:Name="ChkBuildIso" Content="Build updated ISO (optional, requires Windows ADK Oscdimg)" IsChecked="False" Margin="0,3"/></StackPanel></GroupBox>
    <TextBlock Grid.Row="3" Grid.ColumnSpan="2" Margin="0,18" TextWrapping="Wrap" Foreground="#555" Text="Client operating systems are exported as a single index. Windows Server 2022 preserves and services every source index. OLDWIM stores the clean ISO export; NEWWIM stores the final optimized outputs."/>
   </Grid></TabItem>
   <TabItem Header="Updates and features"><Grid Margin="18"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
    <GroupBox Grid.Column="0" Header="Patch selection" Margin="0,0,10,0"><StackPanel Margin="12"><CheckBox x:Name="ChkSSU" Content="Servicing Stack Update" IsChecked="True" Margin="0,5"/><CheckBox x:Name="ChkLCU" Content="Latest Cumulative Update" IsChecked="True" Margin="0,5"/><CheckBox x:Name="ChkSafeOS" Content="Safe OS Dynamic Update" IsChecked="True" Margin="0,5"/><CheckBox x:Name="ChkNetCU" Content=".NET Cumulative Update" IsChecked="True" Margin="0,5"/><CheckBox x:Name="ChkSetupDU" Content="Setup Dynamic Update (used only when building ISO)" IsChecked="True" Margin="0,5"/></StackPanel></GroupBox>
    <GroupBox Grid.Column="1" Header="Optional content" Margin="10,0,0,0"><StackPanel Margin="12"><CheckBox x:Name="ChkNetFx3" Content="Enable .NET Framework 3.5 from OS ISO sources\sxs" IsChecked="False" Margin="0,5"/><CheckBox x:Name="ChkMountFod" Content="Mount FOD ISO even when no languages are selected" IsChecked="False" Margin="0,5"/><TextBlock Text="Package files are discovered recursively in their PATCHES subfolders. Empty selected folders are logged and skipped." TextWrapping="Wrap" Foreground="#555" Margin="0,16,0,0"/></StackPanel></GroupBox>
   </Grid></TabItem>
   <TabItem Header="Languages"><Grid Margin="18"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions><TextBlock Text="Select language packs and language capabilities to add from the matching FOD/language ISO." TextWrapping="Wrap"/><ListBox x:Name="LanguageList" Grid.Row="1" SelectionMode="Multiple" Margin="0,12,0,0"><ListBoxItem Content="de-de"/><ListBoxItem Content="en-gb"/><ListBoxItem Content="es-es"/><ListBoxItem Content="fr-fr"/><ListBoxItem Content="it-it"/><ListBoxItem Content="ja-jp"/><ListBoxItem Content="ko-kr"/><ListBoxItem Content="pt-br"/><ListBoxItem Content="zh-cn"/><ListBoxItem Content="zh-tw"/></ListBox></Grid></TabItem>
   <TabItem Header="Log"><TextBox x:Name="LogBox" Margin="12" IsReadOnly="True" AcceptsReturn="True" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" FontFamily="Consolas" FontSize="12" Background="#111827" Foreground="#E5E7EB"/></TabItem>
  </TabControl>
  <Grid Grid.Row="2" Margin="0,14,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><StackPanel><TextBlock x:Name="Status" Text="Ready"/><ProgressBar x:Name="Progress" Height="18" Minimum="0" Maximum="100" Margin="0,5,14,0"/></StackPanel><Button x:Name="RunButton" Grid.Column="1" Content="Start refresh" Width="130" Height="38" Margin="0,0,8,0" Background="#0078D4" Foreground="White" FontWeight="SemiBold"/><Button x:Name="CancelButton" Grid.Column="2" Content="Cancel" Width="90" Height="38" IsEnabled="False"/></Grid>
 </Grid>
</Window>
'@
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
foreach ($name in @('RootText','OsCombo','ChkInstall','ChkBoot','ChkWinRE','ChkBuildIso','ChkSSU','ChkLCU','ChkSafeOS','ChkNetCU','ChkSetupDU','ChkNetFx3','ChkMountFod','LanguageList','LogBox','Status','Progress','RunButton','CancelButton')) { Set-Variable -Name $name -Value $window.FindName($name) -Scope Script }
foreach ($name in $script:OsDefinitions.Keys) { [void]$script:OsCombo.Items.Add($name) }; $script:OsCombo.SelectedIndex = 0
$script:RunButton.Add_Click({
    $script:RunButton.IsEnabled=$false; $script:CancelButton.IsEnabled=$true
    try { Invoke-MediaRefresh }
    #catch { Write-Log $_.Exception.ToString() 'ERROR'; Set-Progress 0 'Failed'; [System.Windows.MessageBox]::Show($_.Exception.Message,'Media Refresh Studio','OK','Error') | Out-Null }
    catch {
    Write-Log $_.Exception.ToString() 'ERROR'
    Write-Log "Line Number: $($_.InvocationInfo.ScriptLineNumber)" 'ERROR'
    Write-Log "Offset: $($_.InvocationInfo.OffsetInLine)" 'ERROR'
    Write-Log "Line: $($_.InvocationInfo.Line)" 'ERROR'

    Set-Progress 0 'Failed'

    [System.Windows.MessageBox]::Show(
        $_.Exception.Message,
        'Media Refresh Studio',
        'OK',
        'Error'
    ) | Out-Null
}
    finally { Dismount-AllIso; $script:RunButton.IsEnabled=$true; $script:CancelButton.IsEnabled=$false }
})
$script:CancelButton.Add_Click({ $script:Cancelled=$true; $script:Status.Text='Cancellation requested. Current DISM operation must finish first.' })
$window.Add_Closing({ if (-not $script:RunButton.IsEnabled) { $_.Cancel=$true; [System.Windows.MessageBox]::Show('A servicing operation is active. Use Cancel and allow the current DISM operation to finish.','Media Refresh Studio') | Out-Null } })
[void]$window.ShowDialog()