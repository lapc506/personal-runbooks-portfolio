# Debloat audit: which script disabled what (Ublaze vs Raphire), and how to check the rest

## Question

After finding `camsvc`/`cbdhsvc`/`CDPSvc` disabled (see the Snipping Tool runbook), which optimizer
did it — Ublaze Windows11-Optimizer or Raphire Win11Debloat — and what else did they break?

## Method: intersect the machine's disabled set with each script's disable list

Machine list:
```powershell
Get-CimInstance Win32_Service | Where-Object StartMode -eq 'Disabled' |
  Select-Object Name, State, StartMode
```

Script lists (downloaded raw, grepped for `Set-Service`/`Stop-Service` + name arrays):
- Ublaze `Windows11_Optimizer.ps1` → explicit `$servicesToDisable` array with
  `@{Name="..."}` entries.
- Raphire `Win11Debloat.ps1` (current master) → searched for `Set-Service`,
  `Stop-Service`, `StartType`, `CurrentControlSet\Services`: **zero hits**.
  Service-related mentions are UI-only (taskbar search box switch). It disables no services.

## Result

| Disabled on box, in Ublaze list (10) | Disabled on box, in NEITHER script |
|---|---|
| `XblAuthManager`, `XblGameSave`, `XboxGipSvc`, `XboxNetApiSvc`, `wisvc`, `DiagTrack`, `dmwappushservice`, `RetailDemo`, `MapsBroker`, `lfsvc` | `camsvc`, `cbdhsvc_*`, `CDPSvc` (+ `CDPUserSvc_*`, `UnistoreSvc_*`, `PimIndex*`, `UserDataSvc_*`, `DPS`, `SysMain`, `WSearch`, `TokenBroker`, `wlidsvc`, `LanmanServer`, `lmhosts`, `SSDPSRV`, `RemoteRegistry`, `TrkWks`, `RasMan`/`SstpSvc`/`RemoteAccess`, `iphlpsvc`, `SensorService`, `DusmSvc`, `PcaSvc`, `RmSvc`, `WdiSystemHost`, `tzautoupdate`, `whesvc`, `wuqisvc`, `NetTcpPortSharing`, `DisplayEnhancementService`, …) |

So: Ublaze accounts for the Xbox/telemetry batch; Raphire (current master) is **not** the culprit
for any service; the rest — including every service that actually broke something — came from a
third optimizer or manual `services.msc` hardening. (`ssh-agent` Disabled is stock default, not damage.)

## How to tell whether a disabled service is actually hurting

1. SCM log is necessary but not sufficient:
   ```powershell
   Get-WinEvent -LogName System -MaxEvents 3000 |
     Where-Object { $_.TimeCreated -gt (Get-Date).AddDays(-7) -and
       (($_.ProviderName -like '*Service Control Manager*' -and $_.Id -in @(7000,7001,7003,7009,7023,7031,7034)) -or
        ($_.ProviderName -like '*DCOM*' -and $_.Id -eq 10005)) }
   ```
   On the affected box this was clean — yet Camera/Snipping Tool were broken, because WinRT
   `ERROR_SERVICE_DISABLED` surfaces as an app-side stowed exception, never as an SCM event.
2. Functional matrix beats logs. High-risk mappings from this box:
   `RasMan/SstpSvc`→built-in VPN, `LanmanServer`→file sharing, `WSearch`→Start search,
   `TokenBroker/wlidsvc`→MSA/Store/sync, `NPSMSvc`→Phone Link, `UserDataSvc/UnistoreSvc/PimIndex`→contacts/calendar,
   `webthreatdef_*`→SmartScreen, `tzautoupdate`→auto timezone, `CDPSvc`→share/DataTransfer broker.
3. Defaults reference: per-user services (`cbdhsvc`, `CDPUserSvc`, …) default to `Manual`
   (template `Start=3`, `UserServiceFlags=2`); `Start=4` on the instance is always an override.
   Check templates with `(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\<svc>').Start`.

`Audit-DisabledServices.ps1` dumps the machine list plus template starts for triage.
Decision taken on the box: restore only what demonstrably broke (`camsvc`, `cbdhsvc_*`, `CDPSvc`),
leave the rest `Disabled` with the matrix above as the lookup if something else fails silently.
