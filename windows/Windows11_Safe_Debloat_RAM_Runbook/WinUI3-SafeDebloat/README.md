# WinUI3-SafeDebloat — native WinUI 3 app

Mirrors `Safe-Debloat-Wizard.ps1` (NavigationView rail, category pages, confirm dialog)
with real WinUI 3 controls instead of WPF approximations.

## Current status

- The app builds and opens through `dotnet run` as a packaged WinUI app on the target
  machine. Developer Mode must be enabled for the local debug-package registration flow.
- `SafeDebloat.csproj` uses `Microsoft.WindowsAppSDK 2.4.0`, enables MSIX tooling, and
  includes `Microsoft.Windows.SDK.BuildTools.WinApp 0.7.0` for packaged `dotnet run`.
- A published install/Desktop shortcut and the elevated PowerShell script workflow have
  not yet been validated end to end.

## Build and launch

```powershell
dotnet restore
dotnet run -c Release -p:Platform=x64
```

## Remaining work

- [x] CommunityToolkit **Labs DataTable** importado al Overview (`OverviewPage.xaml`):
  `CommunityToolkit.Labs.WinUI.Controls.DataTable 0.1.260915-build.2673` desde el feed
  `CommunityToolkit-Labs` (ver `NuGet.config`). Namespace `labs="using:CommunityToolkit.WinUI.Controls"`.
- Port pages + worker logic (`Safe-Debloat-Apply.ps1` semantics: restore point, snapshot,
  rollback) to MVVM (CommunityToolkit.Mvvm).
- `ContentDialog` always sets `XamlRoot` (see `ConfirmAsync` — the #1 WinUI 3 pitfall).
