# Runs every mock-based check against the script named in $env:MR_SCRIPT (default: ../MediaRefresh_v2.4.ps1, beside this folder).
# Usage (PowerShell 7):  pwsh -NoProfile -File run_all.ps1   (or set $env:MR_SCRIPT first to test another copy of the script)
# Run it from the folder that holds these files: the tests write scratch folders (e2e, ptest, rt, tst) next to themselves.
$pwsh = (Get-Process -Id $PID).Path
$total = 0; $failed = 0
foreach ($t in 'parse.ps1','xaml.ps1','harness.ps1','e2e.ps1','runner.ps1','profiles.ps1','acquisition.ps1') {
    $out = & $pwsh -NoProfile -File (Join-Path $PSScriptRoot $t) 2>&1 | Out-String
    $line = ($out -split "`r?`n" | Where-Object { $_ -match '^(RESULT|PARSE ERRORS)' } | Select-Object -Last 1)
    if (-not $line) { $line = 'NO RESULT LINE (script crashed)'; $failed++ }
    elseif ($line -match 'RESULT: \d+ passed, (\d+) failed' -and [int]$Matches[1] -gt 0) { $failed++ }
    elseif ($line -match 'PARSE ERRORS: (\d+)' -and [int]$Matches[1] -gt 0) { $failed++ }
    '{0,-14} {1}' -f $t, $line
    $total++
}
if ($failed -eq 0) { "`nALL $total SUITES PASSED" } else { "`n$failed of $total SUITES FAILED"; exit 1 }
