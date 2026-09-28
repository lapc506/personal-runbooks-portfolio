#Requires -RunAsAdministrator
# Scans and connects to the known profile. Run AFTER Restore-WiFiServices.ps1.
# NOTE: profile name has a space: "Akinson 5 G" (not "Akinson 5G").
param([string]$Name = 'Akinson 5 G')

netsh wlan show networks mode=bssid
netsh wlan connect name="$Name"
Start-Sleep 7
netsh wlan show interfaces
ipconfig | Select-String -Pattern 'Wi-Fi|IPv4|Puerta'
