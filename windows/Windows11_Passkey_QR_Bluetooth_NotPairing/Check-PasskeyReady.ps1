#Requires -Version 5.1
# PC-side readiness check for cross-device passkey (caBLE/hybrid) QR flow.
# Run non-elevated. All green = PC is not the blocker; scan the QR FROM the phone.
Get-Service bthserv,BTAGService,BthAvctpSvc,DeviceAssociationService,Cdpsvc,RmSvc,NlaSvc,WlanSvc,Dhcp 2>&1 |
  Select-Object Name, Status, StartType | Format-Table -AutoSize
Get-Service BluetoothUserService* | Select-Object Name, Status, StartType | Format-Table -AutoSize
Get-PnpDevice -Class Bluetooth | Select-Object FriendlyName, Status, InstanceId | Format-Table -AutoSize
netsh wlan show interfaces | Select-String 'Estado|SSID|Se..al'
# Expected: BT services Running, Realtek BT + MS BTHLE/BTHBRB OK, Wi-Fi conectado con IPv4.
