using System;
using System.Collections.Generic;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace SafeDebloat;

public sealed partial class MainWindow : Window
{
    private readonly Dictionary<string, int> _groupIndexByTag = new();

    public MainWindow()
    {
        InitializeComponent();
        BuildNavigation();
        PowerUserToggle.Toggled += PowerUserToggle_Toggled;
        Nav.SelectionChanged += Nav_SelectionChanged;

        PowerUser.Enabled = false;
        Nav.SelectedItem = FindMenuItem("Overview");
        SelectOverview();
    }

    private void BuildNavigation()
    {
        Nav.MenuItems.Clear();

        var overview = new NavigationViewItem
        {
            Content = "Resumen",
            Tag = "Overview",
            Icon = new FontIcon { Glyph = "\uE9D2" }
        };
        Nav.MenuItems.Add(overview);
        Nav.MenuItems.Add(new NavigationViewItemSeparator());

        for (var i = 0; i < Catalog.Groups.Count; i++)
        {
            var group = Catalog.Groups[i];
            var item = new NavigationViewItem
            {
                Content = group.Title,
                Tag = $"G{i}",
                Icon = new FontIcon { Glyph = group.Glyph }
            };

            _groupIndexByTag[item.Tag as string ?? $"G{i}"] = i;
            Nav.MenuItems.Add(item);
        }
    }

    private void PowerUserToggle_Toggled(object sender, RoutedEventArgs e)
    {
        PowerUser.Enabled = PowerUserToggle.IsOn;
    }

    private void Nav_SelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (args.SelectedItemContainer is not NavigationViewItem selected)
            return;

        if (selected.Tag is string tag)
        {
            switch (tag)
            {
                case "Overview":
                    SelectOverview();
                    break;
                default:
                    if (_groupIndexByTag.TryGetValue(tag, out var index))
                        ContentFrame.Navigate(typeof(CategoryPage), index);
                    break;
            }
        }
    }

    private NavigationViewItem? FindMenuItem(string tag)
    {
        foreach (NavigationViewItem item in Nav.MenuItems)
        {
            if (string.Equals(item.Tag as string, tag, StringComparison.Ordinal))
                return item;
        }

        return null;
    }

    private void SelectOverview()
    {
        ContentFrame.Navigate(typeof(OverviewPage));
    }
}
