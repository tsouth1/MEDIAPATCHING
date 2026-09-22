# Media Refresh Studio - mock-based test kit

These checks exercise the engine without real images or a real DISM: the DISM cmdlets, ISO mounting and free-space reader are replaced by mocks, so call order, error handling, profile loading and output handling can be re-checked after every change.

**Note:** in the Claude project each script is stored with an extra `.txt` (for example `e2e.ps1.txt`); remove the `.txt` when restoring them to a folder.

**Run:** PowerShell 7, from the folder holding these files: `$env:MR_SCRIPT = '<path to MediaRefresh_v2.x.ps1>'; pwsh -NoProfile -File run_all.ps1`. Verified on PowerShell 7.4 on Linux. (Not the real-image test: that is task 2 in TODO.md.)

| File | What it covers |
|---|---|
| parse.ps1 | Parser: 0 syntax errors |
| xaml.ps1 | XAML is well-formed; every control the script looks up exists |
| harness.ps1 | ISO role detection, package handling, cleanup and failure paths (unit level) |
| mocks.ps1 | Shared mocks, dot-sourced by harness/e2e/profiles |
| e2e.ps1 | Whole-run scenarios E1-E11 (languages, Server multi-index, preflight, IoT edition selection, profiles through a run, archive, free space) |
| runner.ps1 | The background runspace runner: queue messages, result hand-back, cancel, errors, a real preflight inside a runspace |
| profiles.ps1 | JSON profiles, order manifest, support status, archive, free-space check |
| lint2.ps1 | Windows PowerShell 5.1 syntax-compatibility lint (needs PSScriptAnalyzer) |
| lint.ps1 | General PSScriptAnalyzer pass (style findings such as positional parameters are known and accepted) |

Test-only conventions: tests read the engine text between `#region ENGINE` and `#endregion ENGINE`, so keep those markers. `MR_SCRIPT` selects the script under test.
