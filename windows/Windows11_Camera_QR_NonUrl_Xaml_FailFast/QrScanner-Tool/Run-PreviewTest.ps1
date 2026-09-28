Add-Type -Path (Join-Path $PSScriptRoot "lib\zxing.dll")
Add-Type -Path (Join-Path $PSScriptRoot "QrCam.dll")
[QrCam]::StartPreview()
Start-Sleep -Milliseconds 800
$b = [QrCam]::GrabFrame(320, 240)
Write-Output ("FRAME-BYTES: " + $b.Length)
[QrCam]::StopPreview()
Write-Output "PREVIEW-OK"
