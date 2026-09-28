# Safe-Debloat-Wizard.ps1 — NavigationView-style (rail + páginas): Overview con chart,
# grid completo de procesos, categorías con toggles y diálogo modal de confirmación.
# PowerShell + WPF, sin SDK. La elevación ocurre solo en Safe-Debloat-Apply.ps1 (un UAC).
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne "STA") {
  powershell -STA -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @args; exit $LASTEXITCODE
}
Add-Type -AssemblyName PresentationFramework

$groups = @(
  @{ Title = 'Privacidad'; Items = @(
    @{ Id = 'T_Ads'; Label = 'Sin ID de publicidad ni experiencias a medida';
       Tip = 'AdvertisingInfo\Enabled=0 + TailoredExperiences=0.'; On = $true }) },
  @{ Title = 'Explorador'; Items = @(
    @{ Id = 'T_Explorer'; Label = 'Extensiones visibles + ocultos + Este equipo';
       Tip = 'HideFileExt=0, Hidden=1, LaunchTo=1.'; On = $true }) },
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
    @{ Id = 'S_Xbox'; Label = 'Xbox (4) — solo sin gaming'; Tip = 'Game Bar y juegos los necesitan.'; On = $false },
    @{ Id = 'S_Maps'; Label = 'Mapas y ubicación — solo si no los usas'; Tip = 'MapsBroker + lfsvc.'; On = $false },
    @{ Id = 'S_SysMain'; Label = 'SysMain — ahorra RAM (mide antes/después)'; Tip = 'En HDD enlentece aperturas.'; On = $false },
    @{ Id = 'S_Misc'; Label = 'PcaSvc + TrkWks + lmhosts + DusmSvc'; Tip = 'Riesgo bajo.'; On = $false }) }
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
# Glifos Segoe MDL2 Assets por código (a prueba de encoding).
$navGlyphs = @([char]0xE9D2, [char]0xE8FD, [char]0xE72E, [char]0xE8B7,
               [char]0xE7F4, [char]0xE094, [char]0xE713, [char]0xE73E, [char]0xE8FB)

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
<Grid Grid.Column="1" Margin="20">
<Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
<ScrollViewer Grid.Row="0" VerticalScrollBarVisibility="Auto"><StackPanel Name="PageHost"/></ScrollViewer>
<StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,12,0,0">
<Button Name="BBack" Content="Back" Width="90"/>
<TextBlock Name="StepLabel" VerticalAlignment="Center" Margin="20,0,20,0" Foreground="#666666"/>
<Button Name="BNext" Content="Next" Width="90" Style="{StaticResource AccentButton}"/>
</StackPanel>
</Grid>
</Grid>
</Window>
"@
$w = [Windows.Markup.XamlReader]::Parse($xaml)
$rail = $w.FindName("NavRail"); $host_ = $w.FindName("PageHost")

# Tema desde el OS (AppsUseLightTheme). Sin toolchain WinUI: paleta manual.
$lightVal = (Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction SilentlyContinue).AppsUseLightTheme
if ($null -eq $lightVal) { $lightVal = 1 }
$script:T = if ($lightVal -ne 0) {
  @{ Win = 'White'; Rail = '#F3F3F3'; Fg = '#1B1B1B'; Muted = '#666666'; Sel = '#E5E5E5'; Hover = '#EAEAEA'; Box = '#11111B' }
} else {
  @{ Win = '#202020'; Rail = '#2B2B2B'; Fg = 'White'; Muted = '#AAAAAA'; Sel = '#3A3A3A'; Hover = '#333333'; Box = '#11111B' }
}
$w.Background = $script:T.Win; $w.Foreground = $script:T.Fg
$w.FindName("RailPanel").Background = $script:T.Rail
$w.FindName("RailTitle").Foreground = $script:T.Fg
$w.FindName("ProtectNote").Foreground = $script:T.Muted
$w.FindName("StepLabel").Foreground = $script:T.Muted
$navPages = @('Overview', 'Procesos') + ($groups | ForEach-Object { $_.Title }) + @('Confirmar', 'Verificar')
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
    $script:chartCanvas = $cv
    Update-Chart
  } elseif ($p -eq 1) {
    Add-Text $host_ "Procesos (completo)" 16 $true
    Add-Text $host_ "Nuclear = binario bajo C:\Windows (heuristica por ruta). Autostart = StartMode de sus servicios (vacio = app, no servicio). Click en cabecera para ordenar." 12 $false $script:T.Muted
    $dg = New-Object Windows.Controls.DataGrid
    $dg.AutoGenerateColumns = $false; $dg.IsReadOnly = $true; $dg.Height = 380
    if ($script:T.Win -ne 'White') {
      $dg.Background = $script:T.Win; $dg.Foreground = $script:T.Fg
      $dg.RowBackground = $script:T.Rail
    }
    foreach ($c in @(@{H='Proceso';B='Proceso'},@{H='PID';B='PID'},@{H='RAM MB';B='RAM_MB'},
                     @{H='Nuclear';B='Nuclear'},@{H='Servicios';B='Servicios'},@{H='Autostart';B='Autostart'})) {
      $col = New-Object Windows.Controls.DataGridTextColumn
      $col.Header = $c.H; $col.Binding = New-Object Windows.Data.Binding($c.B)
      $dg.Columns.Add($col) | Out-Null
    }
    $dg.ItemsSource = @(Get-ProcRows | Sort-Object RAM_MB -Descending)
    $host_.Children.Add($dg) | Out-Null
  } elseif ($p -eq ($nPages - 2)) {
    Add-Text $host_ "Confirmar" 16 $true
    $sel = Get-Selection
    Add-Text $host_ ("Servicios ({0}): {1}" -f $sel.Services.Count, ($sel.Services -join ', '))
    Add-Text $host_ ("Tweaks ({0} valores): {1}" -f $sel.Tweaks.Count, (($sel.Tweaks | ForEach-Object { $_.Name }) -join ', '))
    $ap = New-Object Windows.Controls.Button
    $ap.Content = "Aplicar (pide 1 UAC)"; $ap.Width = 180; $ap.Margin = "0,10,0,0"
    $ap.Style = $w.FindResource("AccentButton")
    $ap.Add_Click({ Ask-Confirm })
    $host_.Children.Add($ap) | Out-Null
    $script:statusBox = Add-Text $host_ "" 13
  } elseif ($p -eq ($nPages - 1)) {
    Add-Text $host_ "Verificar" 16 $true
    $ram1 = Get-Ram
    Add-Text $host_ ("Antes: {0} GB usados / Ahora: {1} GB usados. Ahorro: {2} GB." -f $script:ram0.Used, $ram1.Used, [math]::Round($script:ram0.Used - $ram1.Used, 2))
    Add-Text $host_ "Checklist: scan Wi-Fi, Win+Shift+S, Win+V, Store. Si algo falla: Rollback-Debloat.ps1."
  } else {
    $g = $groups[$p - 2]
    Add-Text $host_ $g.Title 16 $true
    foreach ($it in $g.Items) {
      $cb = New-Object Windows.Controls.CheckBox
      $cb.Content = $it.Label; $cb.ToolTip = $it.Tip; $cb.IsChecked = [bool]$it.On
      $cb.Tag = $it.Id
      $cb.Style = $w.FindResource("ToggleSwitch")
      $cb.Foreground = $script:T.Fg
      $host_.Children.Add($cb) | Out-Null
      $checkBoxes[$it.Id] = $cb
    }
    $gi = $p - 2
    $ap1 = New-Object Windows.Controls.Button
    $ap1.Content = "Aplicar $($g.Title)"; $ap1.Width = 220; $ap1.Margin = "0,12,0,0"
    $ap1.Style = $w.FindResource("AccentButton")
    $ap1.Tag = $gi
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
  $d.FontFamily = "Segoe UI Variable Text"; $d.Background = "White"
  $sp = New-Object Windows.Controls.StackPanel; $sp.Margin = 20
  $t = New-Object Windows.Controls.TextBlock
  $t.Text = "Se desactivaran $($sel.Services.Count) servicios y se cambiaran $($sel.Tweaks.Count) valores de registro. Se crea restore point y Rollback-Debloat.ps1 antes de aplicar. Continuar?"
  $t.TextWrapping = "Wrap"; $t.Margin = "0,0,0,16"
  $sp.Children.Add($t) | Out-Null
  $cbCloud = New-Object Windows.Controls.CheckBox
  $cbCloud.Content = "Subir un respaldo a la nube."; $cbCloud.Margin = "0,0,0,16"
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
  if (Test-Path "$env:TEMP\SafeDebloat-Done.txt") { $script:statusBox.Text = "Aplicado. Rollback en Rollback-Debloat.ps1." }
  else { $script:statusBox.Text = "Cancelado o fallo (revisa SafeDebloat-Apply.log en TEMP)." }
}
function Update-Chart {
  if ($script:page -ne 0) { return }
  $r = Get-Ram
  $script:history.Add($r.Used)
  while ($script:history.Count -gt 60) { $script:history.RemoveAt(0) }
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
  $w.FindName("BBack").IsEnabled = ($p -gt 0)
  $w.FindName("BNext").Content = if ($p -eq ($nPages - 1)) { "Cerrar" } else { "Next" }
  $w.FindName("StepLabel").Text = "Paso $($p + 1) de $nPages — $($navPages[$p])"
}
$w.FindName("BBack").Add_Click({ if ($script:page -gt 0) { Show-Page ($script:page - 1) } })
$w.FindName("BNext").Add_Click({ if ($script:page -eq ($nPages - 1)) { $w.Close(); return }; Show-Page ($script:page + 1) })
$w.Add_Closed({ $script:sampler.Stop() })
Show-Page 0
[void]$w.ShowDialog()
