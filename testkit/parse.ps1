$errs=$null;$tok=$null
[void][System.Management.Automation.Language.Parser]::ParseFile(($(if ($env:MR_SCRIPT) { $env:MR_SCRIPT } else { '/mnt/user-data/outputs/MediaRefresh_v2.2.ps1' })),[ref]$tok,[ref]$errs)
"PARSE ERRORS: $($errs.Count)"; $errs | % { "$($_.Extent.StartLineNumber): $($_.Message)" }
