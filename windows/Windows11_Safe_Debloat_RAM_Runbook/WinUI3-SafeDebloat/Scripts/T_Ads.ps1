# Path: T_Ads.ps1
Set-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo' Enabled 0
Set-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Privacy' TailoredExperiencesWithDiagnosticDataEnabled 0
