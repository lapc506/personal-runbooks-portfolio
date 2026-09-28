# Measure-RamBaseline.ps1 — idle RAM snapshot before/after debloat (same conditions both times: no apps open).
$os = Get-CimInstance Win32_OperatingSystem
$svchostMB = (Get-Process svchost -ErrorAction SilentlyContinue |
  Measure-Object WorkingSet64 -Sum).Sum / 1MB
[pscustomobject]@{
  Time            = Get-Date -Format 'yyyy-MM-dd HH:mm'
  TotalGB         = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
  FreeGB          = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
  UsedGB          = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1MB, 2)
  SvchostSumMB    = [math]::Round($svchostMB, 0)
} | Format-List
