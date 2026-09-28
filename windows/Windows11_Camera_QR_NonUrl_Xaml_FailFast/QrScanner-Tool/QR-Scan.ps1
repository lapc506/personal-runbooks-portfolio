# QR-Scan.ps1 - escanea QR con la webcam (foto via MediaCapture) o desde imagen, decodifica con ZXing, copia por Win32
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne "STA") {
  powershell -STA -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @args; exit $LASTEXITCODE
}
Add-Type -Path (Join-Path $PSScriptRoot "lib\zxing.dll")
Add-Type -Path (Join-Path $PSScriptRoot "QrCam.dll")
Add-Type -AssemblyName PresentationFramework, System.Drawing, System.Windows.Forms

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="QR Scanner" Height="520" Width="700" Background="#1E1E2E" WindowStartupLocation="CenterScreen" FontFamily="Segoe UI Variable Text">
<Window.Resources>
<Style TargetType="Button">
<Setter Property="Padding" Value="12,6"/>
<Setter Property="Margin" Value="0,0,8,0"/>
<Setter Property="Background" Value="#2D2D3A"/>
<Setter Property="Foreground" Value="White"/>
<Setter Property="BorderBrush" Value="#3E3E4E"/>
<Setter Property="BorderThickness" Value="1"/>
<Setter Property="Template">
<Setter.Value>
<ControlTemplate TargetType="Button">
<Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="4" Padding="{TemplateBinding Padding}">
<ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
</Border>
<ControlTemplate.Triggers>
<Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#3A3A4A"/></Trigger>
<Trigger Property="IsPressed" Value="True"><Setter Property="Background" Value="#0078D4"/></Trigger>
<Trigger Property="IsEnabled" Value="False"><Setter Property="Foreground" Value="#777777"/></Trigger>
</ControlTemplate.Triggers>
</ControlTemplate>
</Setter.Value>
</Setter>
</Style>
<Style x:Key="AccentButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
<Setter Property="Background" Value="#0078D4"/>
<Setter Property="BorderBrush" Value="#0078D4"/>
</Style>
</Window.Resources>
<Grid Margin="16">
<Grid.ColumnDefinitions><ColumnDefinition Width="170"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
<StackPanel Grid.Column="0" Margin="0,0,12,0">
<TextBlock Text="QR Scanner" Foreground="White" FontSize="20" FontWeight="Bold" Margin="0,0,0,4"/>
<TextBlock Name="Status" Text="Iniciando camara..." Foreground="#A0A0A0" Margin="0,0,0,8" TextWrapping="Wrap"/>
<Button Name="BScan" Content="Capturar QR" Style="{StaticResource AccentButton}" Margin="0,0,0,8"/>
<Button Name="BFile" Content="Desde imagen" Margin="0,0,0,8"/>
<Button Name="BCopy" Content="Copiar" Margin="0,0,0,8"/>
<Button Name="BClose" Content="Cerrar" Margin="0,0,0,8"/>
</StackPanel>
<StackPanel Grid.Column="1">
<Image Name="Preview" Height="250" Stretch="Uniform" Margin="0,0,0,8"/>
<TextBox Name="Out" Height="150" Background="#11111B" Foreground="White" FontFamily="Cascadia Mono,Consolas" FontSize="32" TextAlignment="Center" VerticalContentAlignment="Center" TextWrapping="Wrap" IsReadOnly="True"/>
</StackPanel>
</Grid>
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
  $out.Text = ($objs | ForEach-Object { $_.Text }) -join "`r`n"
  Set-Clipboard -Value $objs[0].Text
  $st.Text = "Decodificado + copiado ($($objs[0].BarcodeFormat))."
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
