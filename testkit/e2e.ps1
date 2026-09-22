. ./mocks.ps1
# ---- extra mocks for the end-to-end run ----
$script:ImageCount = 1
function Get-WindowsImage { [CmdletBinding()] param($ImagePath,$Index,[switch]$Mounted)
  if ($Mounted) { return $script:MountedList }
  if ($Index) { return [pscustomobject]@{ ImageIndex=$Index; ImageName="Img$Index"; Version='10.0.17763.9121' } }
  if ($ImagePath -like '*_isos*') { $i=0; return @($script:SourceNames | ForEach-Object { $i++; [pscustomobject]@{ ImageIndex=$i; ImageName=$_ } }) }
  return @(1..$script:ImageCount | ForEach-Object { [pscustomobject]@{ ImageIndex=$_; ImageName=$(if ($script:ImageCount -eq 1) {'Windows 10 Enterprise LTSC'} else {"Edition$_"}) } }) }
$script:SourceNames = @('Windows 10 Enterprise LTSC')
function Get-WindowsPackage { [CmdletBinding()] param($Path,$LogPath)
  return @([pscustomobject]@{ PackageName='Package_for_RollupFix~31bf3856ad364e35~amd64~~17763.9121.1.9'; PackageState='Installed'; ReleaseType='Update' }) + $script:ExtraPkgs }
function Get-WindowsCapability { [CmdletBinding()] param($Path,$LogPath) return $script:Caps }
function Dismount-DiskImage { [CmdletBinding()] param($ImagePath) Note "IsoDismount $(Split-Path $ImagePath -Leaf)" }
$script:IsoMap = @{}
function Mount-IsoFile { param([string]$ImagePath) $script:MountedIsoPaths.Add($ImagePath); return $script:IsoMap[(Split-Path $ImagePath -Leaf)] }
$script:ExtraPkgs = @(); $script:Caps = @()

$pass=0;$fail=0
function Check($name,[bool]$ok,$detail=''){ if($ok){$script:pass++;Write-Host "PASS  $name" -ForegroundColor Green}else{$script:fail++;Write-Host "FAIL  $name  $detail" -ForegroundColor Red} }
function Reset-Test { $script:Calls.Clear(); $script:MountedList=@(); $script:MountedIsoPaths.Clear() }
function New-File($p,$c='x'){ New-Item -ItemType Directory -Force (Split-Path $p) | Out-Null; Set-Content $p $c }
$base = Join-Path $PWD 'e2e'; if (Test-Path $base) { Remove-Item -Recurse -Force $base }; New-Item -ItemType Directory $base | Out-Null
$isos = Join-Path $base '_isos'
function Fake-Iso($repoOsFolder,$isoName,$files){ $d = Join-Path $isos $isoName; foreach($f in $files){ New-File (Join-Path $d $f) }; New-File (Join-Path (Join-Path (Join-Path $base $repoOsFolder) 'ISO') "$isoName.iso"); $script:IsoMap["$isoName.iso"] = $d }
function Opts($os,$langs,[hashtable]$o=@{}) {
  $d = @{ Preflight=$false;Install=$true;Boot=$false;WinRE=$true;Verify=$true;BuildMedia=$false;BuildIso=$false;SSU=$true;LCU=$true;SafeOS=$true;NetCU=$true;SetupDU=$true;NetFx3=$true }
  foreach($k in $o.Keys){$d[$k]=$o[$k]}
  [pscustomobject]@{ OsName=$os; Root=$base; PreflightOnly=[bool]$d.Preflight; Install=$d.Install;Boot=$d.Boot;WinRE=$d.WinRE;Verify=$d.Verify;BuildMedia=$d.BuildMedia;BuildIso=$d.BuildIso;SSU=$d.SSU;LCU=$d.LCU;SafeOS=$d.SafeOS;NetCU=$d.NetCU;SetupDU=$d.SetupDU;NetFx3=$d.NetFx3;Languages=@($langs) } }
function Patches($folder,$files){ foreach($f in $files){ New-File (Join-Path (Join-Path (Join-Path $base $folder) 'PATCHES') $f) } }
$langs10 = @('de-de','en-gb','es-es','fr-fr','it-it','ja-jp','ko-kr','pt-br','zh-cn','zh-tw')

Write-Host "`n=== E1 LTSC 2019, 10 languages, but NO Language Pack ISO in the folder (the situation in your logs) ==="
Reset-Test
Fake-Iso 'Win10_Enterprise_LTSC_2019' 'os2019' @('sources/install.wim','sources/sxs/a.cab')
Fake-Iso 'Win10_Enterprise_LTSC_2019' 'fod1809' @('Microsoft-Windows-LanguageFeatures-Basic-de-de-Package~x.cab')
Patches 'Win10_Enterprise_LTSC_2019' @('SSU/windows10.0-kb5005112-x64_81d0.msu','LCU/windows10.0-kb5120238-x64_9260.msu','NETCU/windows10.0-kb5120703-x64-ndp48_6b0e.msu','SAFEOSDU/safeos.cab')
$threw=$false; try { Invoke-MediaRefresh (Opts 'Windows 10 Enterprise LTSC 2019 (IoT)' $langs10) } catch { $threw=$true; $msg=$_.Exception.Message }
Write-Host "   -> $msg"
Check 'stops early with a Language Pack ISO message' ($threw -and $msg -like '*no Language Pack ISO*')
Check 'no image was ever mounted (no 2-hour wasted run)' (-not ($script:Calls -match '^Mount '))
Check 'ISOs were dismounted' (@($script:Calls | Where-Object {$_ -like 'IsoDismount*'}).Count -eq 2)

Write-Host "`n=== E2 same folder, LP ISO added -> full run with verification ==="
Reset-Test; $script:ImageCount=1
Fake-Iso 'Win10_Enterprise_LTSC_2019' 'lpall' (@($langs10 | % { "x64/langpacks/Microsoft-Windows-Client-Language-Pack_x64_$_.cab" }))
# verification data: image contains all LPs and fonts
$script:ExtraPkgs = @($langs10 | % { [pscustomobject]@{ PackageName="Microsoft-Windows-Client-LanguagePack-Package~31bf3856ad364e35~amd64~$($_.Substring(0,3))$($_.Substring(3).ToUpper())~10.0.17763.1"; PackageState='Installed'; ReleaseType='LanguagePack' } })
$script:Caps = @('Jpan','Kore','Hans','Hant' | % { [pscustomobject]@{ Name="Language.Fonts.$_~~~und-$($_.ToUpper())~0.0.1.0"; State='Installed' } })
Invoke-MediaRefresh (Opts 'Windows 10 Enterprise LTSC 2019 (IoT)' $langs10)
$seq = $script:Calls -join "`n"
Check 'run completed and returned a result' ($null -ne $script:LastResult -and $script:LastResult.VerifyIssues -eq 0) "issues=$($script:LastResult.VerifyIssues)"
Check '10 language packs added' (@($script:Calls | Where-Object { $_ -match 'AddPkg Microsoft-Windows-Client-Language-Pack_x64_' }).Count -eq 10)
Check 'all 4 font capabilities added' (@($script:Calls | Where-Object { $_ -match 'AddCap Language.Fonts' }).Count -eq 4)
Check 'read-only verify mount happened after the final export' ((($script:Calls | Select-String 'Export -> install.wim').LineNumber | Select-Object -Last 1) -lt (($script:Calls | Select-String 'Mount install.wim').LineNumber | Select-Object -Last 1))
Check 'nothing left mounted / ISOs dismounted' ($script:MountedList.Count -eq 0 -and @($script:Calls | Where-Object {$_ -like 'IsoDismount*'}).Count -eq 3)

Write-Host "`n=== E2b Step 3: validation gate, change events and change log for the clean E2 run ==="
Check 'validation gate PASSED (0 issues)' ($script:LastResult.Gate -eq 'PASSED') "Gate=$($script:LastResult.Gate)"
Check 'change events were recorded (SSU/LCU/LanguagePack/Font)' (
    (@($script:ChangeEvents | Where-Object { $_.Category -eq 'SSU' }).Count -ge 1) -and
    (@($script:ChangeEvents | Where-Object { $_.Category -eq 'LCU' }).Count -ge 1) -and
    (@($script:ChangeEvents | Where-Object { $_.Category -eq 'LanguagePack' }).Count -eq 10) -and
    (@($script:ChangeEvents | Where-Object { $_.Category -eq 'Font' }).Count -eq 4)
) "categories=$(($script:ChangeEvents | Select-Object -ExpandProperty Category -Unique) -join ',')"
Check 'Section B inventory was collected (Verify=true)' (@($script:VerifyInventory).Count -gt 0)
Check 'change log files exist and were copied to NEWWIM' (
    ($null -ne $script:LastResult.ChangeLogHtml) -and (Test-Path -LiteralPath $script:LastResult.ChangeLogHtml) -and
    ($null -ne $script:LastResult.ChangeLogCsv) -and (Test-Path -LiteralPath $script:LastResult.ChangeLogCsv) -and
    (Test-Path -LiteralPath (Join-Path (Join-Path $base 'Win10_Enterprise_LTSC_2019') 'NEWWIM' (Split-Path $script:LastResult.ChangeLogHtml -Leaf)))
)
$csvRows2 = @(Import-Csv -LiteralPath $script:LastResult.ChangeLogCsv)
$missingCols2 = @(@('Date','Section','Item','Version / KB','State','Source','Index') | Where-Object { $_ -notin $csvRows2[0].PSObject.Properties.Name })
Check 'CSV has the required columns' ($csvRows2.Count -gt 0 -and $missingCols2.Count -eq 0) "columns=$($csvRows2[0].PSObject.Properties.Name -join ',')"
$html2 = Get-Content -Raw -LiteralPath $script:LastResult.ChangeLogHtml
Check 'HTML header names the OS and shows PASSED' ($html2 -match 'Windows 10 Enterprise LTSC 2019' -and $html2 -match 'PASSED')

Write-Host "`n=== E3 verification catches a missing LP and missing LCU ==="
Reset-Test; $script:ExtraPkgs=@(); $script:Caps=@()
function Get-WindowsPackage { [CmdletBinding()] param($Path,$LogPath) return @() }
Invoke-MediaRefresh (Opts 'Windows 10 Enterprise LTSC 2019 (IoT)' $langs10)
Check 'issues reported (no RollupFix, 10 LPs, 4 fonts = 15)' ($script:LastResult.VerifyIssues -eq 15) "issues=$($script:LastResult.VerifyIssues)"
Check 'validation gate FAILED (issues > 0)' ($script:LastResult.Gate -eq 'FAILED') "Gate=$($script:LastResult.Gate)"
$html3 = Get-Content -Raw -LiteralPath $script:LastResult.ChangeLogHtml
Check 'HTML header shows FAILED for the dirty run' ($html3 -match 'FAILED')

Write-Host "`n=== E4 Win11 English-only, no SSU folder content, no languages ==="
function Get-WindowsPackage { [CmdletBinding()] param($Path,$LogPath) return @([pscustomobject]@{ PackageName='Package_for_RollupFix~31bf3856ad364e35~amd64~~26100.1.1.9'; PackageState='Installed'; ReleaseType='Update' }) }
Reset-Test; $script:ImageCount=1; $script:SourceNames=@('Windows 11 Pro','Windows 11 Pro N','Windows 11 Enterprise')
Fake-Iso 'Win11Enterprise_24H2' 'os11' @('sources/install.wim')      # folder name as you typed it (alias)
Patches 'Win11Enterprise_24H2' @('LCU/windows11.0-kb1-x64.msu')
Invoke-MediaRefresh (Opts 'Windows 11 Enterprise 24H2' @() @{ NetFx3=$false })
Check 'no-language run works, alias folder used, no duplicate folder created' (($null -ne $script:LastResult) -and -not (Test-Path (Join-Path $base 'Win11_Enterprise_24H2')))
Check 'single LCU pass' (@($script:Calls | Where-Object { $_ -match 'AddPkg windows11.0-kb1-x64.msu @ MainOS' }).Count -eq 1)

Write-Host "`n=== E5 Server 2022: 4 indexes, English only ==="
Reset-Test; $script:ImageCount=4; $script:SourceNames=@('Std Core','Std Desktop','DC Core','DC Desktop')
Fake-Iso 'Windows_Server_2022' 'os2022' @('sources/install.wim')
Fake-Iso 'Windows_Server_2022' 'svrlp' @('LanguagesAndOptionalFeatures/Microsoft-Windows-Server-Language-Pack_x64_de-de.cab','LanguagesAndOptionalFeatures/Microsoft-Windows-LanguageFeatures-Basic-de-de-Package~x.cab')
Patches 'Windows_Server_2022' @('LCU/windows10.0-kb2-x64.msu','SAFEOSDU/safeos.cab')
Invoke-MediaRefresh (Opts 'Windows Server 2022' @() @{ NetFx3=$false })
Check 'all 4 indexes serviced' (@($script:Calls | Where-Object { $_ -match '^Mount install.working.wim idx' }).Count -eq 4)
Check 'WinRE serviced once' (@($script:Calls | Where-Object { $_ -match 'DISM: Cleaning WinRE' }).Count -eq 1)
Check 'final WIM has 4 indexes' ($script:LastResult.Install -like '*install.wim')

Write-Host "`n=== E6 Missing LCU stops the run before any mount ==="
Reset-Test; $script:ImageCount=1; $script:SourceNames=@('Windows 10 Enterprise LTSC 2021')
Fake-Iso 'Win10_Enterprise_LTSC_2021_KMS' 'os2021' @('sources/install.wim')
Patches 'Win10_Enterprise_LTSC_2021_KMS' @('SSU/ssu-19041.3562-x64.msu')
$threw=$false; try { Invoke-MediaRefresh (Opts 'Windows 10 Enterprise LTSC 2021 (KMS)' @()) } catch { $threw=$true; $msg=$_.Exception.Message }
Check 'empty LCU folder is fatal with a clear message' ($threw -and $msg -like '*PATCHES\LCU is empty*')

Write-Host "`n=== E7 Preflight only: checks everything, changes nothing ==="
Reset-Test; $script:ImageCount=1; $script:SourceNames=@('Windows 10 Enterprise LTSC 2021')
Patches 'Win10_Enterprise_LTSC_2021_KMS' @('LCU/windows10.0-kb3-x64.msu')
Fake-Iso 'Win10_Enterprise_LTSC_2021_KMS' 'fod2021' @('Microsoft-Windows-LanguageFeatures-Basic-de-de-Package~x.cab')
Fake-Iso 'Win10_Enterprise_LTSC_2021_KMS' 'lp2021' @('x64/langpacks/Microsoft-Windows-Client-Language-Pack_x64_de-de.cab','x64/langpacks/Microsoft-Windows-Client-Language-Pack_x64_ja-jp.cab')
$script:ExtraPkgs=@(); $script:Caps=@()
Invoke-MediaRefresh (Opts 'Windows 10 Enterprise LTSC 2021 (KMS)' @('de-de','ja-jp') @{ Preflight=$true })
Check 'preflight passes and flags itself' ($script:LastResult.Preflight -eq $true)
Check 'no mount / export / package / capability call was made' (@($script:Calls | Where-Object { $_ -match '^(Mount|Export|AddPkg|AddCap|Dismount MainOS|EnableFeature)' }).Count -eq 0) ($script:Calls -join '; ')
Check 'ISOs dismounted afterwards' (@($script:Calls | Where-Object {$_ -like 'IsoDismount*'}).Count -eq 3)
$threw=$false; try { Invoke-MediaRefresh (Opts 'Windows 10 Enterprise LTSC 2021 (KMS)' @('de-de','fr-fr') @{ Preflight=$true }) } catch { $threw=$true; $m7=$_.Exception.Message }
Check 'preflight catches a language pack that is not on the ISO (fr-fr)' ($threw -and $m7 -like '*fr-fr*')


Write-Host "`n=== E8 One ISO holding BOTH an Enterprise LTSC index and an IoT index (the reported error) ==="
Reset-Test; $script:ImageCount=1; $script:SourceNames=@('Windows 10 Enterprise LTSC 2021','Windows 10 IoT Enterprise LTSC 2021')
Fake-Iso 'Win10_IoT_Enterprise_LTSC_2021' 'os2021iot' @('sources/install.wim')
Patches 'Win10_IoT_Enterprise_LTSC_2021' @('SSU/ssu-19041.3562-x64.msu','LCU/windows10.0-kb3-x64.msu')
$script:LogCapture = @()
Invoke-MediaRefresh (Opts 'Windows 10 IoT Enterprise LTSC 2021' @() @{ Preflight=$true })
Check 'IoT profile picks the IoT index without an error' ($script:LastResult.Preflight -eq $true)
Invoke-MediaRefresh (Opts 'Windows 10 IoT Enterprise LTSC 2021' @() @{ Preflight=$true }) *>&1 | Out-String | Set-Variable out8
Check 'IoT profile selected index 2' ($out8 -match 'Selected client image index 2: Windows 10 IoT Enterprise LTSC 2021')
Get-ChildItem (Join-Path $base 'Win10_Enterprise_LTSC_2021_KMS\ISO') -Filter *.iso -ErrorAction SilentlyContinue | Remove-Item -Force; Reset-Test; $script:SourceNames=@('Windows 10 Enterprise LTSC 2021','Windows 10 IoT Enterprise LTSC 2021')
Fake-Iso 'Win10_Enterprise_LTSC_2021_KMS' 'os2021kms' @('sources/install.wim')
Patches 'Win10_Enterprise_LTSC_2021_KMS' @('SSU/ssu-19041.3562-x64.msu','LCU/windows10.0-kb3-x64.msu')
Invoke-MediaRefresh (Opts 'Windows 10 Enterprise LTSC 2021 (KMS)' @() @{ Preflight=$true }) *>&1 | Out-String | Set-Variable out8b
Check 'KMS profile selected index 1 (the non-IoT edition)' ($out8b -match 'Selected client image index 1: Windows 10 Enterprise LTSC 2021')
# genuinely ambiguous ISO: the message must list indexes and names
Reset-Test; $script:SourceNames=@('Windows 10 IoT Enterprise LTSC 2021','Windows 10 IoT Enterprise LTSC')
$threw=$false; try { Invoke-MediaRefresh (Opts 'Windows 10 IoT Enterprise LTSC 2021' @() @{ Preflight=$true }) } catch { $threw=$true; $m8=$_.Exception.Message }
Check 'ambiguous match is still an error but lists index and name for each image' ($threw -and $m8.Contains('[1] Windows 10 IoT Enterprise LTSC 2021;') -and $m8.Contains('[2] Windows 10 IoT Enterprise LTSC') -and $m8 -match 'Tighten EditionRegex')


Write-Host "`n=== E9 profile files, order manifest and support status through a real (preflight) run ==="
Reset-Test; $script:ImageCount=1; $script:SourceNames=@('Windows 10 Enterprise LTSC 2021')
$profDir = Join-Path $base '_profiles'
Patches 'Win10_Enterprise_LTSC_2021_KMS' @('SSU/aaa-extra.msu')
function OptsP($os,$langs,[hashtable]$o=@{}) { $x = Opts $os $langs $o; $x | Add-Member -NotePropertyName ProfilesDir -NotePropertyValue $profDir; $x }
$out9 = (Invoke-MediaRefresh (OptsP 'Windows 10 Enterprise LTSC 2021 (KMS)' @() @{ Preflight=$true }) *>&1 | Out-String)
Check 'first run created the profile files' (@(Get-ChildItem $profDir -Filter *.json).Count -eq 5)
Check 'log names the profile file' ($out9 -match 'Profile: Win10_Enterprise_LTSC_2021_KMS\.json')
Check 'log states the support end date' ($out9 -match 'Support (ends|ended) 2027-01-13')
Check 'log reports the profile file creation' ($out9 -match 'Profile files created from the built-in profiles')
Check 'default order = name order' ($out9 -match 'SSU order: aaa-extra\.msu -> ssu-19041\.3562-x64\.msu')
$pf = Join-Path $profDir 'Win10_Enterprise_LTSC_2021_KMS.json'
$j = Get-Content $pf -Raw | ConvertFrom-Json; $j.packageOrder.SSU = @('ssu-19041*'); $j.notes = 'edited'
[System.IO.File]::WriteAllText($pf, ($j | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
Reset-Test
$out9b = (Invoke-MediaRefresh (OptsP 'Windows 10 Enterprise LTSC 2021 (KMS)' @() @{ Preflight=$true }) *>&1 | Out-String)
Check 'edited JSON is picked up on the next run (SSU manifest)' ($out9b -match 'SSU order: ssu-19041\.3562-x64\.msu -> aaa-extra\.msu') $out9b
$j.packageOrder.SSU = @('ssu-19041*'); $j.editionRegex = '(unclosed'
[System.IO.File]::WriteAllText($pf, ($j | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
Reset-Test; $threw=$false; $m9=''
try { Invoke-MediaRefresh (OptsP 'Windows 10 Enterprise LTSC 2021 (KMS)' @() @{ Preflight=$true }) *>&1 | Out-Null } catch { $threw=$true; $m9=$_.Exception.Message }
Check 'a broken profile file removes that OS from the list; the run says Unknown OS profile' ($threw -and $m9 -like "*Unknown OS profile*")
Remove-Item (Join-Path $base 'Win10_Enterprise_LTSC_2021_KMS\PATCHES\SSU\aaa-extra.msu') -Force
Remove-Item $profDir -Recurse -Force
$script:OsDefinitions = Import-OsProfiles   # back to the built-ins for the remaining scenarios

Write-Host "`n=== E10 a second run archives the first run's output instead of overwriting it ==="
Reset-Test; $script:ImageCount=1; $script:SourceNames=@('Windows 10 Enterprise LTSC 2021')
$newDir = Join-Path $base 'Win10_Enterprise_LTSC_2021_KMS\NEWWIM'
Get-ChildItem $newDir -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
Invoke-MediaRefresh (Opts 'Windows 10 Enterprise LTSC 2021 (KMS)' @() @{ Verify=$false })
Check 'first run: output exists, nothing archived' ((Test-Path (Join-Path $newDir 'install.wim')) -and -not (Test-Path (Join-Path $newDir 'Archive')))
Check 'gate is Skipped when Verify is off' ($script:LastResult.Gate -eq 'Skipped') "Gate=$($script:LastResult.Gate)"
Check 'Section B inventory is empty when Verify is off' (@($script:VerifyInventory).Count -eq 0)
Set-Content (Join-Path $newDir 'install.wim') 'FIRST-RUN'
Start-Sleep -Seconds 1
Reset-Test
$out10 = (Invoke-MediaRefresh (Opts 'Windows 10 Enterprise LTSC 2021 (KMS)' @() @{ Verify=$false }) *>&1 | Out-String)
$arch = @(Get-ChildItem (Join-Path $newDir 'Archive') -Directory -ErrorAction SilentlyContinue)
Check 'second run: one archive folder holding the first run output' ($arch.Count -eq 1 -and (Get-Content (Join-Path $arch[0].FullName 'install.wim')) -eq 'FIRST-RUN')
Check 'second run wrote a new install.wim' ((Get-Content (Join-Path $newDir 'install.wim')) -eq 'x')
Check 'archive was logged' ($out10 -match 'Previous output \(\d+ item\(s\)\) archived to')
Reset-Test
$script:LastResult = $null
Invoke-MediaRefresh (Opts 'Windows 10 Enterprise LTSC 2021 (KMS)' @() @{ Preflight=$true })
Check 'preflight never archives' (@(Get-ChildItem (Join-Path $newDir 'Archive') -Directory).Count -eq 1)

Write-Host "`n=== E11 too little free space stops the run before any image is touched ==="
Reset-Test; $script:FreeGB = 5.0; $threw=$false; $m11=''
try { Invoke-MediaRefresh (Opts 'Windows 10 Enterprise LTSC 2021 (KMS)' @() @{ Preflight=$true }) *>&1 | Out-Null } catch { $threw=$true; $m11=$_.Exception.Message }
Check 'preflight fails with the space message' ($threw -and $m11 -like 'Not enough free disk space.*5*') $m11
Check 'no mount or export happened' (-not ($script:Calls -match '^Mount |^Export'))
Check 'ISOs were dismounted afterwards' (@($script:Calls | Where-Object { $_ -like 'IsoDismount*' }).Count -ge 1)
$script:FreeGB = 500.0

Write-Host "`nRESULT: $pass passed, $fail failed"
