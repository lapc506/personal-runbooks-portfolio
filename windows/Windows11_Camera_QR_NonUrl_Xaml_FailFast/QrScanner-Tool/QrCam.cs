using System;
using System.IO;
using System.Linq;
using Windows.Foundation;
using Windows.Media.Capture;
using Windows.Media.MediaProperties;
using Windows.Storage.Streams;
using System.Drawing;
using ZXing;

public static class QrCam
{
    static void WaitDone(IAsyncInfo op)
    {
        int n = 0;
        while (op.Status == AsyncStatus.Started && n < 200) { System.Threading.Thread.Sleep(100); n++; }
        if (op.Status == AsyncStatus.Error) throw new Exception("WinRT async failed: " + op.ErrorCode);
        if (op.Status == AsyncStatus.Canceled) throw new Exception("WinRT async canceled");
        if (op.Status == AsyncStatus.Started) throw new Exception("WinRT async timeout");
    }

    public static string CaptureAndDecode()
    {
        var mc = new MediaCapture();
        WaitDone(mc.InitializeAsync(new MediaCaptureInitializationSettings
        {
            StreamingCaptureMode = StreamingCaptureMode.Video
        }));
        var stream = new InMemoryRandomAccessStream();
        WaitDone(mc.CapturePhotoToStreamAsync(ImageEncodingProperties.CreateJpeg(), stream));
        if (stream.Size == 0) throw new Exception("Captura vacia (0 bytes)");
        stream.Seek(0);
        var buf = new Windows.Storage.Streams.Buffer((uint)stream.Size);
        var rop = stream.ReadAsync(buf, (uint)stream.Size, InputStreamOptions.None);
        WaitDone(rop);
        rop.GetResults();
        byte[] bytes;
        using (var dr = DataReader.FromBuffer(buf)) { bytes = new byte[buf.Length]; dr.ReadBytes(bytes); }
        using (var ms = new MemoryStream(bytes))
        using (var bmp = (Bitmap)Image.FromStream(ms))
        {
            var reader = new BarcodeReader();
            var results = reader.DecodeMultiple(bmp);
            if (results == null) return null;
            return string.Join("\n", results.Select(r => "[" + r.BarcodeFormat + "] " + r.Text));
        }
    }
}
