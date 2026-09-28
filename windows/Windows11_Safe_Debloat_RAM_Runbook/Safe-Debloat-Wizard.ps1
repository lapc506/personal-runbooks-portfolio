# Safe-Debloat-Wizard.ps1 — NavigationView-style: rail + vistas por categoría (sin stepper).
# Cada tweak es una tarjeta estilo SettingsExpander (icono+título+descripción+switch) con
# su propio botón Aplicar + diálogo modal. PowerShell + WPF, sin SDK.
# La elevación ocurre solo en Safe-Debloat-Apply.ps1 (un UAC).
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne "STA") {
  powershell -STA -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @args; exit $LASTEXITCODE
}
Add-Type -AssemblyName PresentationFramework

$groups = @(
  @{ Title = 'Privacidad'; GlyphCode = 0xE72E; Items = @(
    @{ Id = 'T_Ads'; Label = 'Sin ID de publicidad ni experiencias a medida';
       Desc = 'Quita el ID de publicidad y las experiencias a medida de Windows.';
       Tip = 'AdvertisingInfo\Enabled=0 + TailoredExperiences=0.'; On = $true }) },
  @{ Title = 'Explorador'; GlyphCode = 0xE8B7; Items = @(
    @{ Id = 'T_Explorer'; Label = 'Extensiones visibles + ocultos + Este equipo';
       Desc = 'Muestra extensiones y archivos ocultos; abre en Este equipo.';
       Tip = 'HideFileExt=0, Hidden=1, LaunchTo=1.'; On = $true }) },
  @{ Title = 'Barra de tareas'; GlyphCode = 0xE7F4; Items = @(
    @{ Id = 'T_Taskbar'; Label = 'Izquierda, sin widgets ni Task View';
       Desc = 'Alineación clásica sin distracciones.';
       Tip = 'TaskbarAl=0, TaskbarDa=0, ShowTaskViewButton=0.'; On = $true }) },
  @{ Title = 'Búsqueda y Copilot'; GlyphCode = 0xE094; Items = @(
    @{ Id = 'T_Search'; Label = 'Sin Bing en buscar + sin Copilot';
       Desc = 'Búsqueda local solamente, sin asistente.';
       Tip = 'DisableSearchBoxSuggestions=1, TurnOffWindowsCopilot=1, ShowCopilotButton=0.'; On = $true }) },
  @{ Title = 'Servicios: telemetría'; GlyphCode = 0xE713; Items = @(
    @{ Id = 'S_Telemetry'; Label = 'Telemetría y vendor';
       Desc = 'DiagTrack, dmwappushservice, RetailDemo, InventorySvc, nvagent, HP.';
       Tip = 'Sin dependientes en Home.'; On = $true }) },
  @{ Title = 'Servicios: condicional'; GlyphCode = 0xE713; Items = @(
    @{ Id = 'S_Xbox'; Label = 'Xbox (4)'; Desc = 'Solo sin gaming.';
       Tip = 'XblAuthManager, XblGameSave, XboxGipSvc, XboxNetApiSvc.'; On = $false },
    @{ Id = 'S_Maps'; Label = 'Mapas y ubicación'; Desc = 'Solo si no los usas.';
       Tip = 'MapsBroker + lfsvc.'; On = $false },
    @{ Id = 'S_SysMain'; Label = 'SysMain'; Desc = 'Ahorra RAM (mide antes/después).';
       Tip = 'En HDD enlentece aperturas.'; On = $false },
    @{ Id = 'S_Misc'; Label = 'PcaSvc + TrkWks + lmhosts + DusmSvc'; Desc = 'Riesgo bajo.';
       Tip = 'Compatibilidad y red menor.'; On = $false }) }
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
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="Safe Debloat" Height="600" Width="920" Background="White" WindowStartupLocation="CenterScreen" FontFamily="Segoe UI Variable Text">
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
<Setter Property="Margin" Value="0"/>
<Setter Property="Template">
<Setter.Value>
<ControlTemplate TargetType="CheckBox">
<Border Name="track" Width="52" Height="28" CornerRadius="14" Background="#8A8A8A">
<Ellipse Name="thumb" Width="20" Height="20" Fill="White" HorizontalAlignment="Left" Margin="4,0,0,0"/>
</Border>
<ControlTemplate.Triggers>
<Trigger Property="IsChecked" Value="True">
<Setter TargetName="track" Property="Background" Value="#0078D4"/>
<Setter TargetName="thumb" Property="HorizontalAlignment" Value="Right"/>
<Setter TargetName="thumb" Property="Margin" Value="0,0,4,0"/>
</Trigger>
</ControlTemplate.Triggers>
</ControlTemplate>
</Setter.Value>
</Setter>
</Style>
<Style x:Key="NavButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
<Setter Property="Background" Value="Transparent"/>
<Setter Property="BorderThickness" Value="0"/>
<Setter Property="HorizontalContentAlignment" Value="Left"/>
<Setter Property="Margin" Value="8,2,8,2"/>
</Style>
</Window.Resources>
<Grid>
<Grid.ColumnDefinitions><ColumnDefinition x:Name="RailCol" Width="210"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
<StackPanel Name="RailPanel" Grid.Column="0" Background="#F3F3F3">
<TextBlock Name="RailTitle" Text="Safe Debloat" FontSize="18" FontWeight="Bold" Margin="16,16,0,4"/>
<StackPanel Name="NavRail" Margin="0,8,0,0"/>
<TextBlock Text="Protegidos: camsvc, RmSvc, DPS, iphlpsvc, red, CDPSvc, cbdhsvc. Nunca seleccionables." Name="ProtectNote" TextWrapping="Wrap" Margin="16,24,16,0" Foreground="#666666"/>
</StackPanel>
<ScrollViewer Grid.Column="1" Margin="20" VerticalScrollBarVisibility="Auto"><StackPanel Name="PageHost"/></ScrollViewer>
</Grid>
</Window>
"@
$w = [Windows.Markup.XamlReader]::Parse($xaml)
$rail = $w.FindName("NavRail"); $host_ = $w.FindName("PageHost")

$lightVal = (Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction SilentlyContinue).AppsUseLightTheme
if ($null -eq $lightVal) { $lightVal = 1 }
$script:T = if ($lightVal -ne 0) {
  @{ Win = 'White'; Rail = '#F3F3F3'; Fg = '#1B1B1B'; Muted = '#666666'; Sel = '#E5E5E5'; Hover = '#EAEAEA'; Card = '#F9F9F9' }
} else {
  @{ Win = '#202020'; Rail = '#2B2B2B'; Fg = 'White'; Muted = '#AAAAAA'; Sel = '#3A3A3A'; Hover = '#333333'; Card = '#2D2D2D' }
}
$w.Background = $script:T.Win; $w.Foreground = $script:T.Fg
$w.FindName("RailPanel").Background = $script:T.Rail
$w.FindName("RailTitle").Foreground = $script:T.Fg
$w.FindName("ProtectNote").Foreground = $script:T.Muted

$navPages = @('Overview', 'Procesos') + ($groups | ForEach-Object { $_.Title })
$navGlyphs = @([char]0xE9D2, [char]0xE8FD) + ($groups | ForEach-Object { [char]$_.GlyphCode })
$nPages = $navPages.Count
$checkBoxes = @{}
$script:page = 0
$script:ram0 = $null
$script:history = New-Object Collections.Generic.List[double]
$script:totalGB = 7.3

function Get-Ram {
  $os = Get-CimInstance Win32_OperatingSystem
  [pscustomobject]@{ Total = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    Used = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1MB, 2) }
}
function Add-Text($parent, $text, $size = 13, $bold = $false, $color = $null) {
  if (-not $color) { $color = $script:T.Fg }
  $t = New-Object Windows.Controls.TextBlock
  $t.Text = $text; $t.FontSize = $size; $t.TextWrapping = "Wrap"; $t.Margin = "0,4,0,4"
  if ($bold) { $t.FontWeight = "Bold" }
  $t.Foreground = New-Object Windows.Media.SolidColorBrush([Windows.Media.ColorConverter]::ConvertFromString($color))
  $parent.Children.Add($t) | Out-Null
  return $t
}
function Get-ProcRows {
  $pathByPid = @{}
  foreach ($wp in (Get-CimInstance Win32_Process)) {
    if ($wp.ProcessId -gt 0 -and $wp.ExecutablePath) { $pathByPid[[int]$wp.ProcessId] = $wp.ExecutablePath }
  }
  $svcByPid = @{}
  foreach ($s in (Get-CimInstance Win32_Service)) {
    if ($s.ProcessId -gt 0) {
      $k = [int]$s.ProcessId
      if (-not $svcByPid.ContainsKey($k)) { $svcByPid[$k] = @() }
      $svcByPid[$k] += $s
    }
  }
  foreach ($p in (Get-Process)) {
    $path = if ($pathByPid.ContainsKey($p.Id)) { $pathByPid[$p.Id] } else { "" }
    $core = ($path -like 'C:\Windows\*')
    $svcs = @()
    if ($svcByPid.ContainsKey($p.Id)) { $svcs = $svcByPid[$p.Id] }
    [pscustomobject]@{
      Proceso   = $p.ProcessName
      PID       = $p.Id
      RAM_MB    = [math]::Round($p.WorkingSet64 / 1MB)
      Nuclear   = if ($core) { 'Si' } else { 'no' }
      Servicios = (($svcs | ForEach-Object { $_.DisplayName }) -join '; ')
      Autostart = (($svcs | ForEach-Object { $_.StartMode }) | Select-Object -Unique) -join ','
    }
  }
}
function New-Card($item) {
  $card = New-Object Windows.Controls.Border
  $card.CornerRadius = 6; $card.Background = $script:T.Card
  $card.Padding = "12,10,12,10"; $card.Margin = "0,0,0,8"
  $grid = New-Object Windows.Controls.Grid
  $grid.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition)) | Out-Null
  $auto = New-Object Windows.Controls.ColumnDefinition
  $auto.Width = "Auto"; $grid.ColumnDefinitions.Add($auto) | Out-Null
  $left = New-Object Windows.Controls.StackPanel
  $left.SetValue([Windows.Controls.Grid]::ColumnProperty, 0)
  $title = New-Object Windows.Controls.TextBlock
  $title.Text = $item.Label; $title.FontWeight = "SemiBold"; $title.Foreground = $script:T.Fg
  $left.Children.Add($title) | Out-Null
  $desc = New-Object Windows.Controls.TextBlock
  $desc.Text = $item.Desc; $desc.Foreground = $script:T.Muted; $desc.TextWrapping = "Wrap"
  $left.Children.Add($desc) | Out-Null
  $detail = New-Object Windows.Controls.TextBlock
  if ($svcDefs.ContainsKey($item.Id)) { $detail.Text = "Servicios: " + ($svcDefs[$item.Id] -join ', ') }
  else { $detail.Text = "Valores: " + (($tweakDefs[$item.Id] | ForEach-Object { $_.Name }) -join ', ') + "`n" + $item.Tip }
  $detail.Foreground = $script:T.Muted; $detail.TextWrapping = "Wrap"
  $detail.Margin = "0,6,0,0"; $detail.Visibility = "Collapsed"
  $left.Children.Add($detail) | Out-Null
  $grid.Children.Add($left) | Out-Null
  $cb = New-Object Windows.Controls.CheckBox
  $cb.IsChecked = [bool]$item.On; $cb.Tag = $item.Id
  $cb.Style = $w.FindResource("ToggleSwitch")
  $cb.ToolTip = $item.Tip
  $cb.SetValue([Windows.Controls.Grid]::ColumnProperty, 1)
  $cb.VerticalAlignment = "Center"
  $grid.Children.Add($cb) | Out-Null
  $checkBoxes[$item.Id] = $cb
  $left.Add_MouseLeftButtonUp({ $detail.Visibility = if ($detail.Visibility -eq "Collapsed") { "Visible" } else { "Collapsed" } })
  $left.Cursor = "Hand"
  $card.Child = $grid
  return $card
}
function Render-Page($p) {
  $host_.Children.Clear()
  if ($p -eq 0) {
    Add-Text $host_ "Bienvenido" 24 $true
    Add-Text $host_ "Vamos a reducir tu consumo de RAM. Primero medimos tu punto de partida." 13 $false $script:T.Muted
    if (-not $script:ram0) { $script:ram0 = Get-Ram; $script:totalGB = $script:ram0.Total }
    $pct = [math]::Round($script:ram0.Used / $script:totalGB * 100)
    Add-Text $host_ ("Memoria: {0}/{1} GB ({2}%)" -f $script:ram0.Used, $script:totalGB, $pct) 18 $true
    $pb = New-Object Windows.Controls.ProgressBar
    $pb.Minimum = 0; $pb.Maximum = 100; $pb.Value = $pct; $pb.Height = 18; $pb.Margin = "0,4,0,8"
    $host_.Children.Add($pb) | Out-Null
    Add-Text $host_ "Ultimos 60 s (en vivo):" 13 $true
    $cv = New-Object Windows.Controls.Canvas
    $cv.Height = 120; $cv.Background = "#11111B"
    for ($gi = 1; $gi -lt 8; $gi++) {
      $gl = New-Object Windows.Shapes.Line
      $gl.X1 = $gi / 8 * 560; $gl.X2 = $gi / 8 * 560; $gl.Y1 = 0; $gl.Y2 = 118
      $gl.Stroke = "#2A2A2A"; $gl.StrokeThickness = 1
      $cv.Children.Add($gl) | Out-Null
    }
    for ($gj = 1; $gj -lt 4; $gj++) {
      $gl2 = New-Object Windows.Shapes.Line
      $gl2.X1 = 0; $gl2.X2 = 560; $gl2.Y1 = $gj / 4 * 118; $gl2.Y2 = $gj / 4 * 118
      $gl2.Stroke = "#2A2A2A"; $gl2.StrokeThickness = 1
      $cv.Children.Add($gl2) | Out-Null
    }
    $script:chartFill = New-Object Windows.Shapes.Polygon
    $script:chartFill.Fill = New-Object Windows.Media.SolidColorBrush([Windows.Media.Color]::FromArgb(70, 0, 120, 212))
    $cv.Children.Add($script:chartFill) | Out-Null
    $script:chartLine = New-Object Windows.Shapes.Polyline
    $script:chartLine.Stroke = "#0078D4"; $script:chartLine.StrokeThickness = 2
    $cv.Children.Add($script:chartLine) | Out-Null
    $host_.Children.Add($cv) | Out-Null
    Add-Text $host_ "60 segundos" 11 $false $script:T.Muted
    $tl = New-Object Windows.Controls.Grid
    $tl.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition)) | Out-Null
    $tl.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition)) | Out-Null
    $t60 = New-Object Windows.Controls.TextBlock; $t60.Text = "60 s"
    $t60.Foreground = $script:T.Muted
    $t60.SetValue([Windows.Controls.Grid]::ColumnProperty, 0)
    $tl.Children.Add($t60) | Out-Null
    $t0 = New-Object Windows.Controls.TextBlock; $t0.Text = "ahora"
    $t0.Foreground = $script:T.Muted; $t0.HorizontalAlignment = "Right"
    $t0.SetValue([Windows.Controls.Grid]::ColumnProperty, 1)
    $tl.Children.Add($t0) | Out-Null
    $host_.Children.Add($tl) | Out-Null
    $script:chartCanvas = $cv
    Update-Chart
  } elseif ($p -eq 1) {
    Add-Text $host_ "Procesos (completo)" 16 $true
    Add-Text $host_ "Nuclear = binario bajo C:\Windows (heuristica por ruta). Autostart = StartMode de sus servicios (vacio = app, no servicio). Click en cabecera para ordenar." 12 $false $script:T.Muted
    $dg = New-Object Windows.Controls.DataGrid
    $dg.AutoGenerateColumns = $false; $dg.IsReadOnly = $true; $dg.Height = 380
    $dg.GridLinesVisibility = "Horizontal"
    $dg.RowHeaderWidth = 0
    if ($script:T.Win -ne 'White') {
      $dg.Background = $script:T.Win; $dg.Foreground = $script:T.Fg
      $dg.RowBackground = $script:T.Rail; $dg.AlternatingRowBackground = "#262626"
    } else {
      $dg.AlternatingRowBackground = "#F9F9F9"
    }
    $rowStyle = New-Object Windows.Style([Windows.Controls.DataGridRow])
    $trig = New-Object Windows.Trigger
    $trig.Property = [Windows.Controls.DataGridRow]::IsMouseOverProperty
    $trig.Value = $true
    $trig.Setters.Add((New-Object Windows.Setter([Windows.Controls.DataGridRow]::BackgroundProperty, $script:T.Hover)))
    $rowStyle.Triggers.Add($trig) | Out-Null
    $dg.RowStyle = $rowStyle
    $headStyle = New-Object Windows.Style([Windows.Controls.DataGridColumnHeader])
    $headStyle.Setters.Add((New-Object Windows.Setter([Windows.Controls.Control]::FontWeightProperty, "Bold")))
    $dg.ColumnHeaderStyle = $headStyle
    foreach ($c in @(@{H='Proceso';B='Proceso'},@{H='PID';B='PID'},@{H='RAM MB';B='RAM_MB'},
                     @{H='Nuclear';B='Nuclear'},@{H='Servicios';B='Servicios'},@{H='Autostart';B='Autostart'})) {
      $col = New-Object Windows.Controls.DataGridTextColumn
      $col.Header = $c.H; $col.Binding = New-Object Windows.Data.Binding($c.B)
      $dg.Columns.Add($col) | Out-Null
    }
    $dg.ItemsSource = @(Get-ProcRows | Sort-Object RAM_MB -Descending)
    $host_.Children.Add($dg) | Out-Null
  } else {
    $g = $groups[$p - 2]
    Add-Text $host_ $g.Title 16 $true
    foreach ($it in $g.Items) { $host_.Children.Add((New-Card $it)) | Out-Null }
    $ap1 = New-Object Windows.Controls.Button
    $ap1.Content = "Aplicar $($g.Title)"; $ap1.Width = 220; $ap1.Margin = "0,4,0,0"
    $ap1.Style = $w.FindResource("AccentButton")
    $ap1.Tag = ($p - 2)
    $ap1.Add_Click({ Ask-Confirm ([int]$this.Tag) })
    $host_.Children.Add($ap1) | Out-Null
    $script:statusBox = Add-Text $host_ "" 13
  }
}
function Get-Selection($scope = -1) {
  $svcs = @(); $twks = @()
  $ids = if ($scope -ge 0) { $groups[$scope].Items | ForEach-Object { $_.Id } } else { $checkBoxes.Keys }
  foreach ($id in $ids) {
    if ($checkBoxes.ContainsKey($id) -and $checkBoxes[$id].IsChecked) {
      if ($svcDefs.ContainsKey($id)) { $svcs += $svcDefs[$id] }
      if ($tweakDefs.ContainsKey($id)) { $twks += $tweakDefs[$id] }
    }
  }
  return @{ Services = $svcs; Tweaks = $twks }
}
function Ask-Confirm($scope = -1) {
  $sel = Get-Selection $scope
  $d = New-Object Windows.Window
  $d.Title = "Confirmar cambios"; $d.Width = 460; $d.Height = 300
  $d.WindowStartupLocation = "CenterOwner"; $d.Owner = $w
  $d.FontFamily = "Segoe UI Variable Text"; $d.Background = $script:T.Win; $d.Foreground = $script:T.Fg
  $sp = New-Object Windows.Controls.StackPanel; $sp.Margin = 20
  $t = New-Object Windows.Controls.TextBlock
  $t.Text = "Se desactivaran $($sel.Services.Count) servicios y se cambiaran $($sel.Tweaks.Count) valores de registro. Se crea restore point y Rollback-Debloat.ps1 antes de aplicar. Continuar?"
  $t.Foreground = $script:T.Fg
  $t.TextWrapping = "Wrap"; $t.Margin = "0,0,0,16"
  $sp.Children.Add($t) | Out-Null
  $cbCloud = New-Object Windows.Controls.CheckBox
  $cbCloud.Content = "Subir un respaldo a la nube."; $cbCloud.Margin = "0,0,0,16"; $cbCloud.Foreground = $script:T.Fg
  $sp.Children.Add($cbCloud) | Out-Null
  $row = New-Object Windows.Controls.StackPanel
  $row.Orientation = "Horizontal"; $row.HorizontalAlignment = "Right"
  $ok = New-Object Windows.Controls.Button; $ok.Content = "Aplicar"; $ok.Width = 100; $ok.Margin = "0,0,8,0"
  $ok.Style = $w.FindResource("AccentButton")
  $no = New-Object Windows.Controls.Button; $no.Content = "Cancelar"; $no.Width = 100
  $ok.Add_Click({ $d.DialogResult = $true; $d.Close() })
  $no.Add_Click({ $d.DialogResult = $false; $d.Close() })
  $row.Children.Add($ok) | Out-Null; $row.Children.Add($no) | Out-Null
  $sp.Children.Add($row) | Out-Null
  $d.Content = $sp
  if ($d.ShowDialog() -eq $true) { Invoke-Apply $scope }
}
function Invoke-Apply($scope = -1) {
  $script:statusBox.Text = "Aplicando..."
  $sel = Get-Selection $scope
  @{ Services = $sel.Services; Tweaks = $sel.Tweaks; CreateRestorePoint = $true } |
    ConvertTo-Json -Depth 5 | Set-Content "$env:TEMP\SafeDebloat-Selection.json" -Encoding UTF8
  Remove-Item "$env:TEMP\SafeDebloat-Done.txt" -ErrorAction SilentlyContinue
  & (Join-Path $PSScriptRoot "Safe-Debloat-Apply.ps1")
  if (Test-Path "$env:TEMP\SafeDebloat-Done.txt") {
    $ram1 = Get-Ram
    $script:statusBox.Text = "Aplicado. RAM: $($script:ram0.Used) -> $($ram1.Used) GB. Rollback en Rollback-Debloat.ps1."
  }
  else { $script:statusBox.Text = "Cancelado o fallo (revisa SafeDebloat-Apply.log en TEMP)." }
}
function Update-Chart {
  $r = Get-Ram
  $script:history.Add($r.Used)
  while ($script:history.Count -gt 60) { $script:history.RemoveAt(0) }
  if ($script:page -ne 0 -or -not $script:chartLine) { return }
  $pts = New-Object Windows.Media.PointCollection
  $W = 560; $H = 118
  for ($i = 0; $i -lt $script:history.Count; $i++) {
    $x = $i / 59 * $W
    $y = $H - ($script:history[$i] / $script:totalGB * $H)
    $pts.Add((New-Object Windows.Point($x, $y))) | Out-Null
  }
  $script:chartLine.Points = $pts
  $fp = New-Object Windows.Media.PointCollection
  foreach ($pt in $pts) { $fp.Add($pt) | Out-Null }
  if ($pts.Count -gt 0) {
    $fp.Add((New-Object Windows.Point($pts[$pts.Count - 1].X, 118))) | Out-Null
    $fp.Add((New-Object Windows.Point($pts[0].X, 118))) | Out-Null
  }
  $script:chartFill.Points = $fp
}
$script:sampler = New-Object Windows.Threading.DispatcherTimer
$script:sampler.Interval = [TimeSpan]::FromSeconds(1)
$script:sampler.Add_Tick({ Update-Chart })
$script:sampler.Start()
$script:navBtns = @()
$script:navLabels = @()
$script:paneManual = $false
$script:expanded = $true
function Set-Pane($expand) {
  $script:expanded = $expand
  $w.FindName("RailCol").Width = if ($expand) { 210 } else { 64 }
  foreach ($lb in $script:navLabels) { $lb.Visibility = if ($expand) { "Visible" } else { "Collapsed" } }
  $w.FindName("RailTitle").Visibility = if ($expand) { "Visible" } else { "Collapsed" }
  $w.FindName("ProtectNote").Visibility = if ($expand) { "Visible" } else { "Collapsed" }
}
$ham = New-Object Windows.Controls.Button
$ham.Width = 40; $ham.Margin = "16,0,0,8"; $ham.ToolTip = "Colapsar panel"
$hamGlyph = New-Object Windows.Controls.TextBlock
$hamGlyph.Text = [char]0xE700; $hamGlyph.FontFamily = "Segoe MDL2 Assets"; $hamGlyph.FontSize = 16
$hamGlyph.Foreground = $script:T.Fg
$ham.Content = $hamGlyph
$ham.Add_Click({
  $script:paneManual = $true
  Set-Pane (-not $script:expanded)
})
$rail.Children.Insert(0, $ham) | Out-Null
$w.Add_SizeChanged({
  if (-not $script:paneManual) { Set-Pane ($w.ActualWidth -ge 760) }
})
for ($i = 0; $i -lt $nPages; $i++) {
  $b = New-Object Windows.Controls.Button
  $b.Style = $w.FindResource("NavButton")
  $sp = New-Object Windows.Controls.StackPanel; $sp.Orientation = "Horizontal"
  $ic = New-Object Windows.Controls.TextBlock
  $ic.Text = $navGlyphs[$i]; $ic.FontFamily = "Segoe MDL2 Assets"; $ic.FontSize = 16
  $ic.Width = 28; $ic.VerticalAlignment = "Center"; $ic.Foreground = $script:T.Fg
  $tx = New-Object Windows.Controls.TextBlock
  $tx.Text = $navPages[$i]; $tx.VerticalAlignment = "Center"; $tx.Foreground = $script:T.Fg
  $sp.Children.Add($ic) | Out-Null; $sp.Children.Add($tx) | Out-Null
  $b.Content = $sp; $b.Tag = $i
  $b.Add_Click({ Show-Page ([int]$this.Tag) })
  $b.Add_MouseEnter({ if ($script:page -ne [int]$this.Tag) { $this.Background = $script:T.Hover } })
  $b.Add_MouseLeave({ if ($script:page -ne [int]$this.Tag) { $this.Background = "Transparent" } })
  $rail.Children.Add($b) | Out-Null
  $script:navBtns += $b
  $script:navLabels += $tx
}
function Save-State($p) {
  $gi = $p - 2
  if ($gi -ge 0 -and $gi -lt $groups.Count) {
    foreach ($it in $groups[$gi].Items) {
      if ($checkBoxes.ContainsKey($it.Id)) { $it.On = [bool]$checkBoxes[$it.Id].IsChecked }
    }
  }
}
function Show-Page($p) {
  Save-State $script:page
  $script:page = $p
  Render-Page $p
  for ($i = 0; $i -lt $nPages; $i++) {
    $script:navBtns[$i].FontWeight = if ($i -eq $p) { "Bold" } else { "Normal" }
    $script:navBtns[$i].Background = if ($i -eq $p) { $script:T.Sel } else { "Transparent" }
  }
}
$w.Add_Closed({ $script:sampler.Stop() })
Show-Page 0
[void]$w.ShowDialog()
