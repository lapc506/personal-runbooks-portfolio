# QR-Scan.ps1 - escanea QR con la webcam (foto via MediaCapture) o desde imagen, decodifica con ZXing, copia por Win32
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne "STA") {
  powershell -STA -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @args; exit $LASTEXITCODE
}
Add-Type -Path (Join-Path $PSScriptRoot "lib\zxing.dll")
Add-Type -Path (Join-Path $PSScriptRoot "QrCam.dll")
Add-Type -AssemblyName PresentationFramework, System.Drawing, System.Windows.Forms

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Title="QR Scanner" Height="560" Width="460" Background="#1E1E2E" WindowStartupLocation="CenterScreen">
<StackPanel Margin="16">
<TextBlock Text="QR Scanner" Foreground="White" FontSize="20" FontWeight="Bold" Margin="0,0,0,4"/>
<TextBlock Name="Status" Text="Iniciando camara..." Foreground="#A0A0A0" Margin="0,0,0,8"/>
<Image Name="Preview" Height="200" Stretch="Uniform" Margin="0,0,0,8"/>
<TextBox Name="Out" Height="90" Background="#11111B" Foreground="White" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" IsReadOnly="True"/>
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
$st = $w.FindName("Status"); $out = $w.FindName("Out"); $img = $w.FindName("Preview")

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(400)
$timer.Add_Tick({
  try {
    $b = [QrCam]::GrabFrame(320, 240)
    $ms = New-Object System.IO.MemoryStream(,$b)
    $bi = New-Object System.Windows.Media.Imaging.BitmapImage
    $bi.BeginInit()
    $bi.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bi.StreamSource = $ms
    $bi.EndInit(); $bi.Freeze()
    $img.Source = $bi
    $ms.Dispose()
  } catch { }
})

function Show-Result($r) {
  if (-not $r) { $st.Text = "Sin QR visible. Apunta al codigo."; return }
  $objs = $r | ForEach-Object { [pscustomobject]@{ BarcodeFormat = $_.BarcodeFormat; Text = $_.Text } }
  $out.Text = ($objs | ForEach-Object { "[{0}] {1}" -f $_.BarcodeFormat, $_.Text }) -join "`r`n"
  Set-Clipboard -Value $objs[0].Text
  $st.Text = "Decodificado + copiado."
}

$w.FindName("BScan").Add_Click({
  $btn = $w.FindName("BScan"); $btn.IsEnabled = $false
  $out.Text = ""; $st.Text = "Capturando..."
  try {
    $timer.Stop(); [QrCam]::StopPreview()
    try {
      $txt = [QrCam]::CaptureAndDecode()
      $r = if ($txt) { $txt -split "`n" | ForEach-Object {
        if ($_ -match '^\[(.+)\] (.*)$') { [pscustomobject]@{ BarcodeFormat = $Matches[1]; Text = $Matches[2] } } } }
      Show-Result $r
    } finally { [QrCam]::StartPreview(); $timer.Start() }
  } catch { $st.Text = "Error: " + $_.Exception.Message }
  $btn.IsEnabled = $true
})
$w.FindName("BFile").Add_Click({
  $d = New-Object Windows.Forms.OpenFileDialog
  $d.Filter = "Imagenes|*.png;*.jpg;*.jpeg;*.bmp"
  if ($d.ShowDialog() -ne "OK") { return }
  $out.Text = ""
  $b = [System.Drawing.Bitmap]::FromFile($d.FileName)
  $zr = New-Object ZXing.BarcodeReader
  $found = $zr.DecodeMultiple($b); $b.Dispose()
  $r = ($found | ForEach-Object { [pscustomobject]@{ BarcodeFormat = "$($_.BarcodeFormat)"; Text = $_.Text } })
  Show-Result $r
})
$w.FindName("BCopy").Add_Click({ if ($out.Text) { Set-Clipboard -Value $out.Text; $st.Text = "Copiado." } })
$w.FindName("BClose").Add_Click({ $w.Close() })
$w.Add_Loaded({
  try { [QrCam]::StartPreview(); $timer.Start(); $st.Text = "Listo. Apunta al QR." }
  catch { $st.Text = "Camara no disponible: " + $_.Exception.Message }
})
$w.Add_Closed({ $timer.Stop(); [QrCam]::StopPreview() })
[void]$w.ShowDialog()
