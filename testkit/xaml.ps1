$src = Get-Content -Raw $(if ($env:MR_SCRIPT) { $env:MR_SCRIPT } else { (Join-Path $PSScriptRoot '../MediaRefresh_v2.4.ps1') })
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

# Languages tab (TODO step 10e): the list is built from Languages.json on real WPF controls, shown as "name - code",
# the OS defaults are pre-selected by code, and a run gets codes. Windows only (WPF).
$langBox = $x.SelectSingleNode('//*[@x:Name="LanguageList"]', $ns)
Check 'the XAML language list has no hard-coded items (it is filled from Languages.json)' ($null -ne $langBox -and $langBox.ChildNodes.Count -eq 0)
$wpf = $false; try { Add-Type -AssemblyName PresentationFramework -ErrorAction Stop; $wpf = $true } catch { Write-Host 'SKIP  WPF language list checks (PresentationFramework not available)' }
if ($wpf) {
    $pass0 = $pass; $fail0 = $fail
    . (Join-Path $PSScriptRoot 'mocks.ps1')   # engine + Write-Log/Check (mocks.ps1 resets the counters)
    $pass = $pass0; $fail = $fail0
    $script:WarnLines = [System.Collections.Generic.List[string]]::new()
    function Write-Log { param($Message, $Level = 'INFO') $script:WarnLines.Add("[$Level] $Message") }
    foreach ($fn in 'Update-LanguageItems', 'Set-DefaultLanguages') {
        $fm = [regex]::Match($src, "(?s)function $fn \{.*?\r?\n\}\r?\n"); Invoke-Expression $fm.Value
    }
    $script:LanguageList = New-Object System.Windows.Controls.ListBox; $script:LanguageList.SelectionMode = 'Multiple'
    $script:OsCombo = New-Object System.Windows.Controls.ComboBox
    $script:OsDefinitions = Import-OsProfiles
    $script:LanguageOptions = @(Import-LanguageList)
    Update-LanguageItems
    foreach ($n in $script:OsDefinitions.Keys) { [void]$script:OsCombo.Items.Add($n) }
    $script:OsCombo.SelectedItem = 'Windows 10 Enterprise LTSC 2021 (KMS)'
    Set-DefaultLanguages
    $items = @($script:LanguageList.Items)
    Check 'WPF: one list item per Languages.json entry, shown as "full name - code"' ($items.Count -eq 20 -and [string]$items[0].Content -eq 'Catalan (Spain) - ca-es' -and [string]$items[0].Tag -eq 'ca-es')
    $selected = @($items | Where-Object { $_.IsSelected } | ForEach-Object { [string]$_.Tag })
    Check 'WPF: the OS profile defaults are pre-selected by code' (($selected -join ',') -eq 'de-de,en-gb,es-es,fr-fr,it-it,ja-jp,ko-kr,pt-br,zh-cn,zh-tw') ($selected -join ',')
    $langsLine = [regex]::Match($src, '\$langs = @\(foreach \(\$item in \$script:LanguageList\.Items\)[^\r\n]*').Value
    $langs = @(); Invoke-Expression $langsLine
    Check 'WPF: a run gets the selected codes, not the display text' (($langs -join ',') -eq ($selected -join ',')) ($langs -join ',')
    $script:OsDefinitions['Windows 10 Enterprise LTSC 2021 (KMS)'].DefaultLanguages = @('de-de', 'en-us'); $script:WarnLines.Clear()
    Set-DefaultLanguages
    Check 'WPF: a profile default not in Languages.json is logged and not selected' ((@($script:LanguageList.Items | Where-Object { $_.IsSelected } | ForEach-Object { [string]$_.Tag }) -join ',') -eq 'de-de' -and [bool]($script:WarnLines -match 'WARN.*en-us.*not in Languages.json'))
}
Write-Host "`nRESULT: $pass passed, $fail failed"
