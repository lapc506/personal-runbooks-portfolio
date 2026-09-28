# Windows 11 Snipping Tool: `Win+Shift+S` dead, `New` restarts the app

## Symptoms

- `Win+Shift+S` does nothing. Snipping Tool opens manually, but clicking **New** neither dims the screen nor opens the overlay — the app just restarts after ~0.5s.
- AppX package reports healthy: `Microsoft.ScreenSketch 11.2607.23.0 / Status: Ok`.
- No `Application` log errors for ScreenSketch.

## Environment

- Windows 11 25H2, build 26200 (upgraded box, debloat scripts previously run: Ublaze Windows11-Optimizer, Raphire Win11Debloat).
- Shell without elevation; UAC available for one-shot elevated fixes.

## Diagnosis (in order)

1. Rule out hotkey hijack and policy blocks:
   ```powershell
   reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v DisabledHotkeys
   reg query "HKLM\SOFTWARE\Policies\Microsoft\TabletPC"
   Get-AppxPackage -Name Microsoft.ScreenSketch | Select Name, Version, Status
   Get-Process OneDrive,Teams,Discord,Snagit -ErrorAction SilentlyContinue
   ```
   All clean here: no `DisabledHotkeys`, no TabletPC policy, package `Ok`, no interceptors running.
2. Re-register attempt fails and names the culprit:
   ```
   Add-AppxPackage : ... HRESULT: 0x80073CF6 ... error 0x80070422:
   While processing the request, the system failed to register the
   windows.capability extension ... No se puede iniciar el servicio,
   porque esta deshabilitado ...
   ```
   `0x80070422` = `ERROR_SERVICE_DISABLED`.
3. Confirm via the deployment log and service state:
   ```powershell
   Get-AppPackageLog -ActivityId <id-from-error>
   Get-Service camsvc | Select Name, Status, StartType   # Stopped / Disabled
   ```
   Log shows `Failed to reach state RegistrationChanged` on `windows.capability`.

## Root cause

`camsvc` (Capability Access Manager Service, default `Manual`) was set to `Disabled`
— almost certainly by a debloat/optimizer run, Windows never does this itself.
Without it, ScreenSketch cannot register its `windows.capability` extension, so the
capture overlay never initializes and the app silently restarts.

## Fix

```powershell
# elevated (accept the UAC prompt)
sc.exe config camsvc start= demand
sc.exe start camsvc
# then, current user is enough:
Get-Process -Name SnippingTool -ErrorAction SilentlyContinue | Stop-Process -Force
$pkg = Get-AppxPackage -Name Microsoft.ScreenSketch
Add-AppxPackage -DisableDevelopmentMode -Register "$($pkg.InstallLocation)\AppXManifest.xml"
```

If rectangle-drag still misbehaves afterwards, the crash loop has corrupted the app settings —
delete them (they regenerate on next launch):

```powershell
Get-Process -Name SnippingTool -ErrorAction SilentlyContinue | Stop-Process -Force
Remove-Item "$env:LOCALAPPDATA\Packages\Microsoft.ScreenSketch_8wekyb3d8bbwe\Settings\settings.dat" -Force
```

`Repair-SnippingTool.ps1` in this folder automates the non-elevated half.

## Verification

- `Win+Shift+S` opens the overlay; `snippingtool /clip` works.
- `Nuevo` dims the screen; rectangle drag and fullscreen capture both save.
- `Get-Service camsvc` → `Running / Manual` (survives reboot).

## Failed attempts (kept for the record)

- Re-registering before enabling `camsvc` fails with `0x80073CF6/0x80070422` — the service is the blocker, not the package.
- `Get-AppxPackage -AllUsers` from a non-elevated shell dies with Access Denied; scope to current user instead.
