Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$src = Get-Content -Raw $(if ($env:MR_SCRIPT) { $env:MR_SCRIPT } else { (Join-Path $PSScriptRoot '../MediaRefresh_v2.4.ps1') })
$m = [regex]::Match($src, '(?s)#region ENGINE(.*?)#endregion ENGINE')
$tmp = Join-Path $PWD 'engine_only.ps1'; Set-Content $tmp $m.Groups[1].Value
. $tmp

$script:Calls = [System.Collections.Generic.List[string]]::new()
$script:MountedList = @()
function Note($s) { $script:Calls.Add($s) }
function Write-Log { param($Message,$Level='INFO') Write-Host ("   [{0}] {1}" -f $Level,$Message) }
# ---- mocks for DISM cmdlets / dism.exe ----
function Mount-WindowsImage { [CmdletBinding()] param($ImagePath,$Index,$Path,[switch]$CheckIntegrity,[switch]$ReadOnly,$LogPath)
  Note ("Mount $(Split-Path $ImagePath -Leaf) idx$Index -> $(Split-Path $Path -Leaf)")
  New-Item -ItemType Directory -Force (Join-Path $Path 'Windows/System32/Recovery') | Out-Null
  Set-Content (Join-Path $Path 'Windows/System32/Recovery/winre.wim') 'orig'
  $script:MountedList += [pscustomobject]@{ Path = $Path + '\'; MountStatus='Ok' } }   # trailing backslash on purpose
function Dismount-WindowsImage { [CmdletBinding()] param($Path,[switch]$Save,[switch]$Discard,[switch]$CheckIntegrity,$LogPath)
  Note ("Dismount $(Split-Path $Path -Leaf) " + $(if($Save){'save'}else{'discard'}))
  $script:MountedList = @($script:MountedList | Where-Object { (Get-NormalizedPath $_.Path) -ne (Get-NormalizedPath $Path) })
  Get-ChildItem $Path -Force | Remove-Item -Recurse -Force }
function Get-WindowsImage { [CmdletBinding()] param($ImagePath,$Index,[switch]$Mounted)
  if ($Mounted) { return $script:MountedList }
  if ($Index) { return [pscustomobject]@{ ImageIndex=$Index; ImageName="Img$Index"; Version='10.0.17763.9121' } }
  return @([pscustomobject]@{ ImageIndex=1; ImageName='Img1' }) }
function Add-WindowsPackage { [CmdletBinding()] param($Path,[Parameter(Mandatory)][ValidateNotNullOrEmpty()]$PackagePath,$LogPath)
  Note ("AddPkg $(Split-Path $PackagePath -Leaf) @ $(Split-Path $Path -Leaf)") }
function Add-WindowsCapability { [CmdletBinding()] param($Name,$Path,$Source,[switch]$LimitAccess,$LogPath) Note "AddCap $Name" }
function Enable-WindowsOptionalFeature { [CmdletBinding()] param($Path,$FeatureName,[switch]$All,$Source,[switch]$LimitAccess,$LogPath) Note "EnableFeature $FeatureName" }
function Export-WindowsImage { [CmdletBinding()] param($SourceImagePath,$SourceIndex,$DestinationImagePath,$DestinationName,$CompressionType,[switch]$CheckIntegrity,$LogPath)
  Note "Export -> $(Split-Path $DestinationImagePath -Leaf)"; Set-Content $DestinationImagePath 'x' }
function Get-WindowsPackage { [CmdletBinding()] param($Path,$LogPath) return @() }
function Invoke-DismExe { param([string[]]$Arguments,[string]$Description,[switch]$AllowPending) Note "DISM: $Description" }

$pass = 0; $fail = 0
function Check($name, [bool]$ok, $detail='') { if ($ok) { $script:pass++; Write-Host "PASS  $name" -ForegroundColor Green } else { $script:fail++; Write-Host "FAIL  $name  $detail" -ForegroundColor Red } }
function Reset-Test { $script:Calls.Clear(); $script:MountedList=@() }

$root = Join-Path $PWD 'tst'; if (Test-Path $root) { Remove-Item -Recurse -Force $root }; New-Item -ItemType Directory $root | Out-Null
function New-File($p,$c='x') { New-Item -ItemType Directory -Force (Split-Path $p) | Out-Null; Set-Content $p $c }

Write-Host "`n=== T1 Add-Packages null / empty / multi ==="
Reset-Test
Add-Packages 'C:\m' $null 'tgt' -Label 'SSU'
Add-Packages 'C:\m' @() 'tgt' -Label 'SSU'
Check 'null and empty are skipped without calling DISM' ($script:Calls.Count -eq 0)
Add-Packages 'C:\m' @([pscustomobject]@{FullName='/x/a.msu'},[pscustomobject]@{FullName='/x/b.msu'}) 'tgt' -Label 'LCU'
Check 'two packages -> two adds' ($script:Calls.Count -eq 2)

Write-Host "`n=== T2 Get-PackageSet / Test-PackageSet ==="
$pr = Join-Path $root 'PATCHES'; foreach ($d in 'LCU','SSU','NETCU','SAFEOSDU','SETUPDU') { New-Item -ItemType Directory -Force (Join-Path $pr $d) | Out-Null }
New-File (Join-Path $pr 'LCU/windows10.0-kb1-x64.msu')
$en = @{ LCU=$true; SSU=$true; NetCU=$true; SafeOS=$true; SetupDU=$true }
$set = Get-PackageSet -PatchRoot $pr -Enabled $en
Check 'empty folders give empty arrays, not $null' (($set.SSU -is [array]) -and $set.SSU.Count -eq 0 -and $set.LCU.Count -eq 1)
$legacy = $script:OsDefinitions['Windows 10 Enterprise LTSC 2019 (IoT)']; $w11 = $script:OsDefinitions['Windows 11 Enterprise 24H2']
$threw = $false; try { Test-PackageSet $legacy $set $en $false $false } catch { $threw = $true; $msg = $_.Exception.Message }
Check 'legacy OS with empty SSU folder stops early' $threw
$threw = $false; try { Test-PackageSet $w11 $set $en $false $false } catch { $threw = $true }
Check 'Win11 with empty SSU folder does NOT stop' (-not $threw)
New-File (Join-Path $pr 'SSU/ssu-19041.3562-x64.msu'); $set = Get-PackageSet -PatchRoot $pr -Enabled $en
$threw = $false; try { Test-PackageSet $legacy $set $en $false $false } catch { $threw = $true }
Check 'legacy OS with SSU present passes' (-not $threw)
$set2 = Get-PackageSet -PatchRoot $pr -Enabled @{ LCU=$false; SSU=$false; NetCU=$false; SafeOS=$false; SetupDU=$false }
Check 'unticked types give empty arrays' ($set2.LCU.Count -eq 0)

Write-Host "`n=== T3 Get-IsoRoleMap with the user's ISO layouts ==="
$isoRoot = Join-Path $root 'iso'
function Make-Iso($name,[string[]]$files) { $d = Join-Path $isoRoot $name; foreach ($f in $files) { New-File (Join-Path $d $f) }; [pscustomobject]@{ Path="/x/$name.iso"; Drive=$d } }
$os   = Make-Iso 'os2019'  @('sources/install.wim','sources/sxs/x.cab')
$fod  = Make-Iso 'fod1809' @('Microsoft-Windows-LanguageFeatures-Basic-de-de-Package~31bf3856ad364e35~amd64~~.cab','metadata/a.cab')
$lp   = Make-Iso 'lpall'   @('x64/langpacks/Microsoft-Windows-Client-Language-Pack_x64_de-de.cab','x64/langpacks/Microsoft-Windows-Client-Language-Pack_x64_ja-jp.cab','x86/langpacks/Microsoft-Windows-Client-Language-Pack_x86_de-de.cab')
$svr  = Make-Iso 'svrlp'   @('LanguagesAndOptionalFeatures/Microsoft-Windows-Server-Language-Pack_x64_de-de.cab','LanguagesAndOptionalFeatures/Microsoft-Windows-LanguageFeatures-Basic-de-de-Package~x.cab')
$junk = Make-Iso 'junk'    @('readme.txt')
$r = Get-IsoRoleMap @($os,$fod)
Check '2019 folder (OS + FOD): OS and FOD found, no LP' (($r.OsDrive -eq $os.Drive) -and ($r.FodDrive -eq $fod.Drive) -and ($null -eq $r.LpDrive))
$r = Get-IsoRoleMap @($os,$lp)
Check 'IoT 2021 folder (OS + LangPackAll): LangPackAll is an LP ISO, not a 2nd OS ISO' (($r.OsDrive -eq $os.Drive) -and ($r.LpDrive -eq $lp.Drive) -and ($null -eq $r.FodDrive))
$r = Get-IsoRoleMap @($os,$lp,$fod)
Check 'OS + LP + FOD all resolved' (($r.LpDrive -eq $lp.Drive) -and ($r.FodDrive -eq $fod.Drive))
$r = Get-IsoRoleMap @($os,$svr)
Check 'Server combined LP+FOD ISO fills both roles' (($r.LpDrive -eq $svr.Drive) -and ($r.FodDrive -eq $svr.Drive))
$r = Get-IsoRoleMap @($os,$junk)
Check 'unrecognised ISO is reported, not fatal' ($r.Unclassified.Count -eq 1)
$threw=$false; try { Get-IsoRoleMap @($os,$os) | Out-Null } catch { $threw=$true }
Check 'two OS ISOs is an error' $threw
$threw=$false; try { Get-IsoRoleMap @($fod) | Out-Null } catch { $threw=$true }
Check 'no OS ISO is an error' $threw
$fs1 = @(Get-FodSource @($svr.Drive)); $fs2 = @(Get-FodSource @($fod.Drive)); $fs3 = @(Get-FodSource @($svr.Drive,$fod.Drive))
Check 'Get-FodSource: prefers LanguagesAndOptionalFeatures, else root, one entry per ISO' (($fs1.Count -eq 1 -and $fs1[0] -like '*LanguagesAndOptionalFeatures') -and ($fs2.Count -eq 1 -and $fs2[0] -eq $fod.Drive) -and $fs3.Count -eq 2)
# KMS 2021 scenarios: OS + FOD part 1 + LangPackAll (which may or may not carry language features)
$lpWithFeat = Make-Iso 'lpallfeat' @('x64/langpacks/Microsoft-Windows-Client-Language-Pack_x64_de-de.cab','Microsoft-Windows-LanguageFeatures-Basic-de-de-Package~x.cab','Windows Preinstallation Environment/x64/WinPE_OCs/de-de/lp.cab')
$r = Get-IsoRoleMap @($os,$fod,$lp)
Check 'KMS 2021 (OS + FOD1 + LangPackAll without features): LP=LangPackAll, FOD=[FOD1]' (($r.LpDrive -eq $lp.Drive) -and (@($r.FodDrives).Count -eq 1) -and ($r.FodDrives[0] -eq $fod.Drive))
$r = Get-IsoRoleMap @($os,$fod,$lpWithFeat)
Check 'KMS 2021 (LangPackAll that also carries language features): no error, both used as FOD sources' (($r.LpDrive -eq $lpWithFeat.Drive) -and (@($r.FodDrives).Count -eq 2))
$r = Get-IsoRoleMap @($os,$lpWithFeat)
Check 'IoT 2021 (OS + LangPackAll that carries language features): one ISO fills LP and FOD' (($r.LpDrive -eq $lpWithFeat.Drive) -and ($r.FodDrives[0] -eq $lpWithFeat.Drive))
$r = Get-IsoRoleMap @($os,$svr,$lp)
Check 'two LP candidates: the LP-only ISO wins over the combined one' ($r.LpDrive -eq $lp.Drive)
Check 'WinPE OC root found on the LangPackAll ISO' ((Find-WinPeOcRoot @($lpWithFeat.Drive)) -like '*WinPE_OCs')

Write-Host "`n=== T4 Resolve-LanguagePacks ==="
$f = Resolve-LanguagePacks -LpRoot $lp.Drive -Pattern $script:ClientLpPattern -Languages @('de-de','ja-jp')
Check 'finds x64 packs by pattern' ($f.Count -eq 2 -and $f['de-de'] -like '*x64*')
$threw=$false; try { Resolve-LanguagePacks -LpRoot $lp.Drive -Pattern $script:ClientLpPattern -Languages @('de-de','fr-fr','zh-tw') | Out-Null } catch { $threw=$true; $m4=$_.Exception.Message }
Check 'missing packs stop the run and name them' ($threw -and $m4 -like '*fr-fr, zh-tw*')
$f = Resolve-LanguagePacks -LpRoot $svr.Drive -Pattern $script:ServerLpPattern -Languages @('de-de')
Check 'Server pattern finds Server-Language-Pack' ($f.Count -eq 1)

Write-Host "`n=== T5 Test-IsMounted with trailing backslash ==="
Reset-Test; $script:MountedList = @([pscustomobject]@{ Path='F:\x\MOUNT\MainOS\'; MountStatus='Ok' })
Check 'matches with/without trailing backslash' ((Test-IsMounted 'F:\x\MOUNT\MainOS') -and (Test-IsMounted 'F:\x\MOUNT\MainOS\') -and -not (Test-IsMounted 'F:\x\MOUNT\WinRE'))
$mp=(Join-Path $root 'liveMount'); New-Item -ItemType Directory -Force $mp | Out-Null; $script:MountedList=@([pscustomobject]@{ Path=($mp+'\'); MountStatus='Ok' }); $threw=$false; try { Remove-DirectoryContents $mp } catch { $dbg=$_.Exception.Message; $threw = $dbg -like '*still mounted*' }; Write-Host "   dbg: $dbg"
Check 'Remove-DirectoryContents refuses a live mount' $threw

function New-Paths($name) { $b = Join-Path $root $name; $h=@{}; foreach ($k in 'MainMount','WinReMount','WinPeMount','WinRE','Temp','Working') { $h[$k]=Join-Path $b $k; New-Item -ItemType Directory -Force $h[$k] | Out-Null }; $h }
$script:DismLogArgs = @{}

Write-Host "`n=== T5b Service-InstallIndex order: LTSC 2019 with languages, WinRE on, NetFx3 on ==="
Reset-Test; $p = New-Paths 'a'
$pk = @{ SSU=@([pscustomobject]@{FullName='/p/ssu.msu'}); LCU=@([pscustomobject]@{FullName='/p/lcu.msu'}); NetCU=@([pscustomobject]@{FullName='/p/net1.msu'},[pscustomobject]@{FullName='/p/net2.msu'}); SafeOS=@([pscustomobject]@{FullName='/p/safeos.cab'}); SetupDU=@() }
Service-InstallIndex -ImagePath '/w/install.working.wim' -Index 1 -Paths $p -Packages $pk -OsDrive $os.Drive -LpFiles @{ 'de-de'='/lp/de.cab'; 'ja-jp'='/lp/ja.cab' } -FodSource $fod.Drive -OcRoot $null -Languages @('de-de','ja-jp') -DoWinRe $true -DoNetFx3 $true
$seq = ($script:Calls -join "`n")
$script:Calls | ForEach-Object { "      $_" }
function Idx($pattern,$fromIdx=0) { for ($i=$fromIdx; $i -lt $script:Calls.Count; $i++) { if ($script:Calls[$i] -match $pattern) { return $i } }; return -1 }
$iSsu = Idx 'AddPkg ssu.msu @ MainMount'; $iL1 = Idx 'AddPkg lcu.msu @ MainMount'; $iLp = Idx 'AddPkg de.cab'; $iCap = Idx 'AddCap Language.Basic~~~de-de'
$iL2 = Idx 'AddPkg lcu.msu @ MainMount' ($iCap+1); $iClean = Idx 'DISM: Component cleanup'; $iNfx = Idx 'EnableFeature NetFx3'; $iNet = Idx 'AddPkg net1.msu'; $iSave = Idx 'Dismount MainMount save'
Check 'order: SSU < LCU pass1 < LP < FOD < LCU final < cleanup < NetFx3 < .NET CU < save' (($iSsu -lt $iL1) -and ($iL1 -lt $iLp) -and ($iLp -lt $iCap) -and ($iCap -lt $iL2) -and ($iL2 -lt $iClean) -and ($iClean -lt $iNfx) -and ($iNfx -lt $iNet) -and ($iNet -lt $iSave)) "$iSsu $iL1 $iLp $iCap $iL2 $iClean $iNfx $iNet $iSave"
Check 'LCU applied exactly twice (pass 1 + final)' (@($script:Calls | Where-Object { $_ -match 'AddPkg lcu.msu @ MainMount' }).Count -eq 2)
Check 'font capabilities requested for ja-jp only once' (@($script:Calls | Where-Object { $_ -match 'Language.Fonts.Jpan~~~und-JPAN~0.0.1.0' }).Count -eq 1)
Check 'no font capability for de-de' (-not ($seq -match 'Language.Fonts.*de'))
Check 'WinRE serviced (Safe OS DU added to WinRE)' ($seq -match 'AddPkg safeos.cab @ WinReMount')
Check 'SafeOS DU never added to main OS' (-not ($seq -match 'AddPkg safeos.cab @ MainMount'))
Check 'nothing left mounted' ($script:MountedList.Count -eq 0)

Write-Host "`n=== T5c Win11 English-only: single LCU pass, no language calls ==="
Reset-Test; $p = New-Paths 'b'
$pk = @{ SSU=@(); LCU=@([pscustomobject]@{FullName='/p/lcu.msu'}); NetCU=@(); SafeOS=@(); SetupDU=@() }
Service-InstallIndex -ImagePath '/w/i.wim' -Index 1 -Paths $p -Packages $pk -OsDrive $os.Drive -LpFiles @{} -FodSource $null -OcRoot $null -Languages @() -DoWinRe $false -DoNetFx3 $false
$seq = ($script:Calls -join "`n")
Check 'LCU applied once' (@($script:Calls | Where-Object { $_ -match 'AddPkg lcu.msu' }).Count -eq 1)
Check 'no capability / language calls' (-not ($seq -match 'AddCap'))
Check 'cleanup then save' ((Idx 'DISM: Component cleanup') -lt (Idx 'Dismount MainMount save'))

Write-Host "`n=== T5d Server: 4 indexes, WinRE serviced ONCE and reused ==="
Reset-Test; $p = New-Paths 'c'
$pk = @{ SSU=@(); LCU=@([pscustomobject]@{FullName='/p/lcu.msu'}); NetCU=@(); SafeOS=@([pscustomobject]@{FullName='/p/safeos.cab'}); SetupDU=@() }
foreach ($i in 1..4) { Service-InstallIndex -ImagePath '/w/i.wim' -Index $i -Paths $p -Packages $pk -OsDrive $os.Drive -LpFiles @{} -FodSource $null -OcRoot $null -Languages @() -DoWinRe $true -DoNetFx3 $false }
Check 'Safe OS DU applied to WinRE exactly once across 4 indexes' (@($script:Calls | Where-Object { $_ -match 'AddPkg safeos.cab @ WinReMount' }).Count -eq 1)
Check 'WinRE copied into all 4 indexes' (@($script:Calls | Where-Object { $_ -match 'DISM: Cleaning WinRE' }).Count -eq 1 -and @($script:Calls | Where-Object { $_ -match '^Mount i.wim idx' }).Count -eq 4)
Check 'LCU applied once per index (English only)' (@($script:Calls | Where-Object { $_ -match 'AddPkg lcu.msu @ MainMount' }).Count -eq 4)

Write-Host "`n=== T5e Failure mid-servicing discards the mount ==="
Reset-Test; $p = New-Paths 'd'
function Add-WindowsPackage { [CmdletBinding()] param($Path,$PackagePath,$LogPath) throw 'boom' }
$threw=$false; try { Service-InstallIndex -ImagePath '/w/i.wim' -Index 1 -Paths $p -Packages @{SSU=@();LCU=@([pscustomobject]@{FullName='/p/lcu.msu'});NetCU=@();SafeOS=@();SetupDU=@()} -OsDrive $os.Drive -LpFiles @{} -FodSource $null -OcRoot $null -Languages @() -DoWinRe $false -DoNetFx3 $false } catch { $threw=$true }
Check 'error propagates and image is discarded (works despite trailing backslash in mount list)' ($threw -and $script:MountedList.Count -eq 0 -and ($script:Calls -join ' ') -match 'Dismount MainMount discard')

Write-Host "`nRESULT: $pass passed, $fail failed"
