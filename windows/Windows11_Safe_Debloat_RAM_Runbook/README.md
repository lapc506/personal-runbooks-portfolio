# Windows 11 safe debloat for RAM: corrected successor of `servicios_manual_disabled.ps1`

Reduces idle RAM from bloatware/services **without** repeating the incident in
`../Windows11_Debloat_Service_Audit_Ublaze_Raphire/POSTMORTEM.md` (mass-`Disabled`
broke Snipping Tool, Camera-QR, UWP copy, Win+V, Wi-Fi). Rule: **only disable what is
measured unused AND mapped; everything else stays at factory defaults.**

## How to use (wizard UI — fork of Raphire's tweak model, MUI-stepper UX)

`Safe-Debloat-Wizard.ps1`: 1 Medir → 2 Elegir → 3 Confirmar → 4 Verificar, with Back/Next +
dots. Same safe/conditional catalog as below; protected services are shown locked, never
selectable. Apply runs `Safe-Debloat-Apply.ps1` (single UAC: restore point + apply +
auto-generated rollback).

```powershell
powershell -ExecutionPolicy Bypass -File .\Safe-Debloat-Wizard.ps1
```

CLI alternative: edit the lists in `Safe-Debloat.ps1` and run it directly.

## How to use (classic)

1. Baseline first: `.\Measure-RamBaseline.ps1` → save the numbers.
2. Edit the `$DisableIfUnused` / `$KeepAuto` lists ONLY for features you verified unused.
3. Run `.\Safe-Debloat.ps1` (one UAC). It creates a restore point first, applies only the
   safe list, then re-runs the baseline so you see actual MB saved.
4. Re-verify the feature matrix (Wi-Fi scan, `Win+Shift+S`, Win+V, Store, MSA sign-in).
   Any regression → `.\Rollback-Debloat.ps1` (generated next to the log with exact prior states).

## Verdict table (evidence from this box — incident links in brackets)

PROTECT (broke something when disabled):
`camsvc` [Snipping], `RmSvc`+`DPS`+`iphlpsvc` [Wi-Fi scan], `CDPSvc`+`cbdhsvc` [clipboard/share],
`TokenBroker`/`wlidsvc` [MSA/sync], `NlaSvc`/`WlanSvc`/`Dhcp` [network],
`whesvc` [Hello], `LanmanServer` [file sharing], `RasMan`/`SstpSvc` [VPN],
`SSDPSRV` [casting/discovery], `DeviceAssociationService` [Bluetooth pairing],
`WinHttpAutoProxySvc` [proxy], `SysMain` [see note], `WdiSystemHost` [leave: fails to start anyway].

CONDITIONAL (disable only if you measured the feature unused):
`SysMain` (saves RAM, costs app-launch speed on HDD; neutral on SSD — measure),
`MapsBroker`, `lfsvc`, Xbox services, `PcaSvc`, `TrkWks`, `lmhosts`, `DusmSvc`,
`SharedAccess`, `AppIDSvc`, `DoSvc`.

SAFE (telemetry/vendor, no dependents on a Home box):
`DiagTrack`, `dmwappushservice`, `InventorySvc`, `nvagent`, `HpTouchpointAnalyticsService`.

NEVER touch unknowns: `wuqisvc` and friends stay as-is until mapped. Unknown != unnecessary.

## Roadmap (native WinUI 3)

A `Microsoft.UI.Xaml` port (stepper via `NavigationView`/custom stepper, live camera via
WinUI-Gallery `CaptureElementPreview` sample, MVVM via CommunityToolkit.Mvvm) needs the
Windows App SDK + VS toolchain, absent on the target box (only .NET 9 SDK present). Until then,
this PowerShell+WPF wizard is the shippable UI.
