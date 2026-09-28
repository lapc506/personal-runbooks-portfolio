Add-Type -Path (Join-Path $PSScriptRoot "lib\zxing.dll")
Add-Type -Path (Join-Path $PSScriptRoot "QrCam.dll")
Add-Type -AssemblyName System.Drawing
Write-Output "LOADED-OK"
$res = [QrCam]::CaptureAndDecode()
if ($res) {
  Write-Output $res
  $first = (($res -split "`n")[0] -replace '^\[[^\]]+\] ', '')
  Set-Clipboard -Value $first
  Write-Output "COPIED-OK"
} else { Write-Output "NO-QR-FOUND" }
