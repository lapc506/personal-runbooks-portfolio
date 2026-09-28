# Windows 11 Wi-Fi: no available networks, `netsh` returns Access Denied (error 5)

## Symptoms

- Windows Settings / taskbar shows no available Wi-Fi networks.
- `netsh wlan show interfaces` reports the adapter present but useless:
  ```
  Nombre : Wi-Fi
  Descripcion : Realtek 8852BE-VT Wireless LAN WiFi 6 PCI-E NIC
  Estado : desconectado
  Estado de radio : Hardware Activado / Software Activado
  ```
- `netsh wlan show networks mode=bssid` (even elevated) fails:
  ```
  Nombre de interfaz : Wi-Fi
  Acceso denegado.
  La funcion WlanGetAvailableNetworkList devuelve el error 5
  ```
- Target network `Akinson 5 G` (note the space, not `Akinson 5G`) exists as a saved profile but never appears in scans.

## Environment

- Windows 11 Home Single Language, 10.0.26200 (25H2), 64-bit.
- Adapter: Realtek 8852BE-VT Wireless LAN WiFi 6 PCI-E NIC (`ec:3a:56:0a:29:c0`, GUID `3a8dd0b5-3d6b-481e-9e12-5958023a07b6`).
- Target: `SSID Akinson 5 G / Infraestructura / WPA2-Personal / CCMP / 5 GHz ch 36 / BSSID b8:5f:b0:70:e4:00`.
- Shell without elevation; UAC available for one-shot elevated fixes.
- Debloat previously run: `C:\Users\guara\OneDrive\Desktop\servicios_manual_disabled.ps1`, plus Ublaze Windows11-Optimizer / Raphire Win11Debloat in history.

## Diagnosis (in order)

1. Adapter looks fine at radio level, so rule out hardware switch / airplane mode:
   ```powershell
   netsh wlan show interfaces
   ```
   Result: `desconectado`, but `Hardware Activado / Software Activado` — radio is on, stack is the suspect.
2. Check the WLAN stack via WMI (as requested, WMI is the source of truth here):
   ```powershell
   Get-CimInstance Win32_Service -Filter "Name='RmSvc'" | Select Name, State, StartMode
   Get-CimInstance Win32_Service -Filter "Name='NlaSvc'" | Select Name, State, StartMode
   Get-CimInstance Win32_Service -Filter "Name='WdiSystemHost'" | Select Name, State, StartMode
   Get-CimInstance Win32_NetworkAdapter -Filter "NetConnectionID='Wi-Fi'" | Select Name, NetEnabled, Status
   Get-Service WlanSvc,Dhcp,NlaSvc,RmSvc,DPS,iphlpsvc,WdiSystemHost | Format-Table Name, Status, StartType -AutoSize
   ```
   Result here:
   - `RmSvc Stopped / Disabled`, `NlaSvc Stopped / Manual`, `DPS Stopped / Disabled`, `iphlpsvc Stopped / Disabled`, `WdiSystemHost Stopped / Disabled`
   - `WlanSvc Running / Automatic` (running but starved of dependencies)
   - `Win32_NetworkAdapter NetEnabled=False`
3. Confirm the profile exists but scan is blocked (no need for the password yet):
   ```powershell
   netsh wlan show profiles
   # Perfil de todos los usuarios : Akinson 5 G
   netsh wlan show networks mode=bssid
   # -> Acceso denegado / error 5
   ```
4. Identify who disabled it:
   ```powershell
   Select-String RmSvc C:\Users\guara\OneDrive\Desktop\servicios_manual_disabled.ps1
   ```
   Hit in step 3 of that script:
   ```powershell
   Set-Svc @('DPS','TokenBroker','camsvc','wlidsvc','CDPSvc','whesvc','SysMain','PcaSvc','iphlpsvc','RasMan','LanmanServer','SensorService','InventorySvc','SSDPSRV','RmSvc',...) 'Disabled'
   ```

## Root cause

`RmSvc` (Radio Management Service, default `Automatic`) was set to `Disabled` by the debloat script. Windows never does this itself. Without it, `WlanSvc` cannot enumerate radios, so `WlanGetAvailableNetworkList` returns `error 5`, and the Wi-Fi adapter stays `NetEnabled=False / desconectado`.

Contributors (same script): `DPS` and `iphlpsvc` to `Disabled` keep the scan broken even after `RmSvc` alone is fixed — scan only recovers after they are back to `Automatic` **plus** a `Restart-Service WlanSvc`.

## Fix

```powershell
# elevated (accept the UAC prompt) — Restore-WiFiServices.ps1 in this folder:
Set-Service -Name RmSvc -StartupType Automatic
Set-Service -Name NlaSvc -StartupType Automatic
Set-Service -Name DPS -StartupType Automatic
Set-Service -Name iphlpsvc -StartupType Automatic
Set-Service -Name WdiSystemHost -StartupType Manual -ErrorAction SilentlyContinue
Get-CimInstance Win32_NetworkAdapter -Filter "NetConnectionID='Wi-Fi'" | Invoke-CimMethod -MethodName Enable
Start-Service RmSvc,NlaSvc,DPS,iphlpsvc,WlanSvc,Wcmsvc,Dhcp
Restart-Service WlanSvc -Force  # mandatory: scan stays error 5 without this
```

Then connect to the saved profile (name has a space):

```powershell
# elevated — Repair-WiFiConnect.ps1 in this folder:
netsh wlan connect name="Akinson 5 G"
```

`Restore-WiFiServices.ps1` automates the service/adapter half; `Repair-WiFiConnect.ps1` automates scan + connect.

## Verification

- `Get-Service RmSvc,NlaSvc,DPS,iphlpsvc,WlanSvc,Dhcp` → all `Running` (`RmSvc/NlaSvc/DPS/iphlpsvc` on `Automatic`).
- `netsh wlan show networks mode=bssid` lists `SSID 7 : Akinson 5 G ... Señal 100% ... Canal 36`.
- `netsh wlan show interfaces` → `Estado: conectado, SSID: Akinson 5 G, BSSID b8:5f:b0:70:e4:00, 5 GHz, 866.7 Mbps, Perfil: Akinson 5 G`.
- `ipconfig` → `IPv4 192.168.1.90`; `ping -n 2 8.8.8.8` → `0% perdidos`.
- Full logs of this incident: `$env:TEMP\fixwifi.log`, `$env:TEMP\wifi-connect.log`.

## Failed attempts (kept for the record)

- Restoring only `RmSvc` + `NlaSvc` and re-enabling the adapter via `Invoke-CimMethod Enable` (`ReturnValue 0`) was not enough — scan still returned `Acceso denegado / error 5`.
- Restoring `DPS` + `iphlpsvc` to `Automatic` and starting them was not enough either until `Restart-Service WlanSvc` (+ ~8s wait); only then did the scan list `Akinson 5 G` at 100%.
- `WdiSystemHost` fails to start (`No se puede abrir el servicio`) and `SensorService` remains `Stopped / Disabled` — neither blocks the fix once `WlanSvc` is restarted, left as-is.
- `Get-NetAdapter` dies with `HRESULT 0x800106d9` while the stack is broken; `Get-CimInstance Win32_NetworkAdapter` + `netsh wlan` are the reliable checks here.
- `netsh wlan show networks` without elevation demands elevation (`La operacion solicitada requiere elevacion`); the `error 5` above is the elevated-but-still-broken signature, distinct from the non-elevated one.
