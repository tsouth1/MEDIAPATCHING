Import-Module PSScriptAnalyzer
$r = Invoke-ScriptAnalyzer -Path $(if ($env:MR_SCRIPT) { $env:MR_SCRIPT } else { '/mnt/user-data/outputs/MediaRefresh_v2.2.ps1' }) -Settings @{ IncludeRules=@('PSUseCompatibleSyntax'); Rules=@{ PSUseCompatibleSyntax=@{ Enable=$true; TargetVersions=@('5.1') } } }
"5.1 syntax-compat findings: $(@($r).Count)"; $r | % { "$($_.Line): $($_.Message)" }
