# WinUI3-SafeDebloat — native port scaffold (NOT buildable on the target box yet)

Mirrors `Safe-Debloat-Wizard.ps1` (NavigationView rail, category pages, confirm dialog)
with real WinUI 3 controls instead of WPF approximations.

## Prereqs (absent on target box — only .NET 9 SDK is present)

- Visual Studio 2022 17.12+ with **Windows App SDK** workload (or `dotnet` + Windows SDK +
  manual `Microsoft.WindowsAppSDK` restore), plus package signing for MSIX runs.
- Pin `Microsoft.WindowsAppSDK 1.8.*` to the exact build on first restore.

## Build (once prereqs exist)

```powershell
dotnet restore
dotnet build -c Release
```

## TODO before it compiles clean

- Verify CommunityToolkit **Labs DataTable** package id for the Procesos grid
  (`CommunityToolkit.Labs.WinUI.DataTable` — unconfirmed).
- Port pages + worker logic (`Safe-Debloat-Apply.ps1` semantics: restore point, snapshot,
  rollback) to MVVM (CommunityToolkit.Mvvm).
- `ContentDialog` always sets `XamlRoot` (see `ConfirmAsync` — the #1 WinUI 3 pitfall).
