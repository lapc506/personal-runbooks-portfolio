# Dumps every Disabled service plus its registry template Start value (3=Manual default, 4=Disabled override).
Get-CimInstance Win32_Service | Where-Object StartMode -eq 'Disabled' |
  ForEach-Object {
    $base = $_.Name -replace '_[a-f0-9]+$', ''
    $tpl = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$base" -ErrorAction SilentlyContinue).Start
    [pscustomobject]@{ Service = $_.Name; TemplateStart = $tpl }
  } | Sort-Object Service | Format-Table -AutoSize
