# Path: S_Telemetry.ps1
Set-Service DiagTrack -StartupType Disabled
Set-Service dmwappushservice -StartupType Disabled
Set-Service RetailDemo -StartupType Disabled
Set-Service InventorySvc -StartupType Disabled
Set-Service nvagent -StartupType Disabled
Set-Service HpTouchpointAnalyticsService -StartupType Disabled
