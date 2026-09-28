# Path: A_ClickToDo.ps1
# Disable Click to Do AI text/image analysis when available.
$policyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'
New-Item -Path $policyPath -Force | Out-Null
Set-ItemProperty $policyPath DisableClickToDo 1 -ErrorAction SilentlyContinue
