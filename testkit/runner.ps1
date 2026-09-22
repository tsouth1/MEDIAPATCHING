Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$src = [System.IO.File]::ReadAllText($(if ($env:MR_SCRIPT) { $env:MR_SCRIPT } else { '/mnt/user-data/outputs/MediaRefresh_v2.2.ps1' }))
$engine = [regex]::Match($src, '(?s)#region ENGINE(.*?)#endregion ENGINE').Groups[1].Value
$runner = [regex]::Match($src, "(?s)\`$script:RunnerScript = @'\r?\n(.*?)\r?\n'@").Groups[1].Value
$pass=0;$fail=0
function Check($n,[bool]$ok,$d=''){ if($ok){$script:pass++;Write-Host "PASS  $n" -ForegroundColor Green}else{$script:fail++;Write-Host "FAIL  $n  $d" -ForegroundColor Red} }
Check 'runner imports the Dism module' ($runner -match 'Import-Module Dism')
$runner = $runner -replace 'Import-Module Dism -ErrorAction Stop','# (Dism module not available on this Linux test host)'
Check 'engine text extracted' ($engine.Length -gt 10000)
Check 'runner text extracted' ($runner -match 'Invoke-MediaRefresh' -and $runner -match 'Done')

function Run-InRunspace($engineText, $opts) {
  $q = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
  $sh = [hashtable]::Synchronized(@{ Cancel=$false; Done=$false })
  $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState='MTA'; $rs.ThreadOptions='ReuseThread'; $rs.Open()
  $ps = [powershell]::Create(); $ps.Runspace=$rs
  [void]$ps.AddScript($runner, $true).AddArgument($engineText).AddArgument($q).AddArgument($sh).AddArgument($opts)
  $h = $ps.BeginInvoke()
  [pscustomobject]@{ Ps=$ps; Rs=$rs; H=$h; Q=$q; Sh=$sh }
}
function Drain($r,[int]$timeoutSec=30){
  $lines = New-Object System.Collections.Generic.List[string]; $sw=[Diagnostics.Stopwatch]::StartNew(); $item=$null
  $uiTicks=0
  while (-not $r.H.IsCompleted -or -not $r.Q.IsEmpty) {
    while ($r.Q.TryDequeue([ref]$item)) { $lines.Add($item) }
    $uiTicks++; Start-Sleep -Milliseconds 50   # the "UI thread" keeps ticking while the engine works
    if ($sw.Elapsed.TotalSeconds -gt $timeoutSec) { throw 'timeout' }
  }
  try { [void]$r.Ps.EndInvoke($r.H) } catch { $lines.Add("ENDINVOKE-ERR`t$($_.Exception.Message)") }
  $err = @($r.Ps.Streams.Error | ForEach-Object { $_.ToString() })
  $r.Ps.Dispose(); $r.Rs.Close(); $r.Rs.Dispose()
  [pscustomobject]@{ Lines=$lines; Ticks=$uiTicks; Errors=$err }
}

# ---- 1. fake Invoke-MediaRefresh: long work, logs, progress, cancel checkpoints
$fake = $engine + @'

function Invoke-MediaRefresh { param($Options)
  Write-Log "hello from $($Options.OsName)"
  for ($i=1; $i -le 40; $i++) { Assert-NotCancelled; Set-Progress ($i*2) "step $i"; Start-Sleep -Milliseconds 50 }
  if ($Options.OsName -eq 'BOOM') { throw 'kaboom' }
  $script:LastResult = [pscustomobject]@{ NewWim='X:\new.wim'; Preflight=$false; VerifyIssues=0 }
}
'@
$r = Run-InRunspace $fake ([pscustomobject]@{ OsName='OK' }); $d = Drain $r
Check 'success: Ok flag' ($r.Sh['Ok'] -eq $true -and $r.Sh['Done'] -eq $true) ($r.Sh | Out-String)
Check 'success: result handed back' ($r.Sh['Result'].NewWim -eq 'X:\new.wim')
Check 'success: log line arrived via queue' (@($d.Lines | Where-Object { $_ -like "L`t*hello from OK" }).Count -eq 1)
Check 'success: progress messages arrived' (@($d.Lines | Where-Object { $_ -like "P`t*`tstep *" }).Count -ge 40)
Check 'host loop kept ticking while engine ran (UI would stay responsive)' ($d.Ticks -ge 20) "ticks=$($d.Ticks)"
Check 'no runspace-level errors' ($d.Errors.Count -eq 0) ($d.Errors -join ';')

$r = Run-InRunspace $fake ([pscustomobject]@{ OsName='BOOM' }); $d = Drain $r
Check 'error: Ok=false with message' ($r.Sh['Ok'] -eq $false -and $r.Sh['Message'] -eq 'kaboom' -and $r.Sh['Done'])
Check 'error: ERROR line logged to queue' (@($d.Lines | Where-Object { $_ -like "L`t*[ERROR]*kaboom*" }).Count -ge 1)

$r = Run-InRunspace $fake ([pscustomobject]@{ OsName='OK' }); Start-Sleep -Milliseconds 400; $r.Sh['Cancel']=$true; $d = Drain $r
Check 'cancel: run stops with cancelled message' ($r.Sh['Ok'] -eq $false -and $r.Sh['Message'] -like '*cancelled*') ($r.Sh['Message'])
$last = ($d.Lines | Where-Object { $_ -like "P`t*" } | Select-Object -Last 1)
Check 'cancel: stopped before finishing' ($last -notlike "*step 40") $last

$r = Run-InRunspace ($engine + "`nthrow 'engine load failure'") ([pscustomobject]@{ OsName='OK' }); $d = Drain $r
Check 'bad engine text is reported, not a hang' ($r.Sh['Ok'] -eq $false -and $r.Sh['Message'] -like '*failed to start*' -and $r.Sh['Done'])

# ---- 2. the REAL Invoke-MediaRefresh (preflight) inside the runspace, DISM mocked
$base = Join-Path $PWD 'rt'; if (Test-Path $base) { Remove-Item -Recurse -Force $base }
$osDir = Join-Path $base 'Win11_Enterprise_24H2'; foreach ($s in 'ISO','PATCHES/LCU','PATCHES/SSU') { New-Item -ItemType Directory -Force (Join-Path $osDir $s) | Out-Null }
New-Item -ItemType Directory -Force (Join-Path $base '_iso/sources') | Out-Null
Set-Content (Join-Path $base '_iso/sources/install.wim') 'x'
Set-Content (Join-Path $osDir 'ISO/os.iso') 'x'
Set-Content (Join-Path $osDir 'PATCHES/LCU/windows11-kb1.msu') 'x'
$isoDir = Join-Path $base '_iso'
$mocks = @"

function Mount-IsoFile { param([string]`$ImagePath) `$script:MountedIsoPaths.Add(`$ImagePath); return '$isoDir' }
function Dismount-DiskImage { [CmdletBinding()] param(`$ImagePath) }
function Get-FreeSpaceGB { param([string]`$Path) return 500.0 }
function Get-WindowsImage { [CmdletBinding()] param(`$ImagePath,`$Index,[switch]`$Mounted)
  if (`$Mounted) { return @() }
  return @(1..3 | ForEach-Object { [pscustomobject]@{ ImageIndex=`$_; ImageName=@('Windows 11 Home','Windows 11 Pro','Windows 11 Enterprise')[`$_-1] } }) }
"@
$opts = [pscustomobject]@{ OsName='Windows 11 Enterprise 24H2'; Root=$base; PreflightOnly=$true; Install=$true;Boot=$false;WinRE=$false;Verify=$false;BuildMedia=$false;BuildIso=$false;SSU=$false;LCU=$true;SafeOS=$false;NetCU=$false;SetupDU=$false;NetFx3=$false;Languages=@() }
$r = Run-InRunspace ($engine + $mocks) $opts; $d = Drain $r 60
Check 'real engine preflight ran through the runner' ($r.Sh['Ok'] -eq $true) (($r.Sh['Message']) + ' ' + ($d.Lines -join "`n"))
Check 'real engine selected Enterprise index 3' (@($d.Lines | Where-Object { $_ -like "*Selected client image index 3: Windows 11 Enterprise*" }).Count -eq 1)
Check 'real engine result flagged Preflight' ($r.Sh['Result'].Preflight -eq $true)
$logs = Get-ChildItem (Join-Path $osDir 'LOGS') -Filter 'MediaRefresh_*.log' -ErrorAction SilentlyContinue
Check 'log FILE written from the background runspace too' (@($logs).Count -eq 1 -and (Get-Content $logs[0].FullName -Raw) -match 'Selected client image index 3')
Write-Host "`nRESULT: $pass passed, $fail failed"
