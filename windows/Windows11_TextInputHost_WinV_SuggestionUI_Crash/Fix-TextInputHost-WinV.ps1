# Fix-TextInputHost-WinV.ps1 — one-UAC bundle for the Win+V TextInputHost crash.
# Re-asserts platform services, resets TextInputHost state (direct delete or
# reboot-scheduled via MoveFileEx), and reports reboot/SFC status.
# Safe to re-run: every step is idempotent.
param([string]$LogFile = "$env:TEMP\Fix-TextInputHost-WinV.log")
$ErrorActionPreference = 'Stop'

function Test-Admin {
  ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not (Test-Admin)) {
  try {
    Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -LogFile `"$LogFile`"" -Verb RunAs -Wait
  } catch { Write-Output "UAC-CANCELLED: no se aplicaron cambios"; exit 2 }
  Get-Content $LogFile -ErrorAction SilentlyContinue
  exit $LASTEXITCODE
}
Start-Transcript -Path $LogFile -Force | Out-Null

$interactive = (Get-CimInstance Win32_ComputerSystem).UserName.Split('\')[1]
$local = "C:\Users\$interactive\AppData\Local"
Write-Output "ADMIN-OK as $env:USERNAME for profile $interactive"

# 1. Platform services back to factory Manual (template + per-user instance where applicable)
foreach ($svc in @('camsvc', 'CDPSvc')) {
  Set-Service -Name $svc -StartupType Manual -ErrorAction SilentlyContinue
  Start-Service -Name $svc -ErrorAction SilentlyContinue
}
# NOTE: per-user instance keys use a hash suffix (cbdhsvc_*), never the username — discovered below.
$cbdInst = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services' |
  Where-Object { $_.PSChildName -like 'cbdhsvc_*' } | Select-Object -ExpandProperty PSChildName
foreach ($k in @('cbdhsvc') + @($cbdInst)) {
  Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$k" -Name Start -Value 3
}
Write-Output "SERVICES-OK: camsvc/CDPSvc Manual+started, cbdhsvc template+instance Manual"
Get-Service camsvc, CDPSvc, cbdhsvc* | Format-Table Name, Status, StartType -AutoSize | Out-String | Write-Output

# 2. TextInputHost state reset
$cbsSettings = "$local\Packages\MicrosoftWindows.Client.CBS_cw5n1h2txyewy\Settings\settings.dat"
Get-Process TextInputHost -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep 2
$deleted = $false
try {
  if (Test-Path $cbsSettings) { Remove-Item $cbsSettings -Force -ErrorAction Stop; $deleted = $true }
  else { $deleted = $true }
} catch { Write-Output ("DIRECT-DELETE-BLOCKED: " + $_.Exception.Message) }
if ($deleted) { Write-Output "CBS-SETTINGS-DELETED" }
else {
  $sig = '[DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool MoveFileEx(string a, string b, int f);'
  $mv = Add-Type -MemberDefinition $sig -Name MvFxWinV -Namespace W32 -PassThru
  $ok = [W32.MvFxWinV]::MoveFileEx("\??\$cbsSettings", $null, 4)
  Write-Output ("REBOOT-DELETE-SCHEDULED: " + $ok)
}

# 3. Reboot / SFC status
$pending = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
$cbsReboot = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
Write-Output ("PENDING-RENAMES: " + ($null -ne $pending))
Write-Output ("CBS-REBOOT-PENDING: " + $cbsReboot)
if ($pending -or $cbsReboot) {
  Write-Output "ACTION: reboot, then run: sfc /scannow (elevated), then retest Win+V"
} else {
  Write-Output "ACTION: run sfc /scannow (elevated) now, then retest Win+V"
}
Stop-Transcript | Out-Null
