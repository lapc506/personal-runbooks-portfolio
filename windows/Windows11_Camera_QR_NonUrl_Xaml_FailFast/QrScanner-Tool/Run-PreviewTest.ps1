Add-Type -Path "C:\Users\guara\QRDemo\lib\zxing.dll"
Add-Type -Path "C:\Users\guara\QRDemo\QrCam.dll"
[QrCam]::StartPreview()
Start-Sleep -Milliseconds 800
$b = [QrCam]::GrabFrame(320, 240)
Write-Output ("FRAME-BYTES: " + $b.Length)
[QrCam]::StopPreview()
Write-Output "PREVIEW-OK"
