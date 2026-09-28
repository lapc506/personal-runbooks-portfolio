using System;
using System.IO;
using Microsoft.UI.Xaml;

namespace SafeDebloat;

public partial class App : Application
{
    public static Window? MainWindow { get; private set; }
    public static bool DebugModeEnabled { get; private set; }

    private static string LogPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "SafeDebloat",
        "debug.log");

    public App()
    {
        var raw = Environment.GetEnvironmentVariable("debugMode");
        DebugModeEnabled = string.Equals(raw, "on", StringComparison.OrdinalIgnoreCase)
            || Array.Exists(Environment.GetCommandLineArgs(), arg =>
                arg.StartsWith("debugMode=", StringComparison.OrdinalIgnoreCase) &&
                arg.Substring("debugMode=".Length).Equals("on", StringComparison.OrdinalIgnoreCase));

        InitializeComponent();
        UnhandledException += App_UnhandledException;
        AppDomain.CurrentDomain.FirstChanceException += (_, e) =>
        {
            if (DebugModeEnabled)
                WriteLog($"FirstChanceException: {e.Exception}");
        };
        if (DebugModeEnabled)
            WriteLog($"debugMode=on; commandLine={Environment.CommandLine}");
    }

    private static void WriteLog(string message)
    {
        try
        {
            var dir = Path.GetDirectoryName(LogPath);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
            File.AppendAllText(LogPath, $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff}] {message}{Environment.NewLine}");
        }
        catch
        {
            // keep silent if the log path cannot be written
        }
    }

    private static void App_UnhandledException(object sender, Microsoft.UI.Xaml.UnhandledExceptionEventArgs e)
    {
        WriteLog($"UnhandledException: {e.Exception}");
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        try
        {
            if (DebugModeEnabled) WriteLog("OnLaunched start");
            Microsoft.Windows.AppNotifications.AppNotificationManager.Default.Register();
        }
        catch (Exception ex)
        {
            if (DebugModeEnabled) WriteLog($"Register notification manager failed: {ex}");
        }

        try
        {
            MainWindow = new MainWindow();
            if (DebugModeEnabled) WriteLog("MainWindow created");
            MainWindow.Activate();
            if (DebugModeEnabled) WriteLog("MainWindow activated");
        }
        catch (Exception ex)
        {
            WriteLog($"Window activation failed: {ex}");
            throw;
        }
    }
}
