# Step 5 (acquisition layer) checks: profile catalogSearch parsing + the download engine functions, all mocked -
# no real network access, no real MSCatalogLTS module, no real DISM/ISO mount.
. ./mocks.ps1

$pass = 0; $fail = 0
function Check($name, [bool]$ok, $detail = '') { if ($ok) { $script:pass++; Write-Host "PASS  $name" -ForegroundColor Green } else { $script:fail++; Write-Host "FAIL  $name  $detail" -ForegroundColor Red } }
function Reset-Test { $script:Calls.Clear(); $script:MountedList = @(); $script:MountedIsoPaths.Clear() }

# ---- extra mocks: catalog module + Get-MSCatalogUpdate/Save-MSCatalogUpdate + ISO mount ----
$script:CatalogModuleInstalled = $true
function Get-Module { [CmdletBinding()] param([string]$Name, [switch]$ListAvailable) if ($Name -eq 'MSCatalogLTS' -and $script:CatalogModuleInstalled) { return [pscustomobject]@{ Name = 'MSCatalogLTS' } }; return $null }
function Import-Module { [CmdletBinding()] param($Name) Note "ImportModule $Name" }
function Get-PackageProvider { [CmdletBinding()] param($Name, [switch]$ListAvailable) return [pscustomobject]@{ Name = 'NuGet' } }
function Install-PackageProvider { [CmdletBinding()] param($Name, [switch]$Force, [string]$Scope) Note "InstallProvider $Name" }
function Install-Module { [CmdletBinding()] param($Name, [string]$Scope, [switch]$Force, [switch]$AllowClobber) Note "InstallModule $Name"; $script:CatalogModuleInstalled = $true }
$script:CatalogResults = @{}
# The engine sends the search with a leading space (see Invoke-CatalogUpdateSearch); the catalog trims it, so the mock does too.
function Get-MSCatalogUpdate { [CmdletBinding()] param([string]$Search) $Search = $Search.Trim(); Note "CatalogSearch $Search"; return @($script:CatalogResults[$Search]) }
$script:CatalogFileNames = @{}
# -DownloadAll is a real parameter of the installed MSCatalogLTS (confirmed on Terry's machine, 2026-09-23). A title
# mapped to an array of names mimics a multi-file catalog entry (the combined .NET CU downloads two .msu files).
function Save-MSCatalogUpdate { [CmdletBinding()] param($Update, [string]$Destination, [switch]$Confirm, [switch]$DownloadAll)
    Note "CatalogSave $($Update.Title) -> $Destination$(if ($DownloadAll) { ' [DownloadAll]' })"
    New-Item -ItemType Directory -Force $Destination | Out-Null
    $names = @($script:CatalogFileNames[$Update.Title]); if (-not $names[0]) { $names = @('download.msu') }
    foreach ($name in $names) { Set-Content (Join-Path $Destination $name) 'downloaded' }
}
$script:IsoMap = @{}
function Mount-IsoFile { param([string]$ImagePath) $script:MountedIsoPaths.Add($ImagePath); return $script:IsoMap[(Split-Path $ImagePath -Leaf)] }
function Dismount-DiskImage { [CmdletBinding()] param($ImagePath) Note "IsoDismount $(Split-Path $ImagePath -Leaf)" }
function Get-WindowsImage { [CmdletBinding()] param($ImagePath, $Index, [switch]$Mounted) if ($Mounted) { return $script:MountedList }; return [pscustomobject]@{ ImageIndex = $Index; ImageName = "Img$Index"; Version = '10.0.17763.9121' } }

$base = Join-Path $PWD 'acq'; if (Test-Path $base) { Remove-Item -Recurse -Force $base }; New-Item -ItemType Directory $base | Out-Null
function New-File($p, $c = 'x') { New-Item -ItemType Directory -Force (Split-Path $p) | Out-Null; Set-Content $p $c }
function Fake-Iso($repoOsFolder, $isoName, $files) {
    $d = Join-Path $base "_isos_$isoName"
    foreach ($f in $files) { New-File (Join-Path $d $f) }
    New-File (Join-Path (Join-Path (Join-Path $base $repoOsFolder) 'ISO') "$isoName.iso")
    $script:IsoMap["$isoName.iso"] = $d
}

Write-Host "`n=== A1 ConvertTo-OsProfile: catalogSearch parses, and rejects bad input ==="
$goodData = [ordered]@{ name = 'X'; folder = 'X'; editionRegex = 'a'; preferredIndex = 1
    catalogSearch = [ordered]@{ LCU = [ordered]@{ search = 'Windows 10 Version 1809 {build}'; architecture = 'x64'; excludePreview = $true; checkpointKBs = @('KB111', 'KB222') } } }
$p = ConvertTo-OsProfile -Data $goodData
Check 'catalogSearch.LCU parsed' ($p.CatalogSearch['LCU'].search -eq 'Windows 10 Version 1809 {build}' -and $p.CatalogSearch['LCU'].architecture -eq 'x64' -and $p.CatalogSearch['LCU'].excludePreview -eq $true)
Check 'checkpointKBs parsed as array' ((@($p.CatalogSearch['LCU'].checkpointKBs) -join ',') -eq 'KB111,KB222')
$multiSearchData = [ordered]@{ name = 'X'; folder = 'X'; editionRegex = 'a'; preferredIndex = 1
    catalogSearch = [ordered]@{ NetCU = [ordered]@{ search = @('term-one', ' term-two ', '', 'term-one'); architecture = 'x64' } } }
$pMulti = ConvertTo-OsProfile -Data $multiSearchData
Check 'array search: .search is the first term, .searches keeps every non-empty trimmed term (dupes included, order kept)' ($pMulti.CatalogSearch['NetCU'].search -eq 'term-one' -and ((@($pMulti.CatalogSearch['NetCU'].searches) -join '|') -eq 'term-one|term-two|term-one'))
Check 'a profile with no catalogSearch gets an empty table, not an error' ((ConvertTo-OsProfile -Data ([ordered]@{ name = 'Y'; folder = 'Y'; editionRegex = 'a'; preferredIndex = 1 })).CatalogSearch.Count -eq 0)
$threw = $false; try { ConvertTo-OsProfile -Data ([ordered]@{ name = 'X'; folder = 'X'; editionRegex = 'a'; preferredIndex = 1; catalogSearch = [ordered]@{ Nope = [ordered]@{ search = 'a' } } }) } catch { $threw = $true; $m1 = $_.Exception.Message }
Check 'unknown catalogSearch class throws' ($threw -and $m1 -like "*unknown class*")
$threw = $false; try { ConvertTo-OsProfile -Data ([ordered]@{ name = 'X'; folder = 'X'; editionRegex = 'a'; preferredIndex = 1; catalogSearch = [ordered]@{ SSU = [ordered]@{ search = 'a' } } }) } catch { $threw = $true; $m2 = $_.Exception.Message }
Check 'catalogSearch.SSU throws (SSU stays manual)' ($threw -and $m2 -like '*stay manual*')
$threw = $false; try { ConvertTo-OsProfile -Data ([ordered]@{ name = 'X'; folder = 'X'; editionRegex = 'a'; preferredIndex = 1; catalogSearch = [ordered]@{ LCU = [ordered]@{ architecture = 'x64' } } }) } catch { $threw = $true; $m3 = $_.Exception.Message }
Check "catalogSearch class missing 'search' throws" ($threw -and $m3 -like "*.search' is required*")

Write-Host "`n=== A2 Resolve-CatalogSearch / Test-CatalogCandidate / Get-CatalogDate ==="
Check '{build} substituted' ((Resolve-CatalogSearch -Search 'Windows 10 {build} x64' -Build '19041.3636') -eq 'Windows 10 19041.3636 x64')
Check '{version} alias substituted' ((Resolve-CatalogSearch -Search 'Windows 10 {version} x64' -Build '19041.3636') -eq 'Windows 10 19041.3636 x64')
Check 'no build: placeholder left as literal text' ((Resolve-CatalogSearch -Search 'Windows 10 {build} x64' -Build $null) -eq 'Windows 10 {build} x64')
$ruleArch = [pscustomobject]@{ architecture = 'x64'; excludePreview = $true; buildFilter = '' }
Check 'wrong architecture filtered out' (-not (Test-CatalogCandidate -Result ([pscustomobject]@{ Architecture = 'ARM64'; Title = 'Cumulative Update' }) -Rule $ruleArch))
Check 'preview filtered out when excludePreview' (-not (Test-CatalogCandidate -Result ([pscustomobject]@{ Architecture = 'x64'; Title = '2026-09 Preview Cumulative Update' }) -Rule $ruleArch))
Check 'matching x64 non-preview passes' (Test-CatalogCandidate -Result ([pscustomobject]@{ Architecture = 'x64'; Title = '2026-09 Cumulative Update (KB5044284)' }) -Rule $ruleArch)
$ruleFilter = [pscustomobject]@{ architecture = 'x64'; excludePreview = $true; buildFilter = '21H2' }
Check 'buildFilter excludes non-matching title' (-not (Test-CatalogCandidate -Result ([pscustomobject]@{ Architecture = 'x64'; Title = 'Cumulative Update for Windows 10 Version 1809' }) -Rule $ruleFilter))
Check 'buildFilter passes matching title' (Test-CatalogCandidate -Result ([pscustomobject]@{ Architecture = 'x64'; Title = 'Cumulative Update for Windows 10 Version 21H2' }) -Rule $ruleFilter)
Check 'Get-CatalogDate parses a date string' ((Get-CatalogDate ([pscustomobject]@{ LastUpdated = '9/10/2026' })) -eq [datetime]'2026-09-10')
Check 'Get-CatalogDate falls back to MinValue' ((Get-CatalogDate ([pscustomobject]@{})) -eq [datetime]::MinValue)

Write-Host "`n=== A2b Invoke-CatalogUpdateSearch adapts to the installed module's real parameter surface ==="
Reset-Test
$probeRule = [pscustomobject]@{ search = 'probe-search'; architecture = 'x64'; excludePreview = $true; buildFilter = '' }
$null = Invoke-CatalogUpdateSearch -Search 'probe-search' -Rule $probeRule
Check 'search still runs against a mock lacking Architecture/ExcludePreview params, without erroring' ((@($script:Calls -match '^CatalogSearch probe-search')).Count -eq 1)

Write-Host "`n=== A2c Invoke-CatalogUpdateSearch against the real MSCatalogLTS 2.1.0.1 parameter surface ==="
# The installed 2.1.0.1 (Terry's PC, 2026-09-24) hides Dynamic Updates without -IncludeDynamic, reads one page without
# -AllPages, has -IncludePreview instead of -ExcludePreview, and rewrites searches starting "Dynamic Update for ...".
$simpleCatalogMock = ${function:Get-MSCatalogUpdate}
function Get-MSCatalogUpdate { [CmdletBinding()] param([string]$Search, [string]$Architecture, [switch]$IncludeDynamic, [switch]$AllPages, [switch]$IncludePreview)
    $script:LastCatalogCall = [pscustomobject]@{ Search = $Search; Params = @($PSBoundParameters.Keys) }; return @() }
$duRule = [pscustomobject]@{ search = 'Dynamic Update for Windows 10 Version 1809 for x64-based Systems'; architecture = 'x64'; excludePreview = $true; buildFilter = '' }
$null = Invoke-CatalogUpdateSearch -Search $duRule.search -Rule $duRule
Check '-IncludeDynamic is passed (Safe OS / Setup DU titles contain "Dynamic")' ($script:LastCatalogCall.Params -contains 'IncludeDynamic')
Check '-AllPages is passed (a Setup DU can be past the first 25 rows)' ($script:LastCatalogCall.Params -contains 'AllPages')
Check '-IncludePreview is not passed when excludePreview is true' ($script:LastCatalogCall.Params -notcontains 'IncludePreview')
Check '-Architecture is passed' ($script:LastCatalogCall.Params -contains 'Architecture')
Check 'the search cannot match the module''s update-type rewrite (^Dynamic Update for ...)' ($script:LastCatalogCall.Search -notmatch '^((?:\d{4}-\d{2}(?:-\d{2})?\s+)?)(Servicing Stack|Dynamic Update|Security Update|Cumulative Update|Feature Update)\s+for\s+(.+)$' -and $script:LastCatalogCall.Search.Trim() -eq $duRule.search)
$pvRule = [pscustomobject]@{ search = 'x'; architecture = 'x64'; excludePreview = $false; buildFilter = '' }
$null = Invoke-CatalogUpdateSearch -Search 'x' -Rule $pvRule
Check '-IncludePreview is passed when excludePreview is false' ($script:LastCatalogCall.Params -contains 'IncludePreview')
Set-Item function:Get-MSCatalogUpdate $simpleCatalogMock

Write-Host "`n=== A3 Update-PatchCache: keeps newest + chain, removes the rest, tolerates a missing folder ==="
$cacheDir = Join-Path $base 'cache'; New-File (Join-Path $cacheDir 'old-kb1-x64.msu'); New-File (Join-Path $cacheDir 'old2.cab'); New-File (Join-Path $cacheDir 'chained-kb1234567-x64.msu'); New-File (Join-Path $cacheDir 'newest-kb2345678-x64.msu')
$removed = Update-PatchCache -Folder $cacheDir -NewestFile (Join-Path $cacheDir 'newest-kb2345678-x64.msu') -KeepChain @('KB1234567')
$remaining = @(Get-ChildItem $cacheDir -File | Select-Object -ExpandProperty Name | Sort-Object)
Check 'newest + chained KB kept, others removed' (($remaining -join ',') -eq 'chained-kb1234567-x64.msu,newest-kb2345678-x64.msu')
Check 'removed list has exactly the two superseded files' ($removed.Count -eq 2 -and $removed -contains 'old-kb1-x64.msu' -and $removed -contains 'old2.cab')
Check 'a missing folder returns empty, no error' (@(Update-PatchCache -Folder (Join-Path $base 'doesnotexist') -NewestFile 'x.msu').Count -eq 0)
$multiCacheDir = Join-Path $base 'cache2'; New-File (Join-Path $multiCacheDir 'stale-x64.msu'); New-File (Join-Path $multiCacheDir 'keep1-kb1111111-x64.msu'); New-File (Join-Path $multiCacheDir 'keep2-kb2222222-x64.msu')
$removedMulti = Update-PatchCache -Folder $multiCacheDir -KeepFiles @((Join-Path $multiCacheDir 'keep1-kb1111111-x64.msu'), (Join-Path $multiCacheDir 'keep2-kb2222222-x64.msu'))
$remainingMulti = @(Get-ChildItem $multiCacheDir -File | Select-Object -ExpandProperty Name | Sort-Object)
Check '-KeepFiles keeps every listed file (not just one newest), prunes the rest' (($remainingMulti -join ',') -eq 'keep1-kb1111111-x64.msu,keep2-kb2222222-x64.msu' -and @($removedMulti).Count -eq 1 -and $removedMulti -contains 'stale-x64.msu')

Write-Host "`n=== A4 Invoke-PatchAcquisition: dry run changes nothing; a real run downloads, prunes, logs, and never touches SSU ==="
Reset-Test
$definition = ConvertTo-OsProfile -Data ([ordered]@{
    name = 'TestOS'; folder = 'TestOS'; editionRegex = 'a'; preferredIndex = 1
    catalogSearch = [ordered]@{
        LCU    = [ordered]@{ search = 'search-lcu'; architecture = 'x64'; excludePreview = $true }
        NetCU  = [ordered]@{ search = 'search-netcu'; architecture = 'x64'; excludePreview = $true }
    }
})
$paths = Initialize-Repository -Root $base -Definition $definition
Fake-Iso 'TestOS' 'osiso' @('sources/install.wim')
New-File (Join-Path $paths.Patches 'LCU\old-kb1-x64.msu')
New-File (Join-Path $paths.Patches 'SSU\ssu-kb5005112-x64.msu')
$script:CatalogResults['search-lcu'] = @([pscustomobject]@{ Title = '2026-09 Cumulative Update for Test (KB5044284)'; Architecture = 'x64'; LastUpdated = '9/10/2026' })
$script:CatalogResults['search-netcu'] = @([pscustomobject]@{ Title = '2026-09 Cumulative Update for .NET Framework Test (KB5044999)'; Architecture = 'x64'; LastUpdated = '9/10/2026' })
$script:CatalogFileNames['2026-09 Cumulative Update for Test (KB5044284)'] = 'windows-kb5044284-x64_abcd.msu'
$script:CatalogFileNames['2026-09 Cumulative Update for .NET Framework Test (KB5044999)'] = 'windows-kb5044999-x64-ndp48_efgh.msu'

$optsDry = [pscustomobject]@{ OsName = 'TestOS'; Root = $base; Mode = 'Download'; DryRun = $true; LCU = $true; NetCU = $true; SafeOS = $false; SetupDU = $false }
$resDry = Invoke-PatchAcquisition -Options $optsDry -Definition $definition -Paths $paths
Check 'dry run reports a 2-item plan' (@($resDry.Plan).Count -eq 2)
Check 'dry run downloads nothing' (-not ($script:Calls -match '^CatalogSave'))
Check 'dry run leaves the old LCU file in place' (Test-Path (Join-Path $paths.Patches 'LCU\old-kb1-x64.msu'))
Check 'dry run never touches SSU' (@(Get-ChildItem (Join-Path $paths.Patches 'SSU') -File).Count -eq 1)

Reset-Test
$optsReal = [pscustomobject]@{ OsName = 'TestOS'; Root = $base; Mode = 'Download'; DryRun = $false; LCU = $true; NetCU = $true; SafeOS = $false; SetupDU = $false }
$resReal = Invoke-PatchAcquisition -Options $optsReal -Definition $definition -Paths $paths
Check 'real run downloaded 2 files' (@($resReal.Downloaded).Count -eq 2)
$lcuFiles = @(Get-ChildItem (Join-Path $paths.Patches 'LCU') -File | Select-Object -ExpandProperty Name)
Check 'LCU folder has only the new file (old one pruned)' (($lcuFiles -join ',') -eq 'windows-kb5044284-x64_abcd.msu')
Check 'NetCU folder has the new file' ((@(Get-ChildItem (Join-Path $paths.Patches 'NETCU') -File | Select-Object -ExpandProperty Name) -join ',') -eq 'windows-kb5044999-x64-ndp48_efgh.msu')
Check 'real run never touches SSU either' (@(Get-ChildItem (Join-Path $paths.Patches 'SSU') -File).Count -eq 1)
Check 'change events recorded for LCU and NetCU' (@($script:ChangeEvents | Where-Object { $_.Category -eq 'LCU' -and $_.Kb -eq 'KB5044284' }).Count -eq 1 -and @($script:ChangeEvents | Where-Object { $_.Category -eq 'NetCU' -and $_.Kb -eq 'KB5044999' }).Count -eq 1)
Check 'result carries Mode/DryRun for the GUI to branch on' ($resReal.Mode -eq 'Download' -and $resReal.DryRun -eq $false)

Write-Host "`n=== A5 a class with no profile rule is skipped, not silently ignored ==="
Reset-Test
$optsMissing = [pscustomobject]@{ OsName = 'TestOS'; Root = $base; Mode = 'Download'; DryRun = $true; LCU = $false; NetCU = $false; SafeOS = $true; SetupDU = $false }
$resMissing = Invoke-PatchAcquisition -Options $optsMissing -Definition $definition -Paths $paths
Check 'requesting a class the profile has no rule for is reported, not silently skipped' (@($resMissing.SkippedClasses -match 'SafeOS.*no catalogSearch rule').Count -eq 1)

Write-Host "`n=== A6 Invoke-PatchAcquisition: a class with more than one search term (e.g. .NET CU on Windows 10 1809, which needs both its \"3.5 and 4.7.2\" and \"3.5 and 4.8\" updates) downloads and keeps every term's match, and still prunes what's genuinely stale ==="
Reset-Test
$multiDef = ConvertTo-OsProfile -Data ([ordered]@{
    name = 'TestOS2'; folder = 'TestOS2'; editionRegex = 'a'; preferredIndex = 1
    catalogSearch = [ordered]@{
        NetCU = [ordered]@{ search = @('search-netcu-48', 'search-netcu-472'); architecture = 'x64'; excludePreview = $true }
    }
})
Check 'multi-term rule parsed: .search is the first term, .searches has both' ($multiDef.CatalogSearch['NetCU'].search -eq 'search-netcu-48' -and ((@($multiDef.CatalogSearch['NetCU'].searches) -join ',') -eq 'search-netcu-48,search-netcu-472'))
$paths2 = Initialize-Repository -Root $base -Definition $multiDef
Fake-Iso 'TestOS2' 'osiso2' @('sources/install.wim')
New-File (Join-Path $paths2.Patches 'NETCU\stale-old-kb0000000-x64.msu')
$script:CatalogResults['search-netcu-48'] = @([pscustomobject]@{ Title = '2026-09 Cumulative Update for .NET Framework 3.5 and 4.8 for Test (KB6000001)'; Architecture = 'x64'; LastUpdated = '9/10/2026' })
$script:CatalogResults['search-netcu-472'] = @([pscustomobject]@{ Title = '2026-09 Cumulative Update for .NET Framework 3.5 and 4.7.2 for Test (KB6000002)'; Architecture = 'x64'; LastUpdated = '9/10/2026' })
$script:CatalogFileNames['2026-09 Cumulative Update for .NET Framework 3.5 and 4.8 for Test (KB6000001)'] = 'windows10.0-kb6000001-x64-ndp48.msu'
$script:CatalogFileNames['2026-09 Cumulative Update for .NET Framework 3.5 and 4.7.2 for Test (KB6000002)'] = 'windows10.0-kb6000002-x64-ndp472.msu'

$optsMultiDry = [pscustomobject]@{ OsName = 'TestOS2'; Root = $base; Mode = 'Download'; DryRun = $true; LCU = $false; NetCU = $true; SafeOS = $false; SetupDU = $false }
$resMultiDry = Invoke-PatchAcquisition -Options $optsMultiDry -Definition $multiDef -Paths $paths2
Check 'dry run reports one plan entry per search term (2 for this one class)' (@($resMultiDry.Plan).Count -eq 2)
Check 'dry run downloads nothing' (-not ($script:Calls -match '^CatalogSave'))

Reset-Test
$optsMultiReal = [pscustomobject]@{ OsName = 'TestOS2'; Root = $base; Mode = 'Download'; DryRun = $false; LCU = $false; NetCU = $true; SafeOS = $false; SetupDU = $false }
$resMultiReal = Invoke-PatchAcquisition -Options $optsMultiReal -Definition $multiDef -Paths $paths2
Check 'real run downloaded both term matches, not just one' (@($resMultiReal.Downloaded).Count -eq 2)
$netcuFiles = @(Get-ChildItem (Join-Path $paths2.Patches 'NETCU') -File | Select-Object -ExpandProperty Name | Sort-Object)
Check 'both downloaded files are kept side by side; the stale pre-existing file is pruned' (($netcuFiles -join ',') -eq 'windows10.0-kb6000001-x64-ndp48.msu,windows10.0-kb6000002-x64-ndp472.msu')
Check 'neither current file pruned the other (both KBs present in Downloaded)' (@($resMultiReal.Downloaded | Where-Object { $_.Kb -eq 'KB6000001' }).Count -eq 1 -and @($resMultiReal.Downloaded | Where-Object { $_.Kb -eq 'KB6000002' }).Count -eq 1)

# Capture log lines for A7 as well as printing them (mocks.ps1's Write-Log only prints).
$script:LogLines = [System.Collections.Generic.List[string]]::new()
function Write-Log { param($Message, $Level = 'INFO') $script:LogLines.Add("[$Level] $Message"); Write-Host ("   [{0}] {1}" -f $Level, $Message) }
Write-Host "`n=== A7 Real catalog shapes (Terry's LTSC 2019 test, 2026-09-23): architecture from the title, title filters, multi-file entries, not-applicable .NET parts ==="
# Real Get-MSCatalogUpdate results have Title/Products/Classification/LastUpdated/Version/Size/SizeInBytes/Guid/FileNames -
# no Architecture property. The x86 combined .NET CU entry names no architecture in its title; the x64 one ends "for x64".
$t86 = '2026-09 Cumulative Update for .NET Framework 3.5, 4.7.2 and 4.8 for Windows 10 Version 1809 (KB5126144)'
$t64 = '2026-09 Cumulative Update for .NET Framework 3.5, 4.7.2 and 4.8 for Windows 10 Version 1809 for x64 (KB5126144)'
$tArm = '2026-09 Cumulative Update for .NET Framework 3.5, 4.7.2 and 4.8 for Windows 10 Version 1809 for ARM64 (KB5126144)'
$tLcu = '2026-09 Cumulative Update for Windows 10 Version 1809 for x64-based Systems (KB5126100)'
$tDynLcu = '2026-09 Dynamic Cumulative Update for Windows 10 Version 1809 for x64-based Systems (KB5126101)'
function Real-Result($title, $date = '9/8/2026 9:25:13 PM') { [pscustomobject]@{ Title = $title; Products = 'Windows 10, Windows 10 LTSB'; Classification = 'Security Updates'; LastUpdated = $date; Version = 'n/a'; Size = '100.8 MB'; SizeInBytes = 105703326; Guid = [guid]::NewGuid().ToString(); FileNames = '' } }
Check 'Get-ArchFromText: x64 title / x86-less title / ARM64 title' ((Get-ArchFromText $t64) -eq 'x64' -and (Get-ArchFromText $t86) -eq '' -and (Get-ArchFromText $tArm) -eq 'arm64')
Check 'Get-ArchFromText: file names (x64, x86-ndp48, x64-based Systems)' ((Get-ArchFromText 'windows10.0-kb5126043-x64.msu') -eq 'x64' -and (Get-ArchFromText 'windows10.0-kb5126048-x86-ndp48.msu') -eq 'x86' -and (Get-ArchFromText $tLcu) -eq 'x64')
$ruleX64 = [pscustomobject]@{ architecture = 'x64'; excludePreview = $true; buildFilter = '' }
Check 'no Architecture property: x64 title accepted' (Test-CatalogCandidate -Result (Real-Result $t64) -Rule $ruleX64)
Check 'no Architecture property: title naming no architecture (the x86 .NET entry) rejected' (-not (Test-CatalogCandidate -Result (Real-Result $t86) -Rule $ruleX64))
Check 'no Architecture property: ARM64 title rejected' (-not (Test-CatalogCandidate -Result (Real-Result $tArm) -Rule $ruleX64))
Check "architecture '' in the rule switches the check off" (Test-CatalogCandidate -Result (Real-Result $t86) -Rule ([pscustomobject]@{ architecture = ''; excludePreview = $true; buildFilter = '' }))
Check 'Architecture property amd64 counts as x64' (Test-CatalogCandidate -Result ([pscustomobject]@{ Title = 'Some update'; Architecture = 'AMD64' }) -Rule $ruleX64)

$b1809 = ConvertTo-OsProfile -Data (Get-BuiltInProfileData | Where-Object { $_.folder -eq 'Win10_Enterprise_LTSC_2019' } | Select-Object -First 1)
$lcuRule = [pscustomobject]@{ architecture = 'x64'; excludePreview = $true; buildFilter = $b1809.CatalogSearch['LCU'].buildFilter }
Check 'built-in 1809 LCU filter accepts the real LCU title' (Test-CatalogCandidate -Result (Real-Result $tLcu) -Rule $lcuRule)
Check 'built-in 1809 LCU filter rejects the .NET CU released the same day' (-not (Test-CatalogCandidate -Result (Real-Result $t64) -Rule $lcuRule))
Check 'built-in 1809 LCU filter rejects the Dynamic Cumulative Update' (-not (Test-CatalogCandidate -Result (Real-Result $tDynLcu) -Rule $lcuRule))
$netRule = [pscustomobject]@{ architecture = 'x64'; excludePreview = $true; buildFilter = $b1809.CatalogSearch['NetCU'].buildFilter }
Check 'built-in 1809 NetCU is one search term (the combined 3.5, 4.7.2 and 4.8 entry)' (@($b1809.CatalogSearch['NetCU'].searches).Count -eq 1 -and $b1809.CatalogSearch['NetCU'].search -like '*3.5, 4.7.2 and 4.8*Version 1809*')
Check 'built-in 1809 NetCU filter: x64 combined entry accepted, x86 entry and 4.7.2-only entry rejected' ((Test-CatalogCandidate -Result (Real-Result $t64) -Rule $netRule) -and -not (Test-CatalogCandidate -Result (Real-Result $t86) -Rule $netRule) -and -not (Test-CatalogCandidate -Result (Real-Result '2026-09 Cumulative Update for .NET Framework 3.5 and 4.7.2 for Windows 10 Version 1809 for x64 (KB5126043)') -Rule $netRule))
$b21 = ConvertTo-OsProfile -Data (Get-BuiltInProfileData | Where-Object { $_.folder -eq 'Win10_Enterprise_LTSC_2021_KMS' } | Select-Object -First 1)
$lcu21 = [pscustomobject]@{ architecture = 'x64'; excludePreview = $true; buildFilter = $b21.CatalogSearch['LCU'].buildFilter }
Check 'built-in 21H2 LCU filter rejects Windows 11 21H2 and accepts Windows 10 21H2' ((Test-CatalogCandidate -Result (Real-Result '2026-09 Cumulative Update for Windows 10 Version 21H2 for x64-based Systems (KB5126200)') -Rule $lcu21) -and -not (Test-CatalogCandidate -Result (Real-Result '2026-09 Cumulative Update for Windows 11 Version 21H2 for x64-based Systems (KB5126201)') -Rule $lcu21))

# End to end: the x86 entry is listed first (as on Terry's machine), the x64 entry downloads two files.
Reset-Test
$realDef = ConvertTo-OsProfile -Data ([ordered]@{
    name = 'TestOS3'; folder = 'TestOS3'; editionRegex = 'a'; preferredIndex = 1
    catalogSearch = [ordered]@{ NetCU = [ordered]@{ search = 'search-real-netcu'; architecture = 'x64'; excludePreview = $true; buildFilter = $b1809.CatalogSearch['NetCU'].buildFilter } }
})
$paths3 = Initialize-Repository -Root $base -Definition $realDef
Fake-Iso 'TestOS3' 'osiso3' @('sources/install.wim')
New-File (Join-Path $paths3.Patches 'NETCU\windows10.0-kb5120000-x64.msu')
$script:CatalogResults['search-real-netcu'] = @((Real-Result $t86), (Real-Result $t64))
$script:CatalogFileNames[$t64] = @('windows10.0-kb5126048-x64-ndp48.msu', 'windows10.0-kb5126043-x64.msu')
$resReal = Invoke-PatchAcquisition -Options ([pscustomobject]@{ OsName = 'TestOS3'; Root = $base; Mode = 'Download'; DryRun = $false; LCU = $false; NetCU = $true; SafeOS = $false; SetupDU = $false }) -Definition $realDef -Paths $paths3
Check 'the x64 entry was saved, never the x86 one listed before it' (@($script:Calls -match '^CatalogSave').Count -eq 1 -and ($script:Calls -match '^CatalogSave') -match 'for x64 \(KB5126144\)')
Check '-DownloadAll passed because the installed module declares it' ([bool]($script:Calls -match '^CatalogSave.*\[DownloadAll\]'))
$net3 = @(Get-ChildItem (Join-Path $paths3.Patches 'NETCU') -File | Select-Object -ExpandProperty Name | Sort-Object)
Check 'both files of the entry kept (4.7.2 and 4.8 parts); the previous month''s file pruned' (($net3 -join ',') -eq 'windows10.0-kb5126043-x64.msu,windows10.0-kb5126048-x64-ndp48.msu')
Check 'Downloaded lists each file under its own KB, with the catalog entry KB alongside' ((@($resReal.Downloaded | ForEach-Object { $_.Kb } | Sort-Object) -join ',') -eq 'KB5126043,KB5126048' -and @($resReal.Downloaded | Where-Object { $_.EntryKb -eq 'KB5126144' }).Count -eq 2)

# Safe OS DU vs Setup DU on 1809: same title shape, told apart only by Products (Terry, 2026-09-23: the Safe OS DU is
# '2026-08 Dynamic Update for Windows 10 Version 1809 for x64-based Systems (KB5120247)', products 'Windows 10 and
# later Dynamic Update, Windows Safe OS Dynamic Update'). The Setup DU's Products value is assumed, not yet seen.
$tSafe = '2026-08 Dynamic Update for Windows 10 Version 1809 for x64-based Systems (KB5120247)'
$tSetup = '2026-08 Dynamic Update for Windows 10 Version 1809 for x64-based Systems (KB5120250)'
$rSafe = Real-Result $tSafe; $rSafe.Products = 'Windows 10 and later Dynamic Update, Windows Safe OS Dynamic Update'
$rSetup = Real-Result $tSetup; $rSetup.Products = 'Windows 10 and later Dynamic Update'
$rDynLcu = Real-Result $tDynLcu; $rDynLcu.Products = 'Windows 10 and later Dynamic Update'
$ruleSafe = [pscustomobject]@{ architecture = 'x64'; excludePreview = $true; buildFilter = $b1809.CatalogSearch['SafeOS'].buildFilter; productFilter = $b1809.CatalogSearch['SafeOS'].productFilter; productExclude = $b1809.CatalogSearch['SafeOS'].productExclude }
$ruleSetup = [pscustomobject]@{ architecture = 'x64'; excludePreview = $true; buildFilter = $b1809.CatalogSearch['SetupDU'].buildFilter; productFilter = $b1809.CatalogSearch['SetupDU'].productFilter; productExclude = $b1809.CatalogSearch['SetupDU'].productExclude }
Check 'built-in 1809 SafeOS rule: accepts the real Safe OS DU, rejects the Setup DU and the Dynamic Cumulative Update' ((Test-CatalogCandidate -Result $rSafe -Rule $ruleSafe) -and -not (Test-CatalogCandidate -Result $rSetup -Rule $ruleSafe) -and -not (Test-CatalogCandidate -Result $rDynLcu -Rule $ruleSafe))
Check 'built-in 1809 SetupDU rule: accepts the Setup DU, rejects the Safe OS DU and the Dynamic Cumulative Update' ((Test-CatalogCandidate -Result $rSetup -Rule $ruleSetup) -and -not (Test-CatalogCandidate -Result $rSafe -Rule $ruleSetup) -and -not (Test-CatalogCandidate -Result $rDynLcu -Rule $ruleSetup))
Check 'Products given as a list is matched too' (Test-CatalogCandidate -Result ([pscustomobject]@{ Title = $tSafe; Products = @('Windows 10 and later Dynamic Update', 'Windows Safe OS Dynamic Update') }) -Rule $ruleSafe)
$threw = $false; try { ConvertTo-OsProfile -Data ([ordered]@{ name = 'X'; folder = 'X'; editionRegex = 'a'; preferredIndex = 1; catalogSearch = [ordered]@{ SafeOS = [ordered]@{ search = 'a'; productFilter = '([bad' } } }) } catch { $threw = $true; $mRx = $_.Exception.Message }
Check 'an invalid productFilter regex is refused when the profile loads' ($threw -and $mRx -like "*productFilter' is not a valid regular expression*")
$threw = $false; try { ConvertTo-OsProfile -Data ([ordered]@{ name = 'X'; folder = 'X'; editionRegex = 'a'; preferredIndex = 1; catalogSearch = [ordered]@{ NetCU = [ordered]@{ search = ('x' * 101) } } }) } catch { $threw = $true; $mLen = $_.Exception.Message }
Check 'a search over 100 characters is refused when the profile loads (the catalog returns nothing for it)' ($threw -and $mLen -like '*over 100 characters*')

Write-Host "`n=== A8 built-in rules against real catalog results (Claude, live catalog, 2026-09-24) ==="
$builtIn = @(Get-BuiltInProfileData | ForEach-Object { ConvertTo-OsProfile -Data $_ })
$longest = ($builtIn | ForEach-Object { foreach ($k in @($_.CatalogSearch.Keys)) { foreach ($s in $_.CatalogSearch[$k].searches) { $s.Length } } } | Measure-Object -Maximum).Maximum
Check 'every built-in search fits the catalog''s 100-character limit' ($longest -le 100) "$longest"
function Rule-Of($folder, $class) { $d = $builtIn | Where-Object { $_.Folder -eq $folder } | Select-Object -First 1; $r = $d.CatalogSearch[$class]; [pscustomobject]@{ architecture = $r.architecture; excludePreview = $r.excludePreview; buildFilter = $r.buildFilter; productFilter = $r.productFilter; productExclude = $r.productExclude } }
function RR($title, $products) { $r = Real-Result $title; $r.Products = $products; $r }
$pSafe = 'Windows 10 and later Dynamic Update, Windows Safe OS Dynamic Update'; $pDu = 'Windows 10 and later Dynamic Update'
# Picks: accepted = the entry the rule must choose; rejected = real neighbours from the same search
$cases = @(
    @{ f = 'Win10_IoT_Enterprise_LTSC_2021'; c = 'LCU'; ok = (RR '2026-09 Cumulative Update for Windows 10 Version 21H2 for x64-based Systems (KB5129236)' 'Windows 10 LTSB')
       no = @((RR '2026-09 Dynamic Cumulative Update for Windows 10 Version 21H2 for x64-based Systems (KB5122878)' 'Windows 10 and later GDR-DU'), (RR '2026-09 Cumulative Update for Windows 10 Version 21H2 for ARM64-based Systems (KB5129236)' 'Windows 10 LTSB')) }
    @{ f = 'Win10_IoT_Enterprise_LTSC_2021'; c = 'NetCU'; ok = (RR '2026-09 Cumulative Update for .NET Framework 3.5, 4.8 and 4.8.1 for Windows 10 Version 21H2 for x64 (KB5126145)' 'Windows 10 LTSB')
       no = @((RR '2026-09 Cumulative Update for .NET Framework 3.5, 4.8 and 4.8.1 for Windows 10 Version 21H2 (KB5126145)' 'Windows 10 LTSB'), (RR '2026-09 Cumulative Update for .NET Framework 3.5 and 4.8 for Windows 10 Version 21H2 for x64 (KB5126046)' 'Windows 10 LTSB')) }
    @{ f = 'Win10_IoT_Enterprise_LTSC_2021'; c = 'SafeOS'; ok = (RR '2026-09 Dynamic Update for Windows 10 Version 21H2 for x64-based Systems (KB5122887)' $pSafe)
       no = @((RR '2026-09 Dynamic Update for Windows 10 Version 21H2 for x64-based Systems (KB5126029)' $pDu), (RR '2026-09 Dynamic Cumulative Update for Windows 10 Version 21H2 for x64-based Systems (KB5122878)' 'Windows 10 and later GDR-DU')) }
    @{ f = 'Win10_IoT_Enterprise_LTSC_2021'; c = 'SetupDU'; ok = (RR '2026-09 Dynamic Update for Windows 10 Version 21H2 for x64-based Systems (KB5126029)' $pDu)
       no = @((RR '2026-09 Dynamic Update for Windows 10 Version 21H2 for x64-based Systems (KB5122887)' $pSafe)) }
    @{ f = 'Windows_Server_2022'; c = 'NetCU'; ok = (RR '2026-09 Cumulative Update for .NET Framework 3.5, 4.8 and 4.8.1 for Microsoft server operating system version 21H2 for x64 (KB5126149)' 'Microsoft Server operating system-21H2')
       no = @((RR '2026-09 Cumulative Update for .NET Framework 3.5 and 4.8.1 for Microsoft server operating system version 21H2 for x64 (KB5126422)' 'Microsoft Server operating system-21H2')) }
    @{ f = 'Windows_Server_2022'; c = 'SafeOS'; ok = (RR '2026-09 Dynamic Update for Microsoft server operating system version 21H2 for x64-based Systems (KB5122889)' $pSafe)
       no = @((RR '2026-09 Dynamic Update for Microsoft server operating system version 21H2 for x64-based Systems (KB5126031)' $pDu)) }
    @{ f = 'Windows_Server_2022'; c = 'SetupDU'; ok = (RR '2026-09 Dynamic Update for Microsoft server operating system version 21H2 for x64-based Systems (KB5126031)' $pDu)
       no = @((RR '2026-09 Dynamic Update for Microsoft server operating system version 21H2 for x64-based Systems (KB5122889)' $pSafe)) }
    @{ f = 'Win11_Enterprise_24H2'; c = 'NetCU'; ok = (RR '2026-09 Cumulative Update for .NET Framework 3.5 and 4.8.1 for Windows 11, version 24H2 for x64 (KB5126052)' 'Windows 11')
       no = @((RR '2026-08 Cumulative Update Preview for .NET Framework 3.5 and 4.8.1 for Windows 11, version 24H2 for x64 (KB5122385)' 'Windows 11')) }
    @{ f = 'Win11_Enterprise_24H2'; c = 'SafeOS'; ok = (RR '2026-09 Safe OS Dynamic Update for Windows 11, version 24H2 for x64-based Systems (KB5125758)' 'Windows Safe OS Dynamic Update, Windows 10 and later Dynamic Update')
       no = @((RR '2026-09 Safe OS Dynamic Update for Windows 11, version 24H2 for arm64-based Systems (KB5125758)' 'Windows Safe OS Dynamic Update, Windows 10 and later Dynamic Update'), (RR '2026-09 Setup Dynamic Update for Windows 11, version 24H2 for x64-based Systems (KB5127216)' $pDu)) }
    @{ f = 'Win11_Enterprise_24H2'; c = 'SetupDU'; ok = (RR '2026-09 Setup Dynamic Update for Windows 11, version 24H2 for x64-based Systems (KB5127216)' $pDu)
       no = @((RR '2026-09 Safe OS Dynamic Update for Windows 11, version 24H2 for x64-based Systems (KB5125758)' 'Windows Safe OS Dynamic Update, Windows 10 and later Dynamic Update')) }
)
foreach ($k in $cases) {
    $rule = Rule-Of $k.f $k.c
    $okPass = Test-CatalogCandidate -Result $k.ok -Rule $rule
    $noPass = @($k.no | Where-Object { Test-CatalogCandidate -Result $_ -Rule $rule })
    Check "built-in $($k.f) $($k.c): accepts the real entry, rejects its $(@($k.no).Count) neighbour(s)" ($okPass -and $noPass.Count -eq 0) "accepted=$okPass wronglyAccepted=$(($noPass | ForEach-Object { $_.Title }) -join ' | ')"
}

# A class whose search returns nothing must not stop the run (Terry's real LTSC 2019 dry run: the Safe OS DU search
# returned 0 results and the run died on '.Count' under StrictMode); later classes still run and it is reported.
Reset-Test
$zeroDef = ConvertTo-OsProfile -Data ([ordered]@{
    name = 'TestOS3'; folder = 'TestOS3'; editionRegex = 'a'; preferredIndex = 1
    catalogSearch = [ordered]@{
        SafeOS = [ordered]@{ search = 'search-nothing'; architecture = 'x64'; excludePreview = $true }
        SetupDU = [ordered]@{ search = 'search-setupdu'; architecture = 'x64'; excludePreview = $true }
    }
})
$script:CatalogResults['search-nothing'] = @()
$script:CatalogResults['search-setupdu'] = @((Real-Result '2026-09 Setup Dynamic Update for Windows 10 Version 1809 for x64-based Systems (KB5126300)'))
$zeroErr = ""; $threw = $false; try { $resZero = Invoke-PatchAcquisition -Options ([pscustomobject]@{ OsName = 'TestOS3'; Root = $base; Mode = 'Download'; DryRun = $true; LCU = $false; NetCU = $false; SafeOS = $true; SetupDU = $true }) -Definition $zeroDef -Paths $paths3 } catch { $threw = $true; $zeroErr = $_.Exception.Message }
Check 'a search with no results does not stop the run' (-not $threw) $zeroErr
Check 'the empty class is reported as skipped, and the next class still ran' (-not $threw -and @($resZero.SkippedClasses | Where-Object { $_ -like "SafeOS (no catalog result matched 'search-nothing')" }).Count -eq 1 -and @($resZero.Plan | Where-Object { $_.Class -eq 'SetupDU' -and $_.Kb -eq 'KB5126300' }).Count -eq 1)

# A download whose file name says x86 (should never happen after the title check, but is removed if it does).
Reset-Test
$script:CatalogResults['search-real-netcu'] = @((Real-Result $t64))
$script:CatalogFileNames[$t64] = @('windows10.0-kb5126043-x64.msu', 'windows10.0-kb5126043-x86.msu')
$resMixed = Invoke-PatchAcquisition -Options ([pscustomobject]@{ OsName = 'TestOS3'; Root = $base; Mode = 'Download'; DryRun = $false; LCU = $false; NetCU = $true; SafeOS = $false; SetupDU = $false }) -Definition $realDef -Paths $paths3
Check 'a downloaded file named for another architecture is removed and not reported as downloaded' (-not (Test-Path (Join-Path $paths3.Patches 'NETCU\windows10.0-kb5126043-x86.msu')) -and @($resMixed.Downloaded).Count -eq 1 -and ($script:LogLines -match 'removing windows10.0-kb5126043-x86.msu'))

# Servicing: the 4.8 part of the combined .NET CU does not apply to an image with only 4.7.2 (CBS_E_NOT_APPLICABLE).
Reset-Test
function Add-WindowsPackage { [CmdletBinding()] param($Path, [Parameter(Mandatory)][ValidateNotNullOrEmpty()]$PackagePath, $LogPath)
    if ($PackagePath -like '*ndp48*') { throw 'Add-WindowsPackage failed. Error code = 0x800f081e. The specified package is not applicable to this image.' }
    Note ("AddPkg $(Split-Path $PackagePath -Leaf) @ $(Split-Path $Path -Leaf)") }
$svcDir = Join-Path $base 'svc_netcu'
New-File (Join-Path $svcDir 'windows10.0-kb5126043-x64.msu'); New-File (Join-Path $svcDir 'windows10.0-kb5126048-x64-ndp48.msu')
$pkgs = @(Get-ChildItem $svcDir -File | Sort-Object Name)
$threw = $false; try { Add-Packages -MountPath (Join-Path $base 'mnt') -Packages $pkgs -Target 'install.wim index 1' -Label '.NET CU' -SkipNotApplicable } catch { $threw = $true }
Check '-SkipNotApplicable: the not-applicable 4.8 part is skipped with a WARN, the 4.7.2 part still applied' (-not $threw -and ($script:Calls -match '^AddPkg windows10.0-kb5126043-x64.msu') -and ($script:LogLines -match 'Skipped \.NET CU windows10.0-kb5126048-x64-ndp48.msu: not applicable'))
$threw = $false; try { Add-Packages -MountPath (Join-Path $base 'mnt') -Packages $pkgs -Target 'install.wim index 1' -Label 'LCU (final)' } catch { $threw = $true }
Check 'without -SkipNotApplicable (every other class) a not-applicable package still fails the run' $threw

Write-Host "`nRESULT: $pass passed, $fail failed"
