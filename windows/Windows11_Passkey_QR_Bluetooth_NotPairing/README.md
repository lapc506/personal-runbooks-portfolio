# Windows 11 passkey QR: "Iniciar sesión con una clave de paso" looks like Bluetooth scan is failing

## Symptoms

- GitHub login pops Windows Security `Iniciar sesión con una clave de paso`:
  `iPhone, iPad o dispositivo Android / Clave de paso para github.com`,
  QR + `Digitalizar este código QR con el teléfono o la tableta`,
  `Elegir una clave de paso diferente / Cancelar`.
- User expectation: pair/scan the phone from PC Bluetooth Settings. Phone never appears there, looks like "Bluetooth está fallando a la hora de escanear".

## Environment

- Same box as `Windows11_WiFi_NoNetworks_RmSvc_Disabled` (Windows 11 Home Single Language 10.0.26200, Realtek 8852BE Wi-Fi + Realtek Wireless Bluetooth Adapter `USB\VID_0BDA&PID_B86A`).
- Wi-Fi just restored: `Akinson 5 G conectado, 192.168.1.90, ping 8.8.8.8 0%`.
- Same debloat history (`servicios_manual_disabled.ps1`, Ublaze, Raphire).

## Diagnosis (in order)

1. Check the BT stack, not the QR:
   ```powershell
   Get-Service bthserv,BTAGService,BthAvctpSvc,DeviceAssociationService,DusmSvc,Cdpsvc |
     Format-Table Name, Status, StartType -AutoSize
   Get-Service BluetoothUserService* | Format-Table Name, Status, StartType -AutoSize
   Get-PnpDevice -Class Bluetooth | Select FriendlyName, Status, InstanceId
   ```
   Result here: `BTAGService/BthAvctpSvc/bthserv Running/Manual`, `BluetoothUserService_a464e Running/Manual`, `DeviceAssociationService Running/Manual`, `Cdpsvc Running/Manual`, `RfComm Running`; PnP `Realtek Wireless Bluetooth Adapter OK`, `Enumerador Bluetooth LE OK`, `Enumerador Bluetooth OK`, `RFCOMM OK`. Stack healthy.
2. Check for real BT errors:
   ```powershell
   Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName=@('BTHUSB','BTHPORT','BthServ','DeviceAssociationService'); StartTime=(Get-Date).AddHours(-24)} -MaxEvents 20
   ```
   Only repeat is `BTHPORT Id 18`: `Windows no puede almacenar códigos de autenticación de Bluetooth en el adaptador local`. Informational (classic-pairing link keys / BIOS keyboards), not the passkey flow.
3. Confirm no stale pairing is the issue:
   ```powershell
   Get-PnpDevice -Class Bluetooth | Where FriendlyName -like '*key*'
   # empty — there is nothing to "fix", the phone is not supposed to be paired here
   ```

## Root cause

Misunderstood transport. GitHub cross-device passkey is FIDO2 hybrid / caBLE: the **phone scans the PC's QR**, BLE is only proximity + cloud relay. The phone never appears in PC Bluetooth Settings, so "scanning from Windows" always looks broken. No disabled service was blocking it at check time — `DeviceAssociationService` (set `Disabled` by `servicios_manual_disabled.ps1:23`) was already back to `Running/Manual`, and the Wi-Fi fix had restored `RmSvc/NlaSvc/DPS/iphlpsvc`.

## Fix

Do not pair from Windows. On the phone + PC:

1. Phone: Bluetooth ON, data/Wi-Fi ON, <2m from PC. PC: Bluetooth ON, internet ON (see Wi-Fi runbook).
2. Open the phone **Camera**, point at the PC QR, tap the `FIDO/github.com` prompt, unlock with biometrics, approve.
   - iPhone: Camera > tap notice > iCloud Keychain passkey for `github.com`.
   - Android: Camera/Lens > open in Password Manager > unlock.
3. PC logs in by itself. No code to type.

If the phone has no `github.com` passkey stored, the QR flow cannot succeed — click `Elegir una clave de paso diferente` and use Windows Hello PIN, USB security key, or create the passkey first.

`Check-PasskeyReady.ps1` in this folder is the PC-side preflight (services + radios + Wi-Fi).

## Verification

- PC preflight all green (services `Running`, PnP `OK`, `netsh wlan show interfaces` → `conectado`).
- Phone camera resolves the QR to a `github.com` passkey prompt; approval completes the Windows Security dialog without typing.
- `ping -n 2 8.8.8.8` → `0% perdidos` on both sides is the real network requirement for hybrid relay.

## Failed attempts (kept for the record)

- Looking for the phone under Windows Bluetooth pairing: by design it never shows for caBLE.
- `BTHPORT 18` link-key warning is a red herring for passkeys; fixing classic pairing does not change the QR flow.
- WinRT `BluetoothLEDevice.GetDeviceSelectorFromPairingState` probe from a non-elevated shell adds nothing once `Get-PnpDevice -Class Bluetooth` already reports LE/BRB enumerators `OK`.
