# Pulls the last-24h crash records for WindowsCamera (and any app name passed in).
param([string]$App = "WindowsCamera", [int]$Hours = 24)
$since = (Get-Date).AddHours(-$Hours)
Get-WinEvent -LogName Application -MaxEvents 500 |
  Where-Object { $_.TimeCreated -gt $since -and ($_.Id -eq 1000 -or $_.Id -eq 1001) -and $_.Message -like "*$App*" } |
  ForEach-Object {
    $mod = if ($_.Message -match 'dulo con errores: (\S+)') { $Matches[1] } else { '?' }
    $code = if ($_.Message -match 'digo de excepci.n: (\S+)') { $Matches[1] } else { '?' }
    [pscustomobject]@{ Time = $_.TimeCreated; Event = $_.Id; Module = $mod; Code = $code }
  } | Format-Table -AutoSize
