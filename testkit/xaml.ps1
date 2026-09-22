$src = Get-Content -Raw $(if ($env:MR_SCRIPT) { $env:MR_SCRIPT } else { '/mnt/user-data/outputs/MediaRefresh_v2.2.ps1' })
$pass=0;$fail=0
function Check($n,[bool]$ok,$d=''){ if($ok){$script:pass++;Write-Host "PASS  $n" -ForegroundColor Green}else{$script:fail++;Write-Host "FAIL  $n  $d" -ForegroundColor Red} }
$m = [regex]::Match($src, "(?s)\[xml\]\`$xaml = @'\r?\n(.*?)\r?\n'@")
Check 'XAML block found' $m.Success
$x = $null; try { $x = [xml]$m.Groups[1].Value } catch { Write-Host $_.Exception.Message }
Check 'XAML is well-formed XML' ($null -ne $x)
$ns = New-Object System.Xml.XmlNamespaceManager($x.NameTable); $ns.AddNamespace('x','http://schemas.microsoft.com/winfx/2006/xaml')
$names = @($x.SelectNodes('//*[@x:Name]', $ns) | ForEach-Object { $_.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml') })
$list = [regex]::Match($src, "foreach \(\`$ctl in @\((.*?)\)\)").Groups[1].Value -split ',' | ForEach-Object { $_.Trim().Trim("'") }
$missing = @($list | Where-Object { $names -notcontains $_ })
Check "every control the script looks up exists in the XAML ($($list.Count) controls)" ($missing.Count -eq 0) ($missing -join ',')
$dups = @($names | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object Name)
Check 'no duplicate x:Name values' ($dups.Count -eq 0) ($dups -join ',')
$refs = [regex]::Matches($src, '\$script:(\w+)\.(?:Add_Click|Add_SelectionChanged|IsEnabled|Text|Items)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
$unknown = @($refs | Where-Object { $list -notcontains $_ -and $_ -notin @('UiTimer','RunQueue','RunShared','RunPs','RunRs','RunHandle','RunStatus','RunStarted','LogFile','ProfileMessages') })
Check 'controls used with .Add_Click/.Text/.Items are all registered' ($unknown.Count -eq 0) ($unknown -join ',')
Write-Host "`nRESULT: $pass passed, $fail failed"
