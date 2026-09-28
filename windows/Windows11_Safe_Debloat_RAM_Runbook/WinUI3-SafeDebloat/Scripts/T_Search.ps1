# Path: T_Search.ps1
Set-ItemProperty 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\Explorer' DisableSearchBoxSuggestions 1
Set-ItemProperty 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' TurnOffWindowsCopilot 1
Set-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' ShowCopilotButton 0
