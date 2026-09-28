using Microsoft.UI.Xaml;

namespace SafeDebloat;

public partial class App : Application
{
    public static Window? MainWindow { get; private set; }

    public App() => InitializeComponent();

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        try { Microsoft.Windows.AppNotifications.AppNotificationManager.Default.Register(); } catch { }
        MainWindow = new MainWindow();
        MainWindow.Activate();
    }
}
