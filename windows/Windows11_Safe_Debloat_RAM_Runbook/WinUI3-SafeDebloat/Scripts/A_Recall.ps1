# Path: A_Recall.ps1
# Disable Recall-related policy if present in the current Windows build.
# This is intentionally conservative and reversible.
$policyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'
New-Item -Path $policyPath -Force | Out-Null
Set-ItemProperty $policyPath DisableRecall 1 -ErrorAction SilentlyContinue
