# Re-registers Snipping Tool for the current user and clears its (possibly corrupt) settings.
# Run AFTER camsvc is Running (see Restore-camsvc.ps1, needs one UAC accept).
Get-Process -Name SnippingTool -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep 1
$pkg = Get-AppxPackage -Name Microsoft.ScreenSketch
Add-AppxPackage -DisableDevelopmentMode -Register "$($pkg.InstallLocation)\AppXManifest.xml"
Remove-Item "$env:LOCALAPPDATA\Packages\Microsoft.ScreenSketch_8wekyb3d8bbwe\Settings\settings.dat" -Force -ErrorAction SilentlyContinue
Get-AppxPackage -Name Microsoft.ScreenSketch | Select-Object Name, Version, Status
