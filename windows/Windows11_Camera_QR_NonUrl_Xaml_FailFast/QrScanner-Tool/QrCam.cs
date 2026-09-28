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
    static MediaCapture _mc;

    static void WaitDone(IAsyncInfo op)
    {
        int n = 0;
        while (op.Status == AsyncStatus.Started && n < 200) { System.Threading.Thread.Sleep(100); n++; }
        if (op.Status == AsyncStatus.Error) throw new Exception("WinRT async failed: " + op.ErrorCode);
        if (op.Status == AsyncStatus.Canceled) throw new Exception("WinRT async canceled");
        if (op.Status == AsyncStatus.Started) throw new Exception("WinRT async timeout");
    }

    static void EnsureInit()
    {
        if (_mc != null) return;
        var mc = new MediaCapture();
        WaitDone(mc.InitializeAsync(new MediaCaptureInitializationSettings
        {
            StreamingCaptureMode = StreamingCaptureMode.Video
        }));
        _mc = mc;
    }

    static byte[] TakePhotoBytes()
    {
        EnsureInit();
        var stream = new InMemoryRandomAccessStream();
        try
        {
            WaitDone(_mc.CapturePhotoToStreamAsync(ImageEncodingProperties.CreateJpeg(), stream));
            if (stream.Size == 0) throw new Exception("Captura vacia (0 bytes)");
            stream.Seek(0);
            var buf = new Windows.Storage.Streams.Buffer((uint)stream.Size);
            var rop = stream.ReadAsync(buf, (uint)stream.Size, InputStreamOptions.None);
            WaitDone(rop);
            rop.GetResults();
            byte[] bytes;
            using (var dr = DataReader.FromBuffer(buf)) { bytes = new byte[buf.Length]; dr.ReadBytes(bytes); }
            return bytes;
        }
        finally { stream.Dispose(); }
    }

    static string DecodeBytes(byte[] bytes)
    {
        using (var ms = new MemoryStream(bytes))
        using (var bmp = (Bitmap)Image.FromStream(ms))
        {
            var reader = new BarcodeReader();
            var results = reader.DecodeMultiple(bmp);
            if (results == null) return null;
            return string.Join("\n", results.Select(r => "[" + r.BarcodeFormat + "] " + r.Text));
        }
    }

    public static string CaptureAndDecode()
    {
        return DecodeBytes(TakePhotoBytes());
    }

    // "Preview": una foto fija por llamada (~1 fps). Sin preview stream (requiere sink UI).
    public static void StartPreview() { EnsureInit(); }

    public static byte[] GrabFrame(int w, int h) { return TakePhotoBytes(); }

    public static void StopPreview()
    {
        if (_mc != null) { _mc.Dispose(); _mc = null; }
    }
}
