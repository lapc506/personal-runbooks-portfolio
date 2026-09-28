@echo off
set CSC=C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe
set MD=C:\Windows\System32\WinMetadata
set QRD=C:\Users\guara\QRDemo
"%CSC%" /nologo /t:library /out:"%QRD%\QrCam.dll" "%QRD%\QrCam.cs" ^
 /reference:"%MD%\Windows.Media.winmd" ^
 /reference:"%MD%\Windows.Foundation.winmd" ^
 /reference:"%MD%\Windows.Storage.winmd" ^
 /reference:System.Drawing.dll ^
 /reference:System.Runtime.dll ^
 /reference:System.Runtime.WindowsRuntime.dll ^
 /reference:"%QRD%\lib\zxing.dll"
echo CSC-EXIT:%ERRORLEVEL%
