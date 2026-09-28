using System.Collections.Generic;

namespace SafeDebloat;

// Espejo de $groups / $svcDefs / $tweakDefs de Safe-Debloat-Wizard.ps1.
// Label/Desc/Tip salen de Strings/*.resw (claves "{Id}.Label/Desc/Tip"); aquí solo
// van Ids, servicios y el script que se aplicaría (leído en runtime, visible en modo Power User).
public sealed class TweackDef
{
    public string Id { get; set; } = "";
    public string Label { get; set; } = "";
    public string Desc { get; set; } = "";
    public string Tip { get; set; } = "";
    public bool On { get; set; }
    public string[] Services { get; set; } = System.Array.Empty<string>();
    public string[] RegNames { get; set; } = System.Array.Empty<string>();
    public string ScriptFile { get; set; } = "";
    // Severidad del InfoBar de la card: "Informational" (HKCU reversible) o "Warning" (toca servicios).
    public string Severity { get; set; } = "Informational";
}

public sealed class GroupDef
{
    public string Title { get; set; } = "";
    public string Glyph { get; set; } = "";
    public List<TweackDef> Items { get; set; } = new();
}

public static class Catalog
{
    public static readonly List<GroupDef> Groups = new()
    {
        new GroupDef { Title = "AI", Glyph = "\uE7B5", Items = new()
        {
            new TweackDef { Id = "A_Copilot", Severity = "Warning", Label = "Desactivar Copilot",
                Desc = "Quita el asistente de IA integrado y su botón en búsqueda/Inicio.",
                Tip = "TurnOffWindowsCopilot=1 + ShowCopilotButton=0.", On = true,
                RegNames = new[] { "TurnOffWindowsCopilot", "ShowCopilotButton" },
                ScriptFile = "Scripts\\A_Copilot.ps1" },
            new TweackDef { Id = "A_Recall", Severity = "Warning", Label = "Desactivar Recall",
                Desc = "Desactiva el historial/contexto de IA de Windows Recall.",
                Tip = "DisableRecall / WindowsAI policy.", On = false,
                RegNames = new[] { "DisableRecall" },
                ScriptFile = "Scripts\\A_Recall.ps1" },
            new TweackDef { Id = "A_ClickToDo", Severity = "Warning", Label = "Desactivar Click to Do",
                Desc = "Apaga la IA para análisis de texto e imagen.",
                Tip = "DisableClickToDo.", On = false,
                RegNames = new[] { "DisableClickToDo" },
                ScriptFile = "Scripts\\A_ClickToDo.ps1" },
        } },
        new GroupDef { Title = "Privacidad", Glyph = "\uE72E", Items = new()
        {
            new TweackDef { Id = "T_Ads", Label = "Sin ID de publicidad ni experiencias a medida",
                Desc = "Quita el ID de publicidad y las experiencias a medida de Windows.",
                Tip = "AdvertisingInfo\\Enabled=0 + TailoredExperiences=0.", On = true,
                RegNames = new[] { "Enabled", "TailoredExperiencesWithDiagnosticDataEnabled" },
                ScriptFile = "Scripts\\T_Ads.ps1" },
        } },
        new GroupDef { Title = "Explorador", Glyph = "\uE8B7", Items = new()
        {
            new TweackDef { Id = "T_Explorer", Label = "Extensiones visibles + ocultos + Este equipo",
                Desc = "Muestra extensiones y archivos ocultos; abre en Este equipo.",
                Tip = "HideFileExt=0, Hidden=1, LaunchTo=1.", On = true,
                RegNames = new[] { "HideFileExt", "Hidden", "LaunchTo" },
                ScriptFile = "Scripts\\T_Explorer.ps1" },
        } },
        new GroupDef { Title = "Barra de tareas", Glyph = "\uE7F4", Items = new()
        {
            new TweackDef { Id = "T_Taskbar", Label = "Izquierda, sin widgets ni Task View",
                Desc = "Alineación clásica sin distracciones.",
                Tip = "TaskbarAl=0, TaskbarDa=0, ShowTaskViewButton=0.", On = true,
                RegNames = new[] { "TaskbarAl", "TaskbarDa", "ShowTaskViewButton" },
                ScriptFile = "Scripts\\T_Taskbar.ps1" },
        } },
        new GroupDef { Title = "Búsqueda y Copilot", Glyph = "\uE094", Items = new()
        {
            new TweackDef { Id = "T_Search", Label = "Sin Bing en buscar + sin Copilot",
                Desc = "Búsqueda local solamente, sin asistente.",
                Tip = "DisableSearchBoxSuggestions=1, TurnOffWindowsCopilot=1, ShowCopilotButton=0.", On = true,
                RegNames = new[] { "DisableSearchBoxSuggestions", "TurnOffWindowsCopilot", "ShowCopilotButton" },
                ScriptFile = "Scripts\\T_Search.ps1" },
        } },
        new GroupDef { Title = "Servicios: telemetría", Glyph = "\uE713", Items = new()
        {
            new TweackDef { Id = "S_Telemetry", Severity = "Warning", Label = "Telemetría y vendor",
                Desc = "DiagTrack, dmwappushservice, RetailDemo, InventorySvc, nvagent, HP.",
                Tip = "Sin dependientes en Home.", On = true,
                Services = new[] { "DiagTrack", "dmwappushservice", "RetailDemo", "InventorySvc", "nvagent", "HpTouchpointAnalyticsService" },
                ScriptFile = "Scripts\\S_Telemetry.ps1" },
        } },
        new GroupDef { Title = "Servicios: condicional", Glyph = "\uE713", Items = new()
        {
            new TweackDef { Id = "S_Xbox", Severity = "Warning", Label = "Xbox (4)", Desc = "Solo sin gaming.",
                Tip = "XblAuthManager, XblGameSave, XboxGipSvc, XboxNetApiSvc.", On = false,
                Services = new[] { "XblAuthManager", "XblGameSave", "XboxGipSvc", "XboxNetApiSvc" },
                ScriptFile = "Scripts\\S_Xbox.ps1" },
            new TweackDef { Id = "S_Maps", Severity = "Warning", Label = "Mapas y ubicación", Desc = "Solo si no los usas.",
                Tip = "MapsBroker + lfsvc.", On = false,
                Services = new[] { "MapsBroker", "lfsvc" },
                ScriptFile = "Scripts\\S_Maps.ps1" },
            new TweackDef { Id = "S_SysMain", Severity = "Warning", Label = "SysMain", Desc = "Ahorra RAM (mide antes/después).",
                Tip = "En HDD enlentece aperturas.", On = false,
                Services = new[] { "SysMain" },
                ScriptFile = "Scripts\\S_SysMain.ps1" },
            new TweackDef { Id = "S_Misc", Severity = "Warning", Label = "PcaSvc + TrkWks + lmhosts + DusmSvc", Desc = "Riesgo bajo.",
                Tip = "Compatibilidad y red menor.", On = false,
                Services = new[] { "PcaSvc", "TrkWks", "lmhosts", "DusmSvc" },
                ScriptFile = "Scripts\\S_Misc.ps1" },
        } },
    };
}
