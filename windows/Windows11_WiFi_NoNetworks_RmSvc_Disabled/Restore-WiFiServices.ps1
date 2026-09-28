#Requires -RunAsAdministrator
# Restores Wi-Fi stack services to factory defaults + re-enables the Wi-Fi adapter via WMI.
# Run FIRST (accept the UAC prompt), then run Repair-WiFiConnect.ps1.
# Root cause: servicios_manual_disabled.ps1 set RmSvc (and DPS/iphlpsvc) to Disabled.

$ErrorActionPreference = 'Stop'

# Factory defaults: RmSvc=Auto, NlaSvc=Auto, DPS=Auto, iphlpsvc=Auto, WdiSystemHost=Manual
Set-Service -Name RmSvc -StartupType Automatic
Set-Service -Name NlaSvc -StartupType Automatic
Set-Service -Name DPS -StartupType Automatic
Set-Service -Name iphlpsvc -StartupType Automatic
Set-Service -Name WdiSystemHost -StartupType Manual -ErrorAction SilentlyContinue

# Re-enable Wi-Fi adapter via WMI (was Win32_NetworkAdapter NetEnabled=False)
$ad = Get-CimInstance Win32_NetworkAdapter -Filter "NetConnectionID='Wi-Fi'"
if ($ad.NetEnabled -eq $false) {
  $ad | Invoke-CimMethod -MethodName Enable | Out-Null  # ReturnValue 0 = success
}

Start-Service RmSvc
Start-Service NlaSvc
Start-Service DPS
Start-Service iphlpsvc
Start-Service WlanSvc
Start-Service Wcmsvc
Start-Service Dhcp

# Scan stays "Acceso denegado / error 5" until WlanSvc restarts after RmSvc/DPS return
Restart-Service WlanSvc -Force
Start-Sleep 8

Get-Service RmSvc,NlaSvc,DPS,iphlpsvc,WlanSvc,Dhcp | Select-Object Name, Status, StartType
netsh wlan show interfaces
