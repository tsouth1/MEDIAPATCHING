Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$src = Get-Content -Raw $(if ($env:MR_SCRIPT) { $env:MR_SCRIPT } else { '/mnt/user-data/outputs/MediaRefresh_v2.2.ps1' })
$m = [regex]::Match($src, '(?s)#region ENGINE(.*?)#endregion ENGINE')
$tmp = Join-Path $PWD 'engine_only.ps1'; Set-Content $tmp $m.Groups[1].Value
. $tmp

$script:Calls = [System.Collections.Generic.List[string]]::new()
$script:MountedList = @()
function Note($s) { $script:Calls.Add($s) }
function Write-Log { param($Message,$Level='INFO') Write-Host ("   [{0}] {1}" -f $Level,$Message) }
# ---- mocks for DISM cmdlets / dism.exe ----
function Mount-WindowsImage { [CmdletBinding()] param($ImagePath,$Index,$Path,[switch]$CheckIntegrity,[switch]$ReadOnly,$LogPath)
  Note ("Mount $(Split-Path $ImagePath -Leaf) idx$Index -> $(Split-Path $Path -Leaf)")
  New-Item -ItemType Directory -Force (Join-Path $Path 'Windows/System32/Recovery') | Out-Null
  Set-Content (Join-Path $Path 'Windows/System32/Recovery/winre.wim') 'orig'
  $script:MountedList += [pscustomobject]@{ Path = $Path + '\'; MountStatus='Ok' } }   # trailing backslash on purpose
function Dismount-WindowsImage { [CmdletBinding()] param($Path,[switch]$Save,[switch]$Discard,[switch]$CheckIntegrity,$LogPath)
  Note ("Dismount $(Split-Path $Path -Leaf) " + $(if($Save){'save'}else{'discard'}))
  $script:MountedList = @($script:MountedList | Where-Object { (Get-NormalizedPath $_.Path) -ne (Get-NormalizedPath $Path) })
  Get-ChildItem $Path -Force | Remove-Item -Recurse -Force }
function Get-WindowsImage { [CmdletBinding()] param($ImagePath,$Index,[switch]$Mounted)
  if ($Mounted) { return $script:MountedList }
  if ($Index) { return [pscustomobject]@{ ImageIndex=$Index; ImageName="Img$Index"; Version='10.0.17763.9121' } }
  return @([pscustomobject]@{ ImageIndex=1; ImageName='Img1' }) }
function Add-WindowsPackage { [CmdletBinding()] param($Path,[Parameter(Mandatory)][ValidateNotNullOrEmpty()]$PackagePath,$LogPath)
  Note ("AddPkg $(Split-Path $PackagePath -Leaf) @ $(Split-Path $Path -Leaf)") }
function Add-WindowsCapability { [CmdletBinding()] param($Name,$Path,$Source,[switch]$LimitAccess,$LogPath) Note "AddCap $Name" }
function Enable-WindowsOptionalFeature { [CmdletBinding()] param($Path,$FeatureName,[switch]$All,$Source,[switch]$LimitAccess,$LogPath) Note "EnableFeature $FeatureName" }
function Export-WindowsImage { [CmdletBinding()] param($SourceImagePath,$SourceIndex,$DestinationImagePath,$DestinationName,$CompressionType,[switch]$CheckIntegrity,$LogPath)
  Note "Export -> $(Split-Path $DestinationImagePath -Leaf)"; Set-Content $DestinationImagePath 'x' }
function Get-WindowsPackage { [CmdletBinding()] param($Path,$LogPath) return @() }
function Get-WindowsOptionalFeature { [CmdletBinding()] param($Path,[switch]$All,$LogPath) return $script:OptionalFeatures }
function Get-AppxProvisionedPackage { [CmdletBinding()] param($Path) return $script:ProvisionedAppx }
$script:OptionalFeatures = @()
$script:ProvisionedAppx = @()
$script:FreeGB = 500.0
function Get-FreeSpaceGB { param([string]$Path) return $script:FreeGB }
function Invoke-DismExe { param([string[]]$Arguments,[string]$Description,[switch]$AllowPending) Note "DISM: $Description" }

$pass = 0; $fail = 0
function Check($name, [bool]$ok, $detail='') { if ($ok) { $script:pass++; Write-Host "PASS  $name" -ForegroundColor Green } else { $script:fail++; Write-Host "FAIL  $name  $detail" -ForegroundColor Red } }
function Reset-Test { $script:Calls.Clear(); $script:MountedList=@() }
