using System;

namespace SafeDebloat;

// Acceso central a Strings/{lang}/Resources.resw con fallback al literal español.
// Ejemplo: L10n.Get("Welcome.Text", "Bienvenido").
public static class L10n
{
    private static readonly Microsoft.Windows.ApplicationModel.Resources.ResourceLoader _loader = new();

    // GetString("A.B") NO atraviesa scopes del PRI; la vía documentada es el URI
    // ms-resource con slashes: "A.B" -> "Resources/A/B".
    public static string Get(string key, string fallback)
    {
        try
        {
            var s = _loader.GetStringForUri(new Uri("ms-resource:///Resources/" + key.Replace('.', '/')));
            return string.IsNullOrEmpty(s) ? fallback : s;
        }
        catch { return fallback; }
    }

    public static string Format(string key, string fallback, params object[] args)
    {
        try
        {
            var s = _loader.GetStringForUri(new Uri("ms-resource:///Resources/" + key.Replace('.', '/')));
            if (!string.IsNullOrEmpty(s)) return string.Format(s, args);
        }
        catch { }
        return string.Format(fallback, args);
    }
}
