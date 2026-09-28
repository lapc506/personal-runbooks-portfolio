# Safe-Debloat-Wizard.ps1 — stepper: una fase por categoría (fork del modelo Raphire, UX stepper).
# PowerShell + WPF, sin SDK. La elevación ocurre solo en Safe-Debloat-Apply.ps1 (un UAC).
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne "STA") {
  powershell -STA -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @args; exit $LASTEXITCODE
}
Add-Type -AssemblyName PresentationFramework

$groups = @(
  @{ Title = 'Privacidad'; Items = @(
    @{ Id = 'T_Ads'; Label = 'Sin ID de publicidad ni experiencias a medida';
       Tip = 'AdvertisingInfo\Enabled=0 + TailoredExperiences=0. Solo anuncios y sugerencias.'; On = $true }) },
  @{ Title = 'Explorador'; Items = @(
    @{ Id = 'T_Explorer'; Label = 'Extensiones visibles + ocultos + abrir en Este equipo';
       Tip = 'HideFileExt=0, Hidden=1, LaunchTo=1. Solo vista, reversible.'; On = $true }) },
  @{ Title = 'Barra de tareas'; Items = @(
    @{ Id = 'T_Taskbar'; Label = 'Izquierda, sin widgets ni Task View';
       Tip = 'TaskbarAl=0, TaskbarDa=0, ShowTaskViewButton=0.'; On = $true }) },
  @{ Title = 'Búsqueda y Copilot'; Items = @(
    @{ Id = 'T_Search'; Label = 'Sin Bing en buscar + sin Copilot';
       Tip = 'DisableSearchBoxSuggestions=1, TurnOffWindowsCopilot=1, ShowCopilotButton=0.'; On = $true }) },
  @{ Title = 'Servicios: telemetría'; Items = @(
    @{ Id = 'S_Telemetry'; Label = 'DiagTrack, dmwappushservice, RetailDemo, InventorySvc, nvagent, HP';
       Tip = 'Telemetría y vendor. Sin dependientes en Home.'; On = $true }) },
  @{ Title = 'Servicios: condicional'; Items = @(
    @{ Id = 'S_Xbox'; Label = 'Xbox (4) — solo sin gaming';
       Tip = 'XblAuthManager, XblGameSave, XboxGipSvc, XboxNetApiSvc.'; On = $false },
    @{ Id = 'S_Maps'; Label = 'Mapas y ubicación — solo si no los usas';
       Tip = 'MapsBroker + lfsvc.'; On = $false },
    @{ Id = 'S_SysMain'; Label = 'SysMain — ahorra RAM (mide antes/después)';
       Tip = 'En HDD enlentece aperturas; en SSD neutro.'; On = $false },
    @{ Id = 'S_Misc'; Label = 'PcaSvc + TrkWks + lmhosts + DusmSvc';
       Tip = 'Riesgo bajo.'; On = $false }) }
)

$tweakDefs = @{
  T_Ads      = @(@{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; Name = 'Enabled'; Value = 0 },
                  @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Privacy'; Name = 'TailoredExperiencesWithDiagnosticDataEnabled'; Value = 0 })
  T_Explorer = @(@{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'HideFileExt'; Value = 0 },
                  @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'Hidden'; Value = 1 },
                  @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'LaunchTo'; Value = 1 })
  T_Taskbar  = @(@{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'TaskbarAl'; Value = 0 },
                  @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'TaskbarDa'; Value = 0 },
                  @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'ShowTaskViewButton'; Value = 0 })
  T_Search   = @(@{ Path = 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\Explorer'; Name = 'DisableSearchBoxSuggestions'; Value = 1 },
                  @{ Path = 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot'; Name = 'TurnOffWindowsCopilot'; Value = 1 },
                  @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'ShowCopilotButton'; Value = 0 })
}
$svcDefs = @{
  S_Telemetry = @('DiagTrack','dmwappushservice','RetailDemo','InventorySvc','nvagent','HpTouchpointAnalyticsService')
  S_Xbox      = @('XblAuthManager','XblGameSave','XboxGipSvc','XboxNetApiSvc')
  S_Maps      = @('MapsBroker','lfsvc')
  S_SysMain   = @('SysMain')
  S_Misc      = @('PcaSvc','TrkWks','lmhosts','DusmSvc')
}

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="Safe Debloat — stepper" Height="540" Width="820" Background="White" WindowStartupLocation="CenterScreen" FontFamily="Segoe UI Variable Text">
<Window.Resources>
<Style TargetType="Button">
<Setter Property="Padding" Value="12,6"/>
<Setter Property="Background" Value="#F5F5F5"/>
<Setter Property="Foreground" Value="#1B1B1B"/>
<Setter Property="BorderBrush" Value="#E1E1E1"/>
<Setter Property="BorderThickness" Value="1"/>
<Setter Property="Template">
<Setter.Value>
<ControlTemplate TargetType="Button">
<Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="4" Padding="{TemplateBinding Padding}">
<ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
</Border>
<ControlTemplate.Triggers>
<Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#EAEAEA"/></Trigger>
<Trigger Property="IsPressed" Value="True"><Setter Property="Background" Value="#DADADA"/></Trigger>
</ControlTemplate.Triggers>
</ControlTemplate>
</Setter.Value>
</Setter>
</Style>
<Style x:Key="AccentButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
<Setter Property="Background" Value="#0078D4"/>
<Setter Property="Foreground" Value="White"/>
<Setter Property="BorderBrush" Value="#0078D4"/>
</Style>
<Style x:Key="ToggleSwitch" TargetType="CheckBox">
<Setter Property="Margin" Value="0,6,0,6"/>
<Setter Property="Template">
<Setter.Value>
<ControlTemplate TargetType="CheckBox">
<StackPanel Orientation="Horizontal">
<Border Name="track" Width="52" Height="28" CornerRadius="14" Background="#8A8A8A">
<Ellipse Name="thumb" Width="20" Height="20" Fill="White" HorizontalAlignment="Left" Margin="4,0,0,0"/>
</Border>
<ContentPresenter Margin="10,0,0,0" VerticalAlignment="Center"/>
</StackPanel>
<ControlTemplate.Triggers>
<Trigger Property="IsChecked" Value="True">
<Setter TargetName="track" Property="Background" Value="#0078D4"/>
<Setter TargetName="thumb" Property="HorizontalAlignment" Value="Right"/>
<Setter TargetName="thumb" Property="Margin" Value="0,0,4,0"/>
</Trigger>
<Trigger Property="IsMouseOver" Value="True">
<Setter TargetName="track" Property="Opacity" Value="0.85"/>
</Trigger>
</ControlTemplate.Triggers>
</ControlTemplate>
</Setter.Value>
</Setter>
</Style>
</Window.Resources>
<Grid>
<Grid.ColumnDefinitions><ColumnDefinition Width="200"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
<StackPanel Grid.Column="0" Background="#F3F3F3">
<TextBlock Text="Safe Debloat" FontSize="18" FontWeight="Bold" Margin="16,16,0,4"/>
<StackPanel Name="StepList" Margin="16,8,0,0"/>
<TextBlock Text="Protegidos: camsvc, RmSvc, DPS, iphlpsvc, red, CDPSvc, cbdhsvc. Nunca seleccionables." TextWrapping="Wrap" Margin="16,24,16,0" Foreground="#666666"/>
</StackPanel>
<Grid Grid.Column="1" Margin="20">
<Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
<ScrollViewer Grid.Row="0" VerticalScrollBarVisibility="Auto"><StackPanel Name="PageHost"/></ScrollViewer>
<StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,12,0,0">
<Button Name="BBack" Content="&#8592; Back" Width="90"/>
<StackPanel Name="Dots" Orientation="Horizontal" VerticalAlignment="Center" Margin="20,0,20,0"/>
<Button Name="BNext" Content="Next &#8594;" Width="90" Style="{StaticResource AccentButton}"/>
</StackPanel>
</Grid>
</Grid>
</Window>
"@
$w = [Windows.Markup.XamlReader]::Parse($xaml)
$stepList = $w.FindName("StepList"); $host_ = $w.FindName("PageHost"); $dots = $w.FindName("Dots")
$phaseTitles = @('Medir') + ($groups | ForEach-Object { $_.Title }) + @('Confirmar', 'Verificar')
$nPhases = $phaseTitles.Count
$checkBoxes = @{}
$script:page = 0

for ($i = 0; $i -lt $nPhases; $i++) {
  $t = New-Object Windows.Controls.TextBlock
  $t.Text = "$($i + 1)  $($phaseTitles[$i])"; $t.FontSize = 14; $t.Margin = "0,4,0,0"
  $stepList.Children.Add($t) | Out-Null
  $e = New-Object Windows.Shapes.Ellipse
  $e.Width = 10; $e.Height = 10; $e.Margin = "4,0,4,0"
  $dots.Children.Add($e) | Out-Null
}
function Get-Ram {
  $os = Get-CimInstance Win32_OperatingSystem
  [pscustomobject]@{ Total = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    Used = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1MB, 2) }
}
$script:ram0 = Get-Ram
$script:applied = $false

function Render-Page($p) {
  $host_.Children.Clear()
  $h = New-Object Windows.Controls.TextBlock
  if ($p -eq 0) {
    $t0 = New-Object Windows.Controls.TextBlock
    $t0.Text = "Bienvenido"; $t0.FontSize = 24; $t0.FontWeight = "Bold"
    $host_.Children.Add($t0) | Out-Null
    $t1 = New-Object Windows.Controls.TextBlock
    $t1.Text = "Vamos a reducir tu consumo de RAM. Primero medimos tu punto de partida (cierra apps y repite para comparar)."
    $t1.Margin = "0,4,0,10"; $t1.TextWrapping = "Wrap"; $t1.Foreground = "#555555"
    $host_.Children.Add($t1) | Out-Null
    $pct = [math]::Round($script:ram0.Used / $script:ram0.Total * 100)
    $big = New-Object Windows.Controls.TextBlock
    $big.Text = "Memoria: $($script:ram0.Used)/$($script:ram0.Total) GB ($pct%)"
    $big.FontSize = 18; $big.FontWeight = "Bold"; $big.Margin = "0,0,0,6"
    $host_.Children.Add($big) | Out-Null
    $pb = New-Object Windows.Controls.ProgressBar
    $pb.Minimum = 0; $pb.Maximum = 100; $pb.Value = $pct; $pb.Height = 18
    $host_.Children.Add($pb) | Out-Null
    $top = Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 5 |
      ForEach-Object { "{0}: {1} MB" -f $_.ProcessName, [math]::Round($_.WorkingSet64 / 1MB) }
    $tt = New-Object Windows.Controls.TextBlock
    $tt.Text = "Top RAM ahora:`n" + ($top -join "`n")
    $tt.Margin = "0,10,0,0"; $tt.FontFamily = "Consolas"; $tt.Foreground = "#333333"
    $host_.Children.Add($tt) | Out-Null
  } elseif ($p -eq ($nPhases - 2)) {
    $h.Text = "Confirmar"; $h.FontSize = 16; $h.FontWeight = "Bold"
    $host_.Children.Add($h) | Out-Null
    $sel = Get-Selection
    $s = New-Object Windows.Controls.TextBlock
    $s.Text = "Servicios ($($sel.Services.Count)): " + ($sel.Services -join ', ') +
      "`nTweaks ($($sel.Tweaks.Count) valores): " + (($sel.Tweaks | ForEach-Object { $_.Name }) -join ', ')
    $s.Margin = "0,10,0,0"; $s.TextWrapping = "Wrap"
    $host_.Children.Add($s) | Out-Null
    $ap = New-Object Windows.Controls.Button
    $ap.Content = "Aplicar (pide 1 UAC)"; $ap.Width = 180; $ap.Margin = "0,10,0,0"
    $ap.Style = $w.FindResource("AccentButton")
    $ap.Add_Click({ Invoke-Apply })
    $host_.Children.Add($ap) | Out-Null
    $script:statusBox = New-Object Windows.Controls.TextBlock
    $script:statusBox.Margin = "0,8,0,0"; $script:statusBox.TextWrapping = "Wrap"
    $host_.Children.Add($script:statusBox) | Out-Null
  } elseif ($p -eq ($nPhases - 1)) {
    $h.Text = "Verificar"; $h.FontSize = 16; $h.FontWeight = "Bold"
    $host_.Children.Add($h) | Out-Null
    $v = New-Object Windows.Controls.TextBlock
    $ram1 = Get-Ram
    $v.Text = "Antes: $($script:ram0.Used) GB usados / Ahora: $($ram1.Used) GB usados.`nChecklist: scan Wi-Fi, Win+Shift+S, Win+V, Store. Si algo falla: Rollback-Debloat.ps1."
    $v.Margin = "0,10,0,0"; $v.TextWrapping = "Wrap"
    $host_.Children.Add($v) | Out-Null
  } else {
    $g = $groups[$p - 1]
    $h.Text = $g.Title; $h.FontSize = 16; $h.FontWeight = "Bold"
    $host_.Children.Add($h) | Out-Null
    foreach ($it in $g.Items) {
      $cb = New-Object Windows.Controls.CheckBox
      $cb.Content = $it.Label; $cb.ToolTip = $it.Tip; $cb.IsChecked = [bool]$it.On
      $cb.Tag = $it.Id
      $cb.Style = $w.FindResource("ToggleSwitch")
      $host_.Children.Add($cb) | Out-Null
      $checkBoxes[$it.Id] = $cb
    }
  }
}
function Get-Selection {
  $svcs = @(); $twks = @()
  foreach ($id in $checkBoxes.Keys) {
    if ($checkBoxes[$id].IsChecked) {
      if ($svcDefs.ContainsKey($id)) { $svcs += $svcDefs[$id] }
      if ($tweakDefs.ContainsKey($id)) { $twks += $tweakDefs[$id] }
    }
  }
  return @{ Services = $svcs; Tweaks = $twks }
}
function Invoke-Apply {
  $script:statusBox.Text = "Aplicando..."
  $sel = Get-Selection
  @{ Services = $sel.Services; Tweaks = $sel.Tweaks; CreateRestorePoint = $true } |
    ConvertTo-Json -Depth 5 | Set-Content "$env:TEMP\SafeDebloat-Selection.json" -Encoding UTF8
  Remove-Item "$env:TEMP\SafeDebloat-Done.txt" -ErrorAction SilentlyContinue
  & (Join-Path $PSScriptRoot "Safe-Debloat-Apply.ps1")
  if (Test-Path "$env:TEMP\SafeDebloat-Done.txt") { $script:statusBox.Text = "Aplicado. Rollback en Rollback-Debloat.ps1."; $script:applied = $true }
  else { $script:statusBox.Text = "Cancelado o falló (revisa SafeDebloat-Apply.log en TEMP)." }
}
function Save-State($p) {
  if ($p -ge 1 -and $p -le $groups.Count) {
    foreach ($it in $groups[$p - 1].Items) {
      if ($checkBoxes.ContainsKey($it.Id)) { $it.On = [bool]$checkBoxes[$it.Id].IsChecked }
    }
  }
}
function Show-Page($p) {
  Save-State $script:page
  $script:page = $p
  Render-Page $p
  for ($i = 0; $i -lt $nPhases; $i++) {
    $stepList.Children[$i].FontWeight = if ($i -eq $p) { "Bold" } else { "Normal" }
    $dots.Children[$i].Fill = if ($i -eq $p) {
      New-Object Windows.Media.SolidColorBrush([Windows.Media.Color]::FromRgb(0,120,212))
    } else {
      New-Object Windows.Media.SolidColorBrush([Windows.Media.Color]::FromRgb(200,200,200))
    }
  }
  $w.FindName("BBack").IsEnabled = ($p -gt 0)
  $w.FindName("BNext").Content = if ($p -eq ($nPhases - 1)) { "Cerrar" } else { "Next →" }
}
$w.FindName("BBack").Add_Click({ if ($script:page -gt 0) { Show-Page ($script:page - 1) } })
$w.FindName("BNext").Add_Click({ if ($script:page -eq ($nPhases - 1)) { $w.Close(); return }; Show-Page ($script:page + 1) })
Show-Page 0
[void]$w.ShowDialog()
