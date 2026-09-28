using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace SafeDebloat;

public sealed partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
        Nav.SelectedItem = Nav.MenuItems[0];
        ContentFrame.Navigate(typeof(OverviewPage));
    }

    private void PowerUser_Toggled(object sender, RoutedEventArgs e)
    {
        if (sender is ToggleSwitch sw) PowerUser.Enabled = sw.IsOn;
    }

    private void Nav_SelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (args.SelectedItem is not NavigationViewItem item || item.Tag is not string tag) return;
        if (tag == "Overview") ContentFrame.Navigate(typeof(OverviewPage));
        else if (tag.StartsWith("G") && int.TryParse(tag.Substring(1), out int gi))
            ContentFrame.Navigate(typeof(CategoryPage), gi);
    }

    // Confirm pattern: XamlRoot is MANDATORY in WinUI 3 (else InvalidOperationException).
    public static async System.Threading.Tasks.Task<bool> ConfirmAsync(string text)
    {
        var dialog = new ContentDialog
        {
            Title = L10n.Get("Dialog.Title", "Confirmar cambios"),
            Content = text,
            PrimaryButtonText = L10n.Get("Dialog.Primary", "Aplicar"),
            CloseButtonText = L10n.Get("Dialog.Close", "Cancelar"),
            XamlRoot = App.MainWindow!.Content.XamlRoot
        };
        return await dialog.ShowAsync() == ContentDialogResult.Primary;
    }
}
