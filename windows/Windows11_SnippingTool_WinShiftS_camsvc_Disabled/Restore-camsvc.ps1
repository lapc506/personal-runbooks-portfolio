#Requires -RunAsAdministrator
# Restores camsvc (Capability Access Manager) to factory Manual + starts it.
Set-Service -Name camsvc -StartupType Manual
Start-Service -Name camsvc
Get-Service camsvc | Select-Object Name, Status, StartType
