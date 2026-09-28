# Safe-Debloat-Apply.ps1 — elevated worker launched by the wizard (one UAC).
# In:  $env:TEMP\SafeDebloat-Selection.json { Services: [names], CreateRestorePoint: bool }
# Out: rollback script + result file in the same folder as this script.
param([string]$SelectionFile = "$env:TEMP\SafeDebloat-Selection.json")
$ErrorActionPreference = 'Stop'
function Test-Admin {
  ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not (Test-Admin)) {
  Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -SelectionFile `"$SelectionFile`"" -Verb RunAs -Wait
  exit $LASTEXITCODE
}
$log = "$env:TEMP\SafeDebloat-Apply.log"
Start-Transcript -Path $log -Force | Out-Null
try {
  $sel = Get-Content $SelectionFile -Raw | ConvertFrom-Json
  if ($sel.CreateRestorePoint) {
    Checkpoint-Computer -Description 'Pre-Safe-Debloat-Wizard' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction SilentlyContinue
    Write-Output "RESTORE-POINT-ATTEMPTED"
  }
  $rollback = @('$ErrorActionPreference="Stop"')
  foreach ($n in $sel.Services) {
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
  Write-Output "ROLLBACK-WRITTEN"
  'DONE' | Set-Content "$env:TEMP\SafeDebloat-Done.txt"
} finally { Stop-Transcript | Out-Null }
