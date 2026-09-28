Add-Type -Path "C:\Users\guara\QRDemo\lib\zxing.dll"
Add-Type -Path "C:\Users\guara\QRDemo\QrCam.dll"
Add-Type -AssemblyName System.Drawing
Write-Output "LOADED-OK"
$res = [QrCam]::CaptureAndDecode()
if ($res) {
  Write-Output $res
  $first = (($res -split "`n")[0] -replace '^\[[^\]]+\] ', '')
  Set-Clipboard -Value $first
  Write-Output "COPIED-OK"
} else { Write-Output "NO-QR-FOUND" }
