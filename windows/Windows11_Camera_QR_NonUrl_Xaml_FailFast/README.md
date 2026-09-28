# Windows Camera QR: tapping a non-URL payload crashes the app (`0xc000027b` / `E_FAIL`)

## Symptoms

- Camera app scans QR codes and shows the decoded text pill (e.g. `hola`, `546738`).
- Tapping a pill containing a **URL** opens the browser — works.
- Tapping a pill containing **plain text** crashes Camera to desktop, every time.
- A third-party UWP QR scanner (Matthias Duyck QR Code Scanner) crashes identically on its
  **Copy To Clipboard** button. Plain Win32 copy/paste everywhere else works fine.

## Environment

- `Microsoft.WindowsCamera_2026.2607.1.0_x64`, Windows 11 25H2 build 26200.9457.
- Same debloated box as the Snipping Tool runbook (services restored: `camsvc`, `cbdhsvc_*`, `CDPSvc`).

## Crash signature (stable across reinstalls and repros)

`Application Error 1000`:
```
WindowsCamera.exe → Windows.UI.Xaml.dll 10.0.26100.9444, 0xc000027b, offset 0x90e383
```
`Windows Error Reporting 1001` (`MoAppCrash`, bucket `2305734594999441892`):
```
combase.dll 10.0.26100.9444, E_FAIL 80004005, offset 0x579e4
```
`0xc000027b` is a stowed WinRT exception; the WER record wraps the real `E_FAIL` in `combase`.

## Live-dump analysis (WinDbg `cdb.exe`, offline symbols)

Captured via `HKLM\...\Windows Error Reporting\LocalDumps\WindowsCamera.exe`
(`DumpFolder`, `DumpType=1`, `DumpCount=2`; key removed afterwards).
`!analyze` needs network symbols and hangs here, so the stack was taken with export symbols only
(`.sympath <local>; .reload /f; .ecxr; k 80`):

```
KERNELBASE!RaiseFailFastException
combase!RoFailFastWithErrorContextInternal2
Windows_UI_Xaml!GetStringRawBuffer+...
twinapi_appcore!BiSessionSinkCreate+... / Ordinal501 / PsmRegisterManagerType / Ordinal4
combase!RoReportFailedDelegate
mrt100_app!RhpRethrow / RhRethrow / RhThrowEx / RhpThrowEx
Windows_UI!CreateControlInputEx+...
Windows_UI_Xaml!DllMain+...
twinapi_appcore!BiNotifyNewUser / Ordinal10
SHCore!SHCreateThreadRef ...
```

Reading: the tap travels through the XAML **text-input** path (`CreateControlInputEx`),
throws a .NET Native exception (`mrt100_app`), gets rethrown across the UWP hosting boundary
(`twinapi_appcore`), and the framework **FailFasts the process** instead of surfacing a
catchable error. Both crashing apps are `Windows.UI.Xaml` apps, which is why two unrelated
codebases die identically on the text/copy path.

## Update 2026-09-28 — non-URL pill now copies (hypothesis revised)

Retest after the `Win+V` reboot (`cbdhsvc_ae4e3 Running`, `TextInputHost` stable since `03:02:17`, `CBS RebootPending False`): tapping a plain-text QR pill no longer crashes — the text appears in clipboard history via `Win+V`. Zero `Application Error 1000` for `WindowsCamera.exe` in the 60 min after the test (only pre-reboot `TextInputHost` crashes at `02:40/02:56` remain).

Revised reading: the `Windows.UI.Xaml 0xc000027b / combase E_FAIL` FailFast needed the broken platform state (per-user `cbdhsvc_* Stopped`, `TextInputHost` crash loop, pending CBS renames) as a trigger. Same Camera build `2026.2607.1.0`, so it was never a pure app bug. The `QrScanner-Tool/` workaround is still valid offline, but no longer required for this path.

## Root cause (best supported hypothesis)

App-level bug in Camera `2026.2607.1.0`: the non-URL pill path throws inside XAML text handling
and nothing catches it. Evidence: URL pills work (different code path — `Launcher`), reinstalling
the identical Store build reproduces it, and the faulting offset never moves. Platform services
(`camsvc`, clipboard, `CDPSvc`, `WSearch` — all verified `Running`) and OS updates
(`26200.9457`, zero pending) change nothing.

## What did NOT help (kept for the record)

- `settings.dat` wipe + `Add-AppxPackage -Register` + full Store reinstall (`9WZDNCRFJBBG`) — same build, same crash.
- WinAppSDK 1.8 runtime update — irrelevant: Camera depends on `Microsoft.UI.Xaml.2.8`, not `WindowsAppRuntime` (verified in `AppxManifest.xml` + installed `WindowsAppRuntime.1.8` present).
- Restoring `cbdhsvc_*` / `CDPSvc` to `Manual` — fixed general clipboard health, not this crash.
- `!analyze -v` with symbol server — hangs on this box; export-symbol stack above was sufficient.

## Workaround that works

`QrScanner-Tool/` in this folder: C# (`csc.exe` + OS `.winmd`, no SDK) captures a webcam still via
`MediaCapture` with `IAsyncInfo` polling (no `await` extensions needed), decodes with ZXing.Net,
copies via Win32 clipboard, shows a dark WPF window. Zero XAML on the path — plain-text QRs
(e.g. passwords) decode and copy without crashing. See its README.

## Report upstream

Feedback Hub / Camera → Send feedback, cite bucket `2305734594999441892`
(`combase E_FAIL` wrapping `Windows.UI.Xaml 0xc000027b` on non-URL QR tap).
