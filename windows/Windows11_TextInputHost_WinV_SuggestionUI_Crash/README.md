# Windows 11 `Win+V` dead: `TextInputHost.exe` access violation in `SuggestionUIUndocked`

> Status: **UNRESOLVED** — crash characterized, fix pending reboot + SFC.
> The bundled `Fix-TextInputHost-WinV.ps1` performs every elevated step behind a single UAC prompt.

## Symptoms

- `Win+V` (clipboard history flyout) opens nothing. Each press crashes `TextInputHost.exe`.
- `Application Error 1000`, stable signature:
  ```
  TextInputHost.exe 2607.27000.0.0 → WindowsInternal.ComposableShell.Experiences.SuggestionUIUndocked
  0xc0000005 (access violation)
  ```
  (`MoAppCrash` bucket `1907208325684907408`.) Different family from the Camera/Snipping
  stowed exceptions — this one is a null-deref-style crash in the suggestion UI host.
- Host binary: `C:\Windows\SystemApps\MicrosoftWindows.Client.CBS_cw5n1h2txyewy\TextInputHost.exe`
  (auto-respawns; part of the Client.CBS package with its state in
  `%LOCALAPPDATA%\Packages\MicrosoftWindows.Client.CBS_cw5n1h2txyewy\Settings\settings.dat`, 128 KB).

## Dead ends (kept so nobody repeats them)

- Toggling `HKCU\SOFTWARE\Microsoft\Clipboard\EnableClipboardHistory` 1→0→1 changes nothing.
  (The `0` interval only made `Win+V` show "history off" instead of crashing.)
- Deleting the CBS `settings.dat` fails: `IOException ... siendo utilizado en otro proceso`.
  `handle64.exe` (even elevated) reports **no matching handles** — lock is transient
  (host respawn) or held without a visible handle. Kill+delete races always lose.
- SCM System log (7d, IDs 7000/7001/7003/7009/7023/7031/7034 + DCOM 10005) is clean for this —
  same lesson as the other runbooks: broken shell components fail silently there.
- `sfc /scannow` refuses to run: a system repair is pending reboot
  (`Está pendiente una reparación del sistema que requiere reiniciar`).

## Plan (encoded in `Fix-TextInputHost-WinV.ps1`)

1. Self-elevate (single UAC), re-assert platform services to defaults
   (`camsvc`/`CDPSvc`/`cbdhsvc` template+instance → `Manual`, start `camsvc`).
2. Stop `TextInputHost`, attempt direct `settings.dat` delete; on lock, schedule
   `MoveFileEx(... DELAY_UNTIL_REBOOT)` and verify `PendingFileRenameOperations`.
3. Report reboot-pending state. After reboot: `sfc /scannow`, retest `Win+V`,
   and if it still crashes, capture via WER `LocalDumps\TextInputHost.exe` + `cdb` stack
   (procedure in the Camera runbook).
