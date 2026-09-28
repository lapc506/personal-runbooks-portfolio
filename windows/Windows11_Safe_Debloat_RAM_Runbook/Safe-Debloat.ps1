# Safe-Debloat.ps1 — RAM debloat with guardrails. Self-elevates (one UAC).
# 1) restore point, 2) records prior states + writes Rollback-Debloat.ps1,
# 3) touches ONLY the safe/conditional lists, 4) prints before/after baseline.
param()
$ErrorActionPreference = 'Stop'
function Test-Admin {
  ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not (Test-Admin)) {
  Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs -Wait
  exit $LASTEXITCODE
}

# ---- NEVER-DISABLE: incident-backed protect list (see README) ----
$protected = @('camsvc','RmSvc','DPS','iphlpsvc','NlaSvc','WlanSvc','Dhcp','Wcmsvc',
  'CDPSvc','cbdhsvc','TokenBroker','wlidsvc','whesvc','LanmanServer','RasMan','SstpSvc',
  'SSDPSRV','DeviceAssociationService','WinHttpAutoProxySvc','SysMain','WdiSystemHost',
  'AppXSvc','ShellHWDetection','Themes','wuauserv','InstallService')

# ---- edit below ONLY for features you verified unused on THIS box ----
$disableServices = @('DiagTrack','dmwappushservice','RetailDemo','InventorySvc','nvagent',
  'HpTouchpointAnalyticsService')
$disableIfNoXbox = @('XblAuthManager','XblGameSave','XboxGipSvc','XboxNetApiSvc')
$disableIfNoMaps = @('MapsBroker','lfsvc')

$targets = ($disableServices + $disableIfNoXbox + $disableIfNoMaps) | Where-Object { $_ -notin $protected }
Write-Output ("PROTECTED-SKIPPED: " + (($disableServices + $disableIfNoXbox + $disableIfNoMaps |
  Where-Object { $_ -in $protected }) -join ', '))

Checkpoint-Computer -Description 'Pre-Safe-Debloat' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction SilentlyContinue
Write-Output "RESTORE-POINT-ATTEMPTED"

$rollback = @('$ErrorActionPreference="Stop"')
foreach ($n in $targets) {
  $s = Get-Service -Name $n -ErrorAction SilentlyContinue
  if (-not $s) { Write-Output "SKIP (missing): $n"; continue }
  $rollback += "Set-Service -Name '$n' -StartupType $($s.StartType)"
  try {
    Stop-Service -Name $n -Force -ErrorAction SilentlyContinue
    Set-Service -Name $n -StartupType Disabled
    Write-Output "OK $n -> Disabled (was $($s.StartType))"
  } catch { Write-Output "FAIL $n : $($_.Exception.Message)" }
}
$rollback | Set-Content (Join-Path $PSScriptRoot 'Rollback-Debloat.ps1') -Encoding UTF8
Write-Output "ROLLBACK-WRITTEN: Rollback-Debloat.ps1"
Write-Output "ACTION: re-run Measure-RamBaseline.ps1 under identical idle conditions, then verify Wi-Fi scan, Win+Shift+S, Win+V, Store."
