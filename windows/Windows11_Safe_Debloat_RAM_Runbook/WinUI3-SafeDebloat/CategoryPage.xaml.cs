using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.RegularExpressions;
using CommunityToolkit.WinUI.Controls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;

namespace SafeDebloat;

// Páginas de categoría (Privacidad … Servicios: condicional) con SettingsCards REALES
// importadas (CommunityToolkit.WinUI.Controls.SettingsControls).
// Cada tweak = un SettingsCard con ToggleSwitch + TextBox oculto que muestra el .ps1
// INDEPENDIENTE (Scripts/<Id>.ps1) LEÍDO DEL DISCO en runtime — nunca un string inline.
// El switch global Power User (pie del NavigationView) revela esos TextBox.
// Textos vía Strings/*.resw (claves "{Id}.Label/Desc/Tip").
public sealed partial class CategoryPage : Page
{
    private GroupDef? _group;
    private int _groupIndex;
    private readonly Dictionary<string, ToggleSwitch> _toggles = new();
    private readonly List<FrameworkElement> _psBoxes = new();
    private TextBlock? _status;

    public CategoryPage() => InitializeComponent();

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        PowerUser.Changed += OnPowerUser;
        if (e.Parameter is int gi && gi >= 0 && gi < Catalog.Groups.Count)
        {
            _groupIndex = gi;
            Show(Catalog.Groups[gi], gi);
        }
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        base.OnNavigatedFrom(e);
        PowerUser.Changed -= OnPowerUser;
    }

    private void OnPowerUser(bool enabled)
    {
        foreach (var tb in _psBoxes)
            tb.Visibility = enabled ? Visibility.Visible : Visibility.Collapsed;
    }

    // Lee el .ps1 REAL del disco, COMPLETO y sin filtros.
    private static string ReadScriptFull(TweackDef item)
    {
        try
        {
            return File.ReadAllText(Path.Combine(AppContext.BaseDirectory, item.ScriptFile));
        }
        catch (Exception ex)
        {
            return $"(no se pudo leer {item.ScriptFile}: {ex.Message})";
        }
    }

    private void Show(GroupDef group, int gi)
    {
        _group = group;
        Host.Children.Clear();
        _toggles.Clear();
        _psBoxes.Clear();

        Host.Children.Add(new TextBlock
        {
            Text = L10n.Get($"NavG{gi}.Content", group.Title),
            FontSize = 20,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold
        });

        foreach (var item in group.Items)
        {
            string label = L10n.Get($"{item.Id}.Label", item.Label);
            string desc = L10n.Get($"{item.Id}.Desc", item.Desc);
            string detail = item.Services.Length > 0
                ? L10n.Get("Services.Prefix", "Servicios: ") + string.Join(", ", item.Services)
                : L10n.Get($"{item.Id}.Tip", item.Tip);

            // Layout: toggle SOLO a la derecha; InfoBar full-width debajo del label;
            // TextBox monoespaciado full-width debajo del InfoBar, SOLO comandos.
            var head = new SettingsCard
            {
                Header = label,
                IsClickEnabled = false,
                Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
                BorderThickness = new Thickness(0),
                Padding = new Thickness(0)
            };
            head.HeaderIcon = new FontIcon { Glyph = group.Glyph };

            // DOS InfoBars: Implicaciones (siempre Informational) y Riesgos
            // (Warning si toca servicios). Claves "{Id}.Impl" / "{Id}.Risk".
            var infoImpl = new InfoBar
            {
                IsOpen = true,
                IsClosable = false,
                Severity = InfoBarSeverity.Informational,
                Title = L10n.Get("Info.Impl.Title", "Implicaciones"),
                Message = L10n.Get($"{item.Id}.Impl", desc)
            };
            var infoRisk = new InfoBar
            {
                IsOpen = true,
                IsClosable = false,
                Severity = InfoBarSeverity.Warning,
                Title = L10n.Get("Info.Risk.Title", "Riesgos"),
                Message = L10n.Get($"{item.Id}.Risk", item.Tip)
            };
            // .ps1 COMPLETO sin filtros, con syntax highlighting estilo WinUI Gallery:
            // RichTextBlock + tokenizador propio (comentarios, strings, cmdlets,
            // variables, números, parámetros). Sin paquetes nuevos.
            string full = ReadScriptFull(item);
            string[] codeLines = full.Split('\n');
            int nLines = Math.Max(1, codeLines.Length);
            var code = new RichTextBlock
            {
                FontFamily = new FontFamily("Consolas"),
                FontSize = 12,
                IsTextSelectionEnabled = true
            };
            foreach (var ln in codeLines)
                code.Blocks.Add(HighlightPsLine(ln.TrimEnd('\r')));
            var ps = new ScrollViewer
            {
                Content = code,
                Height = Math.Min(44 + 22 * (nLines - 1), 170),
                HorizontalScrollMode = ScrollMode.Enabled,
                HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
                VerticalScrollMode = ScrollMode.Enabled,
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                BorderBrush = new SolidColorBrush(Microsoft.UI.Colors.Gray),
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(4),
                Padding = new Thickness(8, 6, 8, 6),
                Visibility = PowerUser.Enabled ? Visibility.Visible : Visibility.Collapsed
            };

            var toggle = new ToggleSwitch { IsOn = item.On, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(12, 0, 0, 0) };

            // Izquierda: label + infobar + textbox. Derecha: SOLO el switch.
            var left = new StackPanel { Spacing = 6 };
            left.Children.Add(head);
            left.Children.Add(infoImpl);
            left.Children.Add(infoRisk);
            left.Children.Add(ps);
            var grid = new Grid();
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            left.SetValue(Grid.ColumnProperty, 0);
            toggle.SetValue(Grid.ColumnProperty, 1);
            grid.Children.Add(left);
            grid.Children.Add(toggle);

            var wrap = new Border
            {
                CornerRadius = new CornerRadius(6),
                Padding = new Thickness(12, 10, 12, 10),
                Margin = new Thickness(0, 0, 0, 8),
                Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
                BorderBrush = new SolidColorBrush(Microsoft.UI.Colors.Gray),
                BorderThickness = new Thickness(1)
            };
            wrap.Child = grid;

            _toggles[item.Id] = toggle;
            _psBoxes.Add(ps);
            Host.Children.Add(wrap);
        }

        string title = L10n.Get($"NavG{gi}.Content", group.Title);
        var apply = new Button
        {
            Content = L10n.Format("Apply.Format", "Aplicar {0}", title),
            Width = 220,
            Style = (Style)Application.Current.Resources["AccentButtonStyle"]
        };
        apply.Click += Apply_Click;
        Host.Children.Add(apply);
        _status = new TextBlock { TextWrapping = TextWrapping.Wrap };
        Host.Children.Add(_status);
    }

    // Tokenizador PowerShell mínimo para el visor: comentarios, strings, cmdlets
    // (Verbo-Sustantivo), variables, números y parámetros. Esquema oscuro tipo ISE.
    private static Paragraph HighlightPsLine(string line)
    {
        var p = new Paragraph { Margin = new Thickness(0) };
        if (line.TrimStart().StartsWith("#"))
        {
            p.Inlines.Add(new Run { Text = line, Foreground = PsBrush(106, 153, 85) });
            return p;
        }
        var re = new Regex("('[^']*'|\"[^\"]*\")|(\\$[\\w:]+)|(\\b\\d+\\b)|(\\b[A-Z][a-zA-Z]*-[A-Za-z][\\w]*\\b)|( -{1,2}[A-Za-z]+)");
        int pos = 0;
        foreach (Match m in re.Matches(line))
        {
            if (m.Index > pos)
                p.Inlines.Add(new Run { Text = line.Substring(pos, m.Index - pos) });
            SolidColorBrush? fg = null;
            if (m.Groups[1].Success) fg = PsBrush(206, 145, 120);
            else if (m.Groups[2].Success) fg = PsBrush(78, 201, 176);
            else if (m.Groups[3].Success) fg = PsBrush(181, 206, 168);
            else if (m.Groups[4].Success) fg = PsBrush(220, 220, 170);
            else if (m.Groups[5].Success) fg = PsBrush(156, 220, 254);
            var run = new Run { Text = m.Value };
            if (fg is not null) run.Foreground = fg;
            p.Inlines.Add(run);
            pos = m.Index + m.Length;
        }
        if (pos < line.Length)
            p.Inlines.Add(new Run { Text = line.Substring(pos) });
        if (line.Length == 0)
            p.Inlines.Add(new Run { Text = " " });
        return p;
    }

    private static SolidColorBrush PsBrush(byte r, byte g, byte b) =>
        new(Microsoft.UI.ColorHelper.FromArgb(255, r, g, b));

    private async void Apply_Click(object sender, RoutedEventArgs e)
    {
        if (_group is null || _status is null) return;
        var ids = _group.Items.Where(i => _toggles.TryGetValue(i.Id, out var t) && t.IsOn).Select(i => i.Id).ToList();
        var svcs = _group.Items.Where(i => ids.Contains(i.Id)).SelectMany(i => i.Services).ToList();
        string title = L10n.Get($"NavG{_groupIndex}.Content", _group.Title);
        if (ids.Count == 0)
        {
            // No crítico: nada que aplicar.
            _status.Text = L10n.Get("Toast.NothingMsg", "Sin cambios: no hay nada seleccionado.");
            Notifier.Show(Notifier.Kind.Partial,
                L10n.Get("Toast.NothingTitle", "Safe Debloat"),
                L10n.Get("Toast.NothingMsg", "Sin cambios: no hay nada seleccionado."));
            return;
        }
        bool ok = await MainWindow.ConfirmAsync(
            L10n.Format("Confirm.Format", "Se desactivarán {0} servicios en {1}.", svcs.Count, title));
        if (!ok) return;
        try
        {
            var json = JsonSerializer.Serialize(new { Services = svcs, Ids = ids });
            File.WriteAllText(Path.Combine(Path.GetTempPath(), "SafeDebloat-WinUI-Selection.json"), json);
            _status.Text = L10n.Format("Status.Exported.Format", "Selección exportada ({0} servicios).", svcs.Count);
            Notifier.Show(Notifier.Kind.Success,
                L10n.Get("Toast.OkTitle", "Safe Debloat"),
                L10n.Format("Toast.OkMsg", "Cambios exportados ({0} servicios).", svcs.Count));
        }
        catch (Exception ex)
        {
            // Crítico: ni siquiera se pudo exportar.
            _status.Text = ex.Message;
            Notifier.Show(Notifier.Kind.Critical,
                L10n.Get("Toast.ErrorTitle", "Safe Debloat"),
                L10n.Get("Toast.ErrorMsg", "Error al exportar la selección."));
        }
    }
}
