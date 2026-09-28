# QR-Scan.ps1 - escanea QR con la webcam (foto via MediaCapture) o desde imagen, decodifica con ZXing, copia por Win32
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne "STA") {
  powershell -STA -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @args; exit $LASTEXITCODE
}
$lib = Join-Path $PSScriptRoot "lib\zxing.dll"
Add-Type -Path (Join-Path $PSScriptRoot "lib\zxing.dll")
Add-Type -Path (Join-Path $PSScriptRoot "QrCam.dll")
Add-Type -AssemblyName PresentationFramework, System.Drawing, System.Windows.Forms

function Capture-QR {
  $txt = [QrCam]::CaptureAndDecode()
  if (-not $txt) { return $null }
  return $txt -split "`n" | ForEach-Object {
    if ($_ -match '^\[(.+)\] (.*)$') { [pscustomobject]@{ BarcodeFormat = $Matches[1]; Text = $Matches[2] } }
  }
}

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Title="QR Scanner" Height="340" Width="460" Background="#1E1E2E" WindowStartupLocation="CenterScreen">
<StackPanel Margin="16">
<TextBlock Text="QR Scanner" Foreground="White" FontSize="20" FontWeight="Bold" Margin="0,0,0,4"/>
<TextBlock Name="Status" Text="Listo." Foreground="#A0A0A0" Margin="0,0,0,8"/>
<TextBox Name="Out" Height="120" Background="#11111B" Foreground="White" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" IsReadOnly="True"/>
<StackPanel Orientation="Horizontal" Margin="0,10,0,0">
<Button Name="BScan" Content="Capturar QR" Width="110" Margin="0,0,8,0"/>
<Button Name="BFile" Content="Desde imagen" Width="110" Margin="0,0,8,0"/>
<Button Name="BCopy" Content="Copiar" Width="80" Margin="0,0,8,0"/>
<Button Name="BClose" Content="Cerrar" Width="70"/>
</StackPanel>
</StackPanel>
</Window>
"@
$w = [Windows.Markup.XamlReader]::Parse($xaml)
$st = $w.FindName("Status"); $out = $w.FindName("Out")
$w.FindName("BScan").Add_Click({
  try { $st.Text = "Capturando..."; $w.UpdateLayout()
    $r = Capture-QR
    if (-not $r) { $st.Text = "Sin QR visible. Acerca el celular."; return }
    $out.Text = ($r | ForEach-Object { "[{0}] {1}" -f $_.BarcodeFormat, $_.Text }) -join "`r`n"
    Set-Clipboard -Value $r[0].Text; $st.Text = "Decodificado + copiado."
  } catch { $st.Text = "Error: " + $_.Exception.Message }
})
$w.FindName("BFile").Add_Click({
  $d = New-Object Windows.Forms.OpenFileDialog
  $d.Filter = "Imagenes|*.png;*.jpg;*.jpeg;*.bmp"
  if ($d.ShowDialog() -ne "OK") { return }
  $b = [System.Drawing.Bitmap]::FromFile($d.FileName)
  $zr = New-Object ZXing.BarcodeReader
  $found = $zr.DecodeMultiple($b); $b.Dispose()
  $r = ($found | ForEach-Object { [pscustomobject]@{ BarcodeFormat = "$($_.BarcodeFormat)"; Text = $_.Text } })
  if (-not $r) { $st.Text = "No se encontro QR."; return }
  $out.Text = ($r | ForEach-Object { "[{0}] {1}" -f $_.BarcodeFormat, $_.Text }) -join "`r`n"
  Set-Clipboard -Value $r[0].Text; $st.Text = "Decodificado + copiado."
})
$w.FindName("BCopy").Add_Click({ if ($out.Text) { Set-Clipboard -Value $out.Text; $st.Text = "Copiado." } })
$w.FindName("BClose").Add_Click({ $w.Close() })
[void]$w.ShowDialog()
