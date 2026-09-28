# Windows Runbooks

## WinUI 3: Developer Mode and Windows App Runtime

### Verified findings

- The repository's `WinUI3-SafeDebloat` project now enables MSIX tooling and references
  `Microsoft.WindowsAppSDK 2.4.0` plus `Microsoft.Windows.SDK.BuildTools.WinApp 0.7.0`.
- With Developer Mode enabled, `dotnet run -c Release -p:Platform=x64` launched the real
  Safe Debloat app as a packaged app; the visible window showed its navigation and service
  catalog. This verifies the app's packaged debug-launch path, not a published install or
  desktop shortcut.
- A separate stock WinUI probe was tested both unpackaged and packaged. Starting its
  unpackaged `.exe` failed during Windows App Runtime auto-initialization with
  `0x80040154 (REGDB_E_CLASSNOTREG)`. That earlier test used a different, unpackaged launch
  path; it does not contradict the successful packaged launch or establish global Windows
  damage.
- The packaged `dotnet run` path initially stopped before launch because Developer Mode was
  disabled. After it was enabled in Settings, the Windows App Development CLI registered
  the debug package identity. Developer Mode is required for this local debug-packaging
  workflow.
- Asking NuGet for `Microsoft.WindowsAppSDK 2.3.12` produced warning `NU1603`: that exact
  version was unavailable, so NuGet resolved `2.4.0`. Pinning `2.4.0` exactly removed the
  warning and both the probe and real app launched as packaged apps.
- `sfc /scannow` reported no integrity violations. That result does not explain the
  difference between packaged and unpackaged activation.

### Launch the real app

Enable **Settings > System > For developers > Developer Mode** first, then run from the
repository root:

```powershell
$project = 'windows\Windows11_Safe_Debloat_RAM_Runbook\WinUI3-SafeDebloat\SafeDebloat.csproj'
dotnet run --project $project -c Release -p:Platform=x64
```

The desktop shortcut/published installation and the UAC script-execution workflow still
need separate end-to-end validation. Do not infer those results from `dotnet run`.