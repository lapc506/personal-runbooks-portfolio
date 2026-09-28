# Path: S_Xbox.ps1
Set-Service XblAuthManager -StartupType Disabled
Set-Service XblGameSave -StartupType Disabled
Set-Service XboxGipSvc -StartupType Disabled
Set-Service XboxNetApiSvc -StartupType Disabled
