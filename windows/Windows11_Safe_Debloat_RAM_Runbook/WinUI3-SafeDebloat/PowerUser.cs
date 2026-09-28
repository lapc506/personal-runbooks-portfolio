using System;

namespace SafeDebloat;

// Switch global "Power User" del pie del NavigationView. Al activarse, cada
// SettingsCard muestra su TextBox oculto con el .ps1 que se aplicaría en el registro.
public static class PowerUser
{
    private static bool _enabled;
    public static bool Enabled
    {
        get => _enabled;
        set
        {
            if (_enabled == value) return;
            _enabled = value;
            Changed?.Invoke(value);
        }
    }
    public static event Action<bool>? Changed;
}
