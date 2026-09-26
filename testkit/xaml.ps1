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

    # "Save settings" / "Reset to defaults" (step 10c) on the real window's controls, so the default ticks are the real ones
    $win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x))
    foreach ($n in $script:SettingOptionNames) { Set-Variable -Name "Chk$n" -Scope Script -Value $win.FindName("Chk$n") }
    $script:RootText = $win.FindName('RootText'); $script:LanguageList = $win.FindName('LanguageList')
    Check 'the Save settings and Reset to defaults buttons are in the window' ($null -ne $win.FindName('SaveSettingsButton') -and $null -ne $win.FindName('ResetSettingsButton'))
    foreach ($fn in 'Set-OsSettings', 'Get-SelectedSettings', 'Save-CurrentOsSettings', 'Reset-CurrentOsSettings') {
        $fm = [regex]::Match($src, "(?s)function $fn \{.*?\r?\n\}\r?\n"); Invoke-Expression $fm.Value
    }
    $script:SettingsDir = Join-Path $PWD 'tst_settings'; if (Test-Path $script:SettingsDir) { Remove-Item -Recurse -Force $script:SettingsDir }
    $script:DefaultChecks = @{}; foreach ($n in $script:SettingOptionNames) { $script:DefaultChecks[$n] = [bool](Get-Variable -Name "Chk$n" -Scope Script -ValueOnly).IsChecked }
    $script:OsDefinitions = Import-OsProfiles
    Update-LanguageItems
    $ticks = { ($script:SettingOptionNames | ForEach-Object { "$_=$([bool](Get-Variable -Name "Chk$_" -Scope Script -ValueOnly).IsChecked)" }) -join ',' }
    $picked = { (@($script:LanguageList.Items | Where-Object { $_.IsSelected } | ForEach-Object { [string]$_.Tag }) -join ',') }
    $defaultTicks = & $ticks
    $script:OsCombo.SelectedItem = 'Windows 10 Enterprise LTSC 2021 (KMS)'; Set-OsSettings
    Check 'WPF: an OS without saved settings gets the window defaults and its profile languages' ((& $ticks) -eq $defaultTicks -and (& $picked) -eq 'de-de,en-gb,es-es,fr-fr,it-it,ja-jp,ko-kr,pt-br,zh-cn,zh-tw')
    $script:ChkBoot.IsChecked = -not $script:ChkBoot.IsChecked; $script:ChkWinRE.IsChecked = -not $script:ChkWinRE.IsChecked
    foreach ($item in $script:LanguageList.Items) { $item.IsSelected = @('de-de', 'ja-jp') -contains [string]$item.Tag }
    $script:RootText.Text = 'G:\mediaRefresh'
    $changedTicks = & $ticks
    $savedFile = Save-CurrentOsSettings
    Check 'WPF: Save settings writes Settings\Win10_Enterprise_LTSC_2021_KMS.json and General.json' ((Split-Path $savedFile -Leaf) -eq 'Win10_Enterprise_LTSC_2021_KMS.json' -and (Read-GeneralSettings -Directory $script:SettingsDir) -eq 'G:\mediaRefresh')
    $script:OsCombo.SelectedItem = 'Windows 11 Enterprise 24H2'; Set-OsSettings
    Check 'WPF: switching to another OS without saved settings restores the defaults' ((& $ticks) -eq $defaultTicks -and (& $picked) -eq '')
    $script:OsCombo.SelectedItem = 'Windows 10 Enterprise LTSC 2021 (KMS)'; Set-OsSettings
    Check 'WPF: switching back loads the saved ticks and languages for that OS' ((& $ticks) -eq $changedTicks -and (& $picked) -eq 'de-de,ja-jp') "$(& $ticks) | $(& $picked)"
    Reset-CurrentOsSettings
    Check 'WPF: Reset to defaults deletes the OS''s settings file and restores the defaults' (-not (Test-Path $savedFile) -and (& $ticks) -eq $defaultTicks -and (& $picked) -eq 'de-de,en-gb,es-es,fr-fr,it-it,ja-jp,ko-kr,pt-br,zh-cn,zh-tw')
    $win.Close()
}
Write-Host "`nRESULT: $pass passed, $fail failed"
