# Decode-Qr.ps1 - decodifica QR/barras desde una foto y copia el texto (via Win32, evita el broker UWP roto)
param([string]$Path = "")
$lib = Join-Path $PSScriptRoot "lib\zxing.dll"
Add-Type -Path $lib
Add-Type -AssemblyName System.Drawing, System.Windows.Forms
if (-not $Path) {
  $dlg = New-Object Windows.Forms.OpenFileDialog
  $dlg.Filter = "Imagenes|*.png;*.jpg;*.jpeg;*.bmp"
  if ($dlg.ShowDialog() -ne "OK") { exit 1 }
  $Path = $dlg.FileName
}
$bmp = [System.Drawing.Bitmap]::FromFile($Path)
$reader = New-Object ZXing.BarcodeReader
$res = $reader.DecodeMultiple($bmp)
$bmp.Dispose()
if (-not $res) { Write-Output "NO-QR-FOUND"; exit 2 }
foreach ($r in $res) { Write-Output ("[{0}] {1}" -f $r.BarcodeFormat, $r.Text) }
Set-Clipboard -Value $res[0].Text
Write-Output "COPIED-OK"
