using System;
using System.Diagnostics;
using System.IO;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace SafeDebloat;

public static class AdminExecutionService
{
    public static async Task<bool> ConfirmAsync(string message, string title, string primaryButtonText)
    {
        if (App.MainWindow is not Window window || window.Content is not FrameworkElement root)
            return true;

        var dialog = new ContentDialog
        {
            Title = title,
            Content = new ScrollViewer
            {
                MaxHeight = 360,
                Content = new TextBlock
                {
                    Text = message,
                    TextWrapping = TextWrapping.Wrap,
                    Margin = new Thickness(0, 8, 0, 0)
                }
            },
            XamlRoot = root.XamlRoot,
            PrimaryButtonText = primaryButtonText,
            CloseButtonText = "Cancelar",
            DefaultButton = ContentDialogButton.Primary
        };

        return await dialog.ShowAsync() == ContentDialogResult.Primary;
    }

    public static bool RunScriptAsAdmin(string scriptPath, string scriptName, string scriptSummary)
    {
        if (string.IsNullOrWhiteSpace(scriptPath) || !File.Exists(scriptPath))
            throw new FileNotFoundException($"No se encontró el script '{scriptName}' en '{scriptPath}'.");

        var workingDirectory = Path.GetDirectoryName(scriptPath) ?? Environment.CurrentDirectory;
        var psi = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            Arguments = $"-NoProfile -ExecutionPolicy Bypass -File \"{scriptPath}\"",
            UseShellExecute = true,
            Verb = "runas",
            WorkingDirectory = workingDirectory
        };

        using var process = Process.Start(psi);
        if (process is null)
            throw new InvalidOperationException($"No se pudo iniciar la elevación UAC para '{scriptName}'.");

        process.WaitForExit();
        return process.ExitCode == 0;
    }
}
