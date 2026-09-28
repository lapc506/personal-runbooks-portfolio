# QrScanner-Tool — webcam QR reader that avoids the broken UWP/XAML copy path

Reads QR/barcodes with the laptop webcam (or an image file), decodes with ZXing.Net,
copies via the Win32 clipboard. Written because Camera and third-party UWP scanners crash
on plain-text QR payloads on this box (see parent README).

## Layout

- `QrCam.cs` — C# capture core: `MediaCapture` still photo → JPEG bytes → ZXing `DecodeMultiple`.
  Compiled with the in-box Framework `csc.exe` against the OS `.winmd` files; uses
  `IAsyncInfo.Status` polling instead of `await` (no WinRT await extensions needed).
- `build.bat` — one-shot compile to `QrCam.dll` (no SDK: no `dotnet`, no VS, no cargo).
- `QR-Scan.ps1` — dark WPF window: **Capturar QR** (webcam), **Desde imagen** (file),
  **Copiar**. Self-elevates to STA.
- `Decode-Qr.ps1` — file-only variant (no camera).
- `Run-Test.ps1` — headless capture→decode→clipboard smoke test.

## Prereqs

- `lib\zxing.dll` — ZXing.Net 0.16.11 `net40` build, fetched once from NuGet (not vendored):
  ```powershell
  $v = (Invoke-RestMethod 'https://api.nuget.org/v3-flatcontainer/zxing.net/index.json').versions |
    Where-Object { $_ -notmatch '-' } | Select-Object -Last 1
  Invoke-WebRequest "https://api.nuget.org/v3-flatcontainer/zxing.net/$v/zxing.net.$v.nupkg" -OutFile zxing.zip
  Expand-Archive zxing.zip zxingpkg; Copy-Item zxingpkg\lib\net40\zxing.dll lib\
  ```
- Webcam + camera privacy consent on first capture.

## Run

```powershell
.\build.bat
powershell -ExecutionPolicy Bypass -File .\QR-Scan.ps1
```

Hold the QR up to the webcam, click **Capturar QR**. First capture initializes the camera (slow);
subsequent ones are fast. Clipboard history stays untouched (Win32 `Set-Clipboard` path).
