# Post-mortem: el script de debloat que generé rompió 5 features en silencio

*En resumen:* @lapc506 en una sesión pasada generé `servicios_manual_disabled.ps1` y lo
ejecutamos elevado sin análisis por servicio ni red de seguridad; eso dejó ~35 servicios en
`Disabled` y rompió Recortes, Cámara-QR, copiado UWP, Win+V y Wi-Fi. Sobrevivieron los datos
y ya hay runbooks + fixes pusheados; sigue pendiente el reboot + SFC y el rework del borrado CBS.

## Qué pasó

1. *Sesión pasada (fecha exacta no verificada en logs — reporte del usuario):* se generó y
   ejecutó `servicios_manual_disabled.ps1` con `#Requires -RunAsAdministrator`.
2. *El script puso en `Disabled`:* `DPS, TokenBroker, camsvc, wlidsvc, CDPSvc, whesvc, SysMain,
   PcaSvc, iphlpsvc, RasMan, LanmanServer, SensorService, InventorySvc, SSDPSRV, RmSvc`
   (+ plantillas `cbdhsvc, CDPUserSvc, UnistoreSvc, UserDataSvc`, etc. a `Start=4`).
   Evidencia: contenido del archivo leído del Desktop esta sesión.
3. *Tras reinicio:* rotura silenciosa y dispersa en el tiempo — cada síntoma pareció un bug aislado.
4. *Sesión actual:* debugueamos Recortes (`0x80070422` -> `camsvc`), Cámara-QR
   (`0xc000027b`/`E_FAIL`), Win+V (`TextInputHost 0xc0000005`), Wi-Fi (`RmSvc`, runbook propio
   del usuario). La causa común (el script del Desktop) la reveló el usuario, no la investigación
   del agente.
5. *Cierre de sesión:* `Fix-TextInputHost-WinV.ps1` corre pero `REBOOT-DELETE-SCHEDULED: False` —
   el `MoveFileEx` falló; queda por rehacer.

## Qué NO fue

- Ublaze Windows11-Optimizer: solo 10 servicios (lote Xbox/telemetría), verificado contra su
  array `$servicesToDisable`.
- Raphire Win11Debloat (master actual): cero `Set-Service`/`Stop-Service` en el código.
- Drivers, malware, Windows Update o hardware: paquetes `Ok`, updates al día (`26200.9457`,
  0 pendientes), fallas 100% reproducibles por software.

## Causa Raíz

1. Se generó un script de endurecimiento por lista plana sin mapear servicio -> feature
   dependiente (el archivo visible no crea restore point ni backup).
2. Se ejecutó con admin de una sola vez (`Set-Service ... 'Disabled'` en loop): sin "un cambio
   a la vez" ni investigación previa (viola la Iron Law de systematic-debugging).
3. Windows aplica `Start=4` sin advertir dependencias: `WlanSvc` corre pero sin radios (`RmSvc`),
   `ScreenSketch` no registra `windows.capability` (`camsvc`), el broker DataTransfer/TextBox
   falla (`cbdhsvc`/`CDPSvc`), el flyout Win+V hace AV en `SuggestionUIUndocked`.
4. Esta sesión repitió el patrón al inicio: se persiguieron repos externos (Ublaze/Raphire) en vez
   de preguntar "qué scripts corrieron EN esta máquina" (systematic-debugging Fase 1, paso 3).

## La Buena Noticia (todo verificado)

- Recortes 100% funcional (`Win+Shift+S`, rectángulo y pantalla completa verificados).
- Contenidos QR legibles vía `QrScanner-Tool` v2 (`[QR_CODE] 546738` copiado en vivo).
- Wi-Fi restaurado según runbook del usuario (conectado `Akinson 5 G`, 866 Mbps, `192.168.1.90`).
- 3 runbooks Tier 1 + tool + README pusheados; cero binarios en el repo; cero leaks de username
  (barrido `git grep` + `$PSScriptRoot`).
- Sin pérdida de datos en ningún paso.

## Plan de Mitigación en marcha

1. `[x]` Runbooks Tier 1 + `QrScanner-Tool` v2 en `main` — hecho.
2. `[~]` Rework de `Fix-TextInputHost-WinV.ps1` (`MoveFileEx` retornó False) — dueño: agente.
3. `[ ]` Reboot + `sfc /scannow` elevado + retest Win+V — dueño: usuario.
4. `[ ]` Guardarraíl anti-debloat: restore point obligatorio + allowlist + un cambio por vez.
5. `[ ]` Corrección de `servicios_manual_disabled.ps1` — SUPERSEDED por
   `../Windows11_Safe_Debloat_RAM_Runbook/` (baseline 2026-09-28: 7.3 GB total / 5.75 usados).
