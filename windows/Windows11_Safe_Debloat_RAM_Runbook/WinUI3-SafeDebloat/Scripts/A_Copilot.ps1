# Path: A_Copilot.ps1
# Disable Windows Copilot, hide its button, and remove the app package.
# Run this script from an elevated (Administrator) PowerShell session.
New-Item -Path 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' -Force | Out-Null
Set-ItemProperty 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' TurnOffWindowsCopilot 1 -ErrorAction SilentlyContinue
Set-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' ShowCopilotButton 0 -ErrorAction SilentlyContinue

# Remove the Copilot app package for the current user, if it is installed.
Get-AppxPackage -Name '*Copilot*' -ErrorAction SilentlyContinue |
    ForEach-Object {
        Remove-AppxPackage -Package $_.PackageFullName -ErrorAction SilentlyContinue
    }

# Remove the provisioned Copilot package so it is not installed for new users (requires elevation).
try {
    Get-AppxProvisionedPackage -Online -ErrorAction Stop |
        Where-Object { $_.DisplayName -like '*Copilot*' } |
        ForEach-Object {
            Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue
        }
} catch {
    Write-Warning "Could not remove the provisioned Copilot package (run elevated). $($_.Exception.Message)"
}
