using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;

namespace SafeDebloat;

public sealed class ProcRow
{
    public string Pid { get; set; } = "";
    public string Name { get; set; } = "";
    public string RamMb { get; set; } = "";
    public string Nuclear { get; set; } = "";
    public string Servicios { get; set; } = "";
    public string Ruta { get; set; } = "";
}

public sealed class ProcGroup : List<ProcRow>
{
    public string Title { get; }
    public ProcGroup(string title, IEnumerable<ProcRow> rows) : base(rows) { Title = title; }
}

public sealed partial class OverviewPage : Page
{
    private readonly List<double> _history = new();
    private double _totalGb = 7.3;
    private Polyline? _chartLine;
    private Polygon? _chartFill;
    private DispatcherQueueTimer? _sampler;

    public OverviewPage()
    {
        InitializeComponent();
        Loaded += (_, _) =>
        {
            Load();
            _sampler = DispatcherQueue.CreateTimer();
            _sampler.Interval = TimeSpan.FromSeconds(1);
            _sampler.Tick += (_, _) => UpdateChart();
            _sampler.Start();
        };
        Unloaded += (_, _) => _sampler?.Stop();
    }

    private void Load()
    {
        var (totalGb, usedGb) = Ram();
        if (totalGb > 0)
        {
            _totalGb = totalGb;
            RamSummary.Text = L10n.Format("Ram.Summary.Format", "Memoria: {0:F2}/{1:F1} GB", usedGb, totalGb);
            RamBar.Value = usedGb / totalGb * 100;
        }
        else RamSummary.Text = L10n.Get("Ram.Unknown", "Memoria: n/d");

        // ItemsSource del ListView agrupado; el template crea un DataRow por fila (patrón DataTableSample).
        // Servicios = nombres CORTOS (Name, no DisplayName) + ruta completa del binario, vía WMI.
        try
        {
            var (svcMap, pathMap) = ProcMaps();
            var rows = new List<ProcRow>();
            foreach (var p in Process.GetProcesses()
                         .OrderByDescending(p => SafeWorkingSet(p))
                         .Take(60))
            {
                rows.Add(new ProcRow
                {
                    Pid = p.Id.ToString(),
                    Name = p.ProcessName,
                    RamMb = (SafeWorkingSet(p) / 1048576.0).ToString("F0"),
                    Nuclear = IsCore(p, pathMap) ? "Si" : "no",
                    Servicios = svcMap.TryGetValue(p.Id, out var s) ? s : "",
                    Ruta = pathMap.TryGetValue(p.Id, out var r) ? r : "",
                });
            }
            var nuclear = rows.Where(r => r.Nuclear == "Si").ToList();
            var resto = rows.Where(r => r.Nuclear != "Si").ToList();
            var groups = new List<ProcGroup>
            {
                new(L10n.Format("Group.Nuclear.Format", "Nucleares — NO desactivar, rompen Windows ({0})", nuclear.Count), nuclear),
                new(L10n.Format("Group.Resto.Format", "No nucleares — candidatos a revisar ({0})", resto.Count), resto),
            };
            var cvs = new Microsoft.UI.Xaml.Data.CollectionViewSource { IsSourceGrouped = true, Source = groups };
            ProcList.ItemsSource = cvs.View;
        }
        catch { /* Overview nunca debe crashear por enumerar procesos */ }
    }

    private void UpdateChart()
    {
        var (_, usedGb) = Ram();
        _history.Add(usedGb);
        while (_history.Count > 60) _history.RemoveAt(0);
        if (ChartCanvas is null) return;

        double W = ChartCanvas.ActualWidth > 100 ? ChartCanvas.ActualWidth : 560;
        const double H = 118;
        var pts = new PointCollection();
        for (int i = 0; i < _history.Count; i++)
            pts.Add(new Point(i / 59.0 * W, H - (_history[i] / _totalGb * H)));

        ChartCanvas.Children.Clear();
        var gridBrush = new SolidColorBrush(Microsoft.UI.ColorHelper.FromArgb(255, 42, 42, 42));
        for (int gi = 1; gi < 8; gi++)
        {
            var gl = new Line
            {
                X1 = gi / 8.0 * W, X2 = gi / 8.0 * W, Y1 = 0, Y2 = H,
                Stroke = gridBrush, StrokeThickness = 1
            };
            ChartCanvas.Children.Add(gl);
        }
        for (int gj = 1; gj < 4; gj++)
        {
            var gl2 = new Line
            {
                X1 = 0, X2 = W, Y1 = gj / 4.0 * H, Y2 = gj / 4.0 * H,
                Stroke = gridBrush, StrokeThickness = 1
            };
            ChartCanvas.Children.Add(gl2);
        }
        _chartFill = new Polygon
        {
            Fill = new SolidColorBrush(Microsoft.UI.ColorHelper.FromArgb(70, 0, 120, 212))
        };
        foreach (var pt in pts) _chartFill.Points.Add(pt);
        if (pts.Count > 0)
        {
            _chartFill.Points.Add(new Point(pts[^1].X, H));
            _chartFill.Points.Add(new Point(pts[0].X, H));
        }
        _chartLine = new Polyline
        {
            Stroke = new SolidColorBrush(Microsoft.UI.ColorHelper.FromArgb(255, 0, 120, 212)),
            StrokeThickness = 2,
            Points = pts
        };
        ChartCanvas.Children.Add(_chartFill);
        ChartCanvas.Children.Add(_chartLine);
    }

    // Una sola pasada WMI: PID -> nombres cortos de servicio + ruta completa del ejecutable.
    private static (Dictionary<int, string> Svc, Dictionary<int, string> Path) ProcMaps()
    {
        var svc = new Dictionary<int, List<string>>();
        var path = new Dictionary<int, string>();
        try
        {
            using var q1 = new System.Management.ManagementObjectSearcher(
                "SELECT ProcessId, Name FROM Win32_Service WHERE ProcessId > 0");
            foreach (System.Management.ManagementObject mo in q1.Get())
            {
                int pid = Convert.ToInt32(mo["ProcessId"]);
                string name = mo["Name"]?.ToString() ?? "";
                if (!svc.TryGetValue(pid, out var list)) svc[pid] = list = new List<string>();
                list.Add(name);
            }
            using var q2 = new System.Management.ManagementObjectSearcher(
                "SELECT ProcessId, ExecutablePath FROM Win32_Process");
            foreach (System.Management.ManagementObject mo in q2.Get())
            {
                try
                {
                    int pid = Convert.ToInt32(mo["ProcessId"]);
                    string? exe = mo["ExecutablePath"]?.ToString();
                    if (!string.IsNullOrEmpty(exe)) path[pid] = exe;
                }
                catch { }
            }
        }
        catch { }
        return (svc.ToDictionary(kv => kv.Key, kv => string.Join("; ", kv.Value)), path);
    }

    private static (double TotalGb, double UsedGb) Ram()
    {
        var st = new MEMORYSTATUSEX
        {
            dwLength = (uint)System.Runtime.InteropServices.Marshal.SizeOf<MEMORYSTATUSEX>()
        };
        if (!GlobalMemoryStatusEx(ref st)) return (0, 0);
        double total = st.ullTotalPhys / 1073741824.0;
        double free = st.ullAvailPhys / 1073741824.0;
        return (total, total - free);
    }

    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    private struct MEMORYSTATUSEX
    {
        public uint dwLength;
        public uint dwMemoryLoad;
        public ulong ullTotalPhys;
        public ulong ullAvailPhys;
        public ulong ullTotalPageFile;
        public ulong ullAvailPageFile;
        public ulong ullTotalVirtual;
        public ulong ullAvailVirtual;
        public ulong ullAvailExtendedVirtual;
    }

    [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
    [return: System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)]
    private static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX lpBuffer);

    private static long SafeWorkingSet(Process p)
    {
        try { return p.WorkingSet64; } catch { return 0; }
    }

    private static bool IsCore(Process p, Dictionary<int, string> pathMap)
    {
        if (pathMap.TryGetValue(p.Id, out var exe))
            return exe.StartsWith(@"C:\Windows\", StringComparison.OrdinalIgnoreCase);
        try { return (p.MainModule?.FileName ?? "").StartsWith(@"C:\Windows\", StringComparison.OrdinalIgnoreCase); }
        catch { return false; }
    }
}
