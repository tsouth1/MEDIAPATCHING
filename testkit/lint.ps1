$ErrorActionPreference='Continue'
try {
  Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
  Install-Module PSScriptAnalyzer -Scope CurrentUser -Force -ErrorAction Stop
  Import-Module PSScriptAnalyzer
  "PSScriptAnalyzer $((Get-Module PSScriptAnalyzer).Version) loaded"
  $settings = @{ Rules = @{ PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @('5.1') } } }
  $r = Invoke-ScriptAnalyzer -Path $(if ($env:MR_SCRIPT) { $env:MR_SCRIPT } else { '/mnt/user-data/outputs/MediaRefresh_v2.2.ps1' }) -Settings $settings
  "COMPAT (5.1 syntax) findings: $(@($r).Count)"; $r | % { "$($_.Line): $($_.RuleName): $($_.Message)" }
  $r2 = Invoke-ScriptAnalyzer -Path $(if ($env:MR_SCRIPT) { $env:MR_SCRIPT } else { '/mnt/user-data/outputs/MediaRefresh_v2.2.ps1' }) -Severity Error,Warning -ExcludeRule PSAvoidUsingWriteHost,PSUseApprovedVerbs,PSUseShouldProcessForStateChangingFunctions,PSAvoidGlobalVars,PSUseSingularNouns,PSReviewUnusedParameter,PSAvoidUsingEmptyCatchBlock
  "GENERAL error/warning findings: $(@($r2).Count)"; $r2 | % { "$($_.Line): [$($_.Severity)] $($_.RuleName): $($_.Message)" }
} catch { "LINT UNAVAILABLE: $($_.Exception.Message)" }
