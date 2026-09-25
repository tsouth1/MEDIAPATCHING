$errs=$null;$tok=$null
[void][System.Management.Automation.Language.Parser]::ParseFile(($(if ($env:MR_SCRIPT) { $env:MR_SCRIPT } else { (Join-Path $PSScriptRoot '../MediaRefresh_v2.4.ps1') })),[ref]$tok,[ref]$errs)
"PARSE ERRORS: $($errs.Count)"; $errs | % { "$($_.Extent.StartLineNumber): $($_.Message)" }
