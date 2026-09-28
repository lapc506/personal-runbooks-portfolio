# Path: A_Copilot.ps1
# Disable Windows Copilot and hide the button without deleting the app package.
New-Item -Path 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' -Force | Out-Null
Set-ItemProperty 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' TurnOffWindowsCopilot 1 -ErrorAction SilentlyContinue
Set-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' ShowCopilotButton 0 -ErrorAction SilentlyContinue
