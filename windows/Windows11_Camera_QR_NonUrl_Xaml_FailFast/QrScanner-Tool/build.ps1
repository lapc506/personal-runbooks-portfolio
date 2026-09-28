# build.ps1 - compila QrCam.cs -> QrCam.dll con el csc in-box (sin SDK)
$csc = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$md  = 'C:\Windows\System32\WinMetadata'
$qrd = $PSScriptRoot
$arguments = @(
  '/nologo', '/t:library', "/out:$qrd\QrCam.dll", "$qrd\QrCam.cs",
  "/reference:$md\Windows.Media.winmd",
  "/reference:$md\Windows.Foundation.winmd",
  "/reference:$md\Windows.Storage.winmd",
  "/reference:$md\Windows.Graphics.winmd",
  '/reference:System.Drawing.dll',
  '/reference:System.Runtime.dll',
  '/reference:System.Runtime.WindowsRuntime.dll',
  "/reference:$qrd\lib\zxing.dll"
)
& $csc $arguments
exit $LASTEXITCODE
