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
function Get-MSCatalogUpdate { [CmdletBinding()] param([string]$Search) Note "CatalogSearch $Search"; return @($script:CatalogResults[$Search]) }
$script:CatalogFileNames = @{}
function Save-MSCatalogUpdate { [CmdletBinding()] param($Update, [string]$Destination, [switch]$Confirm)
    Note "CatalogSave $($Update.Title) -> $Destination"
    New-Item -ItemType Directory -Force $Destination | Out-Null
    $name = $script:CatalogFileNames[$Update.Title]; if (-not $name) { $name = 'download.msu' }
    Set-Content (Join-Path $Destination $name) 'downloaded'
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

Write-Host "`nRESULT: $pass passed, $fail failed"
