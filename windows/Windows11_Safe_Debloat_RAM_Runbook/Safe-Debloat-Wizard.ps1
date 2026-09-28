# Safe-Debloat-Wizard.ps1 — stepper-wizard UI (Raphire-tweak model, MUI-vertical-stepper UX).
# PowerShell + WPF, no SDK. Elevation happens only in Safe-Debloat-Apply.ps1 (one UAC).
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne "STA") {
  powershell -STA -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @args; exit $LASTEXITCODE
}
Add-Type -AssemblyName PresentationFramework

function Get-Ram {
  $os = Get-CimInstance Win32_OperatingSystem
  [pscustomobject]@{
    Total = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    Free  = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
    Used  = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1MB, 2)
  }
}

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Title="Safe Debloat — stepper" Height="540" Width="820" Background="White" WindowStartupLocation="CenterScreen">
<Grid>
<Grid.ColumnDefinitions><ColumnDefinition Width="190"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
<StackPanel Grid.Column="0" Background="#F3F3F3" Margin="0">
<TextBlock Text="Safe Debloat" FontSize="18" FontWeight="Bold" Margin="16,16,0,4"/>
<TextBlock Name="S0" Text="1  Medir" Margin="16,12,0,0" FontSize="14"/>
<TextBlock Name="S1" Text="2  Elegir" Margin="16,8,0,0" FontSize="14"/>
<TextBlock Name="S2" Text="3  Confirmar" Margin="16,8,0,0" FontSize="14"/>
<TextBlock Name="S3" Text="4  Verificar" Margin="16,8,0,0" FontSize="14"/>
<TextBlock Text="Fork del modelo Raphire. Solo listas seguras + protegidas." TextWrapping="Wrap" Margin="16,24,16,0" Foreground="#666666"/>
</StackPanel>
<Grid Grid.Column="1" Margin="20">
<Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
<Grid Name="P0" Grid.Row="0">
<StackPanel>
<TextBlock Text="Paso 1 — Línea base de RAM" FontSize="16" FontWeight="Bold"/>
<TextBlock Name="BaseLine" Margin="0,10,0,0" TextWrapping="Wrap"/>
<TextBlock Text="Protegidos (nunca se tocan — incidentes documentados): camsvc, RmSvc, DPS, iphlpsvc, NlaSvc, WlanSvc, Dhcp, CDPSvc, cbdhsvc, TokenBroker, wlidsvc, whesvc, LanmanServer, RasMan, SstpSvc." TextWrapping="Wrap" Margin="0,12,0,0" Foreground="#555555"/>
</StackPanel>
</Grid>
<ScrollViewer Name="P1" Grid.Row="0" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
<StackPanel>
<TextBlock Text="Paso 2 — Elige qué desactivar" FontSize="16" FontWeight="Bold"/>
<TextBlock Text="Telemetría (seguro)" FontWeight="Bold" Margin="0,10,0,0"/>
<CheckBox Name="C_DiagTrack" Content="DiagTrack — telemetría" IsChecked="True"/>
<CheckBox Name="C_dmwappushservice" Content="dmwappushservice — telemetría push" IsChecked="True"/>
<CheckBox Name="C_RetailDemo" Content="RetailDemo — modo tienda" IsChecked="True"/>
<CheckBox Name="C_InventorySvc" Content="InventorySvc — inventario" IsChecked="True"/>
<CheckBox Name="C_nvagent" Content="nvagent — telemetría NVIDIA" IsChecked="True"/>
<CheckBox Name="C_HpTouchpoint" Content="HpTouchpoint — telemetría HP" IsChecked="True"/>
<TextBlock Text="Condicional (solo si no usas la feature)" FontWeight="Bold" Margin="0,10,0,0"/>
<CheckBox Name="C_Xbox" Content="Servicios Xbox (4) — solo sin gaming"/>
<CheckBox Name="C_Maps" Content="MapsBroker + lfsvc — solo sin mapas/ubicación"/>
<CheckBox Name="C_SysMain" Content="SysMain — ahorra RAM, cuesta lanzamientos en HDD"/>
<CheckBox Name="C_Misc" Content="PcaSvc + TrkWks + lmhosts + DusmSvc — bajo riesgo"/>
</StackPanel>
</ScrollViewer>
<Grid Name="P2" Grid.Row="0" Visibility="Collapsed">
<StackPanel>
<TextBlock Text="Paso 3 — Confirmar" FontSize="16" FontWeight="Bold"/>
<TextBlock Name="Summary" Margin="0,10,0,0" TextWrapping="Wrap"/>
<CheckBox Name="C_Restore" Content="Crear restore point antes (recomendado)" IsChecked="True" Margin="0,10,0,0"/>
<Button Name="BApply" Content="Aplicar (pide 1 UAC)" Width="180" HorizontalAlignment="Left" Margin="0,10,0,0" Background="#0078D4" Foreground="White"/>
<TextBlock Name="ApplyStatus" Margin="0,8,0,0" TextWrapping="Wrap"/>
</StackPanel>
</Grid>
<Grid Name="P3" Grid.Row="0" Visibility="Collapsed">
<StackPanel>
<TextBlock Text="Paso 4 — Verificar" FontSize="16" FontWeight="Bold"/>
<TextBlock Name="VerifyBox" Margin="0,10,0,0" TextWrapping="Wrap"/>
<TextBlock Text="Checklist: scan Wi-Fi, Win+Shift+S, Win+V, Store, login MSA. Si algo falla: corre Rollback-Debloat.ps1 (generado junto al script)." TextWrapping="Wrap" Margin="0,10,0,0"/>
</StackPanel>
</Grid>
<StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,12,0,0">
<Button Name="BBack" Content="← Back" Width="90"/>
<StackPanel Name="Dots" Orientation="Horizontal" VerticalAlignment="Center" Margin="20,0,20,0"/>
<Button Name="BNext" Content="Next →" Width="90" Background="#0078D4" Foreground="White"/>
</StackPanel>
</Grid>
</Grid>
</Window>
"@
$w = [Windows.Markup.XamlReader]::Parse($xaml)
$pages = @($w.FindName("P0"), $w.FindName("P1"), $w.FindName("P2"), $w.FindName("P3"))
$steps = @($w.FindName("S0"), $w.FindName("S1"), $w.FindName("S2"), $w.FindName("S3"))
$script:page = 0
$dots = $w.FindName("Dots")
$dotEls = @()
for ($i = 0; $i -lt 4; $i++) {
  $e = New-Object Windows.Shapes.Ellipse
  $e.Width = 10; $e.Height = 10; $e.Margin = "4,0,4,0"
  $dots.Children.Add($e) | Out-Null; $dotEls += $e
}
function Show-Page($p) {
  $script:page = $p
  for ($i = 0; $i -lt 4; $i++) {
    $pages[$i].Visibility = if ($i -eq $p) { "Visible" } else { "Collapsed" }
    $steps[$i].FontWeight = if ($i -eq $p) { "Bold" } else { "Normal" }
    $dotEls[$i].Fill = if ($i -eq $p) {
      New-Object Windows.Media.SolidColorBrush([Windows.Media.Color]::FromRgb(0,120,212))
    } else {
      New-Object Windows.Media.SolidColorBrush([Windows.Media.Color]::FromRgb(200,200,200))
    }
  }
  $w.FindName("BBack").IsEnabled = ($p -gt 0)
  $w.FindName("BNext").Content = if ($p -eq 3) { "Cerrar" } else { "Next →" }
  if ($p -eq 2) { Build-Summary }
}
function Get-Selection {
  $sel = @()
  foreach ($n in @('DiagTrack','dmwappushservice','RetailDemo','InventorySvc','nvagent')) {
    $cb = $w.FindName("C_$n"); if ($cb -and $cb.IsChecked) { $sel += $n }
  }
  if ($w.FindName("C_HpTouchpoint").IsChecked) { $sel += 'HpTouchpointAnalyticsService' }
  if ($w.FindName("C_Xbox").IsChecked) { $sel += @('XblAuthManager','XblGameSave','XboxGipSvc','XboxNetApiSvc') }
  if ($w.FindName("C_Maps").IsChecked) { $sel += @('MapsBroker','lfsvc') }
  if ($w.FindName("C_SysMain").IsChecked) { $sel += 'SysMain' }
  if ($w.FindName("C_Misc").IsChecked) { $sel += @('PcaSvc','TrkWks','lmhosts','DusmSvc') }
  return $sel
}
function Build-Summary {
  $sel = Get-Selection
  $w.FindName("Summary").Text = "Se desactivarán $($sel.Count): " + ($sel -join ', ')
}
$ram0 = Get-Ram
$w.FindName("BaseLine").Text = "Total: $($ram0.Total) GB | En uso: $($ram0.Used) GB | Libre: $($ram0.Free) GB (cierra apps y repite para comparar)"
$w.FindName("BBack").Add_Click({ if ($script:page -gt 0) { Show-Page ($script:page - 1) } })
$w.FindName("BNext").Add_Click({
  if ($script:page -eq 3) { $w.Close(); return }
  Show-Page ($script:page + 1)
})
$w.FindName("BApply").Add_Click({
  $st = $w.FindName("ApplyStatus"); $st.Text = "Aplicando..."
  $sel = Get-Selection
  @{ Services = $sel; CreateRestorePoint = [bool]$w.FindName("C_Restore").IsChecked } |
    ConvertTo-Json | Set-Content "$env:TEMP\SafeDebloat-Selection.json" -Encoding UTF8
  Remove-Item "$env:TEMP\SafeDebloat-Done.txt" -ErrorAction SilentlyContinue
  & (Join-Path $PSScriptRoot "Safe-Debloat-Apply.ps1")
  if (Test-Path "$env:TEMP\SafeDebloat-Done.txt") {
    $ram1 = Get-Ram
    $st.Text = "Aplicado. Rollback en Rollback-Debloat.ps1."
    $w.FindName("VerifyBox").Text = "Antes: $($ram0.Used) GB usados / Después: $($ram1.Used) GB usados. Ahorro: $([math]::Round($ram0.Used - $ram1.Used, 2)) GB (misma ociosidad)."
  } else { $st.Text = "Cancelado o falló (revisa SafeDebloat-Apply.log en TEMP)." }
})
Show-Page 0
[void]$w.ShowDialog()
