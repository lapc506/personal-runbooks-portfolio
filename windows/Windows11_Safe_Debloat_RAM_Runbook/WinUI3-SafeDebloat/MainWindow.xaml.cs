using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace SafeDebloat;

public sealed partial class MainWindow : Window
{
    public MainWindow() => InitializeComponent();

    private void Nav_SelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        // TODO: navigate ContentFrame per Tag (Overview / Procesos / ...).
        // Procesos grid -> CommunityToolkit Labs DataTable (verify package id
        // CommunityToolkit.Labs.WinUI.DataTable on first restore).
    }

    // Confirm pattern: XamlRoot is MANDATORY in WinUI 3 (else InvalidOperationException).
    public static async System.Threading.Tasks.Task<bool> ConfirmAsync(string text)
    {
        var dialog = new ContentDialog
        {
            Title = "Confirmar cambios",
            Content = text,
            PrimaryButtonText = "Aplicar",
            CloseButtonText = "Cancelar",
            XamlRoot = App.MainWindow.Content.XamlRoot
        };
        return await dialog.ShowAsync() == ContentDialogResult.Primary;
    }
}
