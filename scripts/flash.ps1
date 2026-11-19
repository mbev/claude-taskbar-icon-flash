# taskbar-flash: get attention for the window hosting this Claude Code session.
# Usage: flash.ps1 start|stop|test [-RateMs 500]
#   start  launch a background watcher that pulses the taskbar button red (works even when the
#          window has focus) and flashes it when it doesn't, until you engage with the window
#   stop   stop the watcher (used on prompt submit)
#   test   print which window would flash, without flashing
# Always exits 0 so a failure never blocks a Claude Code session.
param(
    [Parameter(Position = 0)][ValidateSet('start', 'stop', 'test')][string]$Action = 'start',
    [int]$RateMs = 500
)

$ErrorActionPreference = 'Stop'
try {
    $src = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

[ComImport, Guid("ea1afb91-9e28-4b86-90e9-9e9f8a5eefaf"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ITaskbarList3
{
    void HrInit();
    void AddTab(IntPtr hwnd);
    void DeleteTab(IntPtr hwnd);
    void ActivateTab(IntPtr hwnd);
    void SetActiveAlt(IntPtr hwnd);
    void MarkFullscreenWindow(IntPtr hwnd, [MarshalAs(UnmanagedType.Bool)] bool fullscreen);
    void SetProgressValue(IntPtr hwnd, ulong completed, ulong total);
    void SetProgressState(IntPtr hwnd, int flags);
}

[ComImport, Guid("56FDF344-FD6D-11d0-958A-006097C9A090"), ClassInterface(ClassInterfaceType.None)]
class TaskbarListCom { }

public static class TaskbarFlash
{
    [StructLayout(LayoutKind.Sequential)]
    struct FLASHWINFO { public uint cbSize; public IntPtr hwnd; public uint dwFlags; public uint uCount; public uint dwTimeout; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct PROCESSENTRY32
    {
        public uint dwSize; public uint cntUsage; public uint th32ProcessID; public IntPtr th32DefaultHeapID;
        public uint th32ModuleID; public uint cntThreads; public uint th32ParentProcessID; public int pcPriClassBase;
        public uint dwFlags; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szExeFile;
    }

    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }

    delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")] static extern bool FlashWindowEx(ref FLASHWINFO pwfi);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr hWnd, uint cmd);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr hWnd, uint flags);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO lii);
    [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr hWnd, StringBuilder s, int n);
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32FirstW(IntPtr snap, ref PROCESSENTRY32 e);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32NextW(IntPtr snap, ref PROCESSENTRY32 e);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);

    const uint FLASHW_STOP = 0, FLASHW_ALL = 3, FLASHW_TIMERNOFG = 12;
    const int TBPF_NOPROGRESS = 0, TBPF_ERROR = 4;
    const int GraceMs = 1500;                    // ignore input right after the flash starts
    const int MaxMs = 4 * 60 * 60 * 1000;        // give up after 4 hours

    static Dictionary<uint, KeyValuePair<uint, string>> ProcessTable()
    {
        var map = new Dictionary<uint, KeyValuePair<uint, string>>();
        IntPtr snap = CreateToolhelp32Snapshot(2, 0);
        if (snap == new IntPtr(-1)) return map;
        try
        {
            var e = new PROCESSENTRY32 { dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32)) };
            if (Process32FirstW(snap, ref e))
                do { map[e.th32ProcessID] = new KeyValuePair<uint, string>(e.th32ParentProcessID, e.szExeFile); }
                while (Process32NextW(snap, ref e));
        }
        finally { CloseHandle(snap); }
        return map;
    }

    static IntPtr TopWindowOf(uint pid)
    {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) =>
        {
            uint wp; GetWindowThreadProcessId(h, out wp);
            if (wp == pid && IsWindowVisible(h) && GetWindow(h, 4 /*GW_OWNER*/) == IntPtr.Zero && GetWindowTextLength(h) > 0)
            { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    // Walk up from this process to the nearest ancestor that owns a window
    // (Claude desktop app, Windows Terminal, VS Code, ...). Returns "hwnd|exe|title" or "".
    public static string FindHostWindow()
    {
        var table = ProcessTable();
        uint pid = (uint)Process.GetCurrentProcess().Id;
        var seen = new HashSet<uint>();
        for (int depth = 0; depth < 32 && pid != 0 && seen.Add(pid); depth++)
        {
            KeyValuePair<uint, string> entry;
            if (!table.TryGetValue(pid, out entry)) break;
            uint parent = entry.Key;
            if (parent == 0 || !table.ContainsKey(parent)) break;
            string exe = table[parent].Value;
            if (exe.Equals("explorer.exe", StringComparison.OrdinalIgnoreCase)) break;
            IntPtr h = TopWindowOf(parent);
            if (h != IntPtr.Zero)
            {
                var sb = new StringBuilder(256); GetWindowText(h, sb, 256);
                return h.ToInt64() + "|" + exe + "|" + sb;
            }
            pid = parent;
        }
        return "";
    }

    static void Flash(IntPtr hwnd, bool start, uint rateMs)
    {
        var fi = new FLASHWINFO
        {
            cbSize = (uint)Marshal.SizeOf(typeof(FLASHWINFO)), hwnd = hwnd,
            dwFlags = start ? (FLASHW_ALL | FLASHW_TIMERNOFG) : FLASHW_STOP,
            uCount = 0, dwTimeout = start ? rateMs : 0
        };
        FlashWindowEx(ref fi);
    }

    static string StopEventName(long hwnd) { return "Local\\taskbar-flash-stop-" + hwnd; }

    public static void SignalStop(long hwnd)
    {
        EventWaitHandle ev;
        if (EventWaitHandle.TryOpenExisting(StopEventName(hwnd), out ev)) { ev.Set(); ev.Dispose(); }
        Flash(new IntPtr(hwnd), false, 0);
    }

    static bool IsHost(IntPtr fg, IntPtr hwnd)
    {
        return fg == hwnd || (fg != IntPtr.Zero && GetAncestor(fg, 3 /*GA_ROOTOWNER*/) == hwnd);
    }

    // Background loop: pulse the taskbar button red once per 2*rateMs until the person engages
    // with the window, a stop is signaled, or the window closes.
    public static void Watch(long hwndValue, int rateMs)
    {
        IntPtr hwnd = new IntPtr(hwndValue);
        bool created;
        using (var mutex = new Mutex(true, "Local\\taskbar-flash-" + hwndValue, out created))
        {
            if (!created) return;                 // a watcher is already running for this window
            using (var stop = new EventWaitHandle(false, EventResetMode.ManualReset, StopEventName(hwndValue)))
            {
                stop.Reset();
                var tb = (ITaskbarList3)new TaskbarListCom();
                tb.HrInit();
                uint startTick = (uint)Environment.TickCount;
                bool wasAway = !IsHost(GetForegroundWindow(), hwnd);
                if (wasAway) Flash(hwnd, true, (uint)rateMs);
                bool on = false;
                try
                {
                    while (IsWindow(hwnd))
                    {
                        on = !on;
                        if (on) { tb.SetProgressValue(hwnd, 100, 100); tb.SetProgressState(hwnd, TBPF_ERROR); }
                        else tb.SetProgressState(hwnd, TBPF_NOPROGRESS);

                        if (stop.WaitOne(rateMs)) break;
                        uint elapsed = (uint)Environment.TickCount - startTick;
                        if (elapsed > MaxMs) break;

                        bool fg = IsHost(GetForegroundWindow(), hwnd);
                        if (!fg) { wasAway = true; continue; }
                        if (wasAway) break;               // switched back to the window
                        if (elapsed < GraceMs) continue;

                        // Window kept focus the whole time: stop on input while the cursor is over it.
                        var lii = new LASTINPUTINFO { cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO)) };
                        GetLastInputInfo(ref lii);
                        if ((int)(lii.dwTime - (startTick + GraceMs)) <= 0) continue;
                        POINT p; RECT r;
                        if (GetCursorPos(out p) && GetWindowRect(hwnd, out r) &&
                            p.X >= r.Left && p.X < r.Right && p.Y >= r.Top && p.Y < r.Bottom) break;
                    }
                }
                finally
                {
                    try { tb.SetProgressState(hwnd, TBPF_NOPROGRESS); } catch { }
                    Flash(hwnd, false, 0);
                }
            }
        }
    }

    [STAThread]
    public static void Main(string[] args)
    {
        try
        {
            if (args.Length >= 3 && args[0] == "watch") Watch(long.Parse(args[1]), int.Parse(args[2]));
        }
        catch { }
    }
}
'@

    # Compile once per source version into a windowless exe (no console flash when launched) and cache it.
    $sha = [System.Security.Cryptography.SHA1]::Create()
    $hash = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($src))[0..5] | ForEach-Object { $_.ToString('x2') })
    $cacheDir = Join-Path $env:LOCALAPPDATA 'taskbar-flash'
    $exe = Join-Path $cacheDir "TaskbarFlash-$hash.exe"
    if (-not (Test-Path $exe)) {
        New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
        Add-Type -TypeDefinition $src -OutputAssembly $exe -OutputType WindowsApplication
    }
    if (-not ([System.Management.Automation.PSTypeName]'TaskbarFlash').Type) {
        [void][Reflection.Assembly]::LoadFrom($exe)
    }

    $host_ = [TaskbarFlash]::FindHostWindow()
    if (-not $host_) {
        if ($Action -eq 'test') { 'No host window found (unattended run or no windowed ancestor).' }
        exit 0
    }
    $hwnd, $exeName, $title = $host_ -split '\|', 3

    switch ($Action) {
        'test'  { "Would flash: $exeName  hwnd=$hwnd  title='$title'" }
        'start' { Start-Process -FilePath $exe -ArgumentList 'watch', $hwnd, $RateMs }
        'stop'  { [TaskbarFlash]::SignalStop([long]$hwnd) }
    }
}
catch {
    if ($Action -eq 'test') { "Error: $_" }
}
exit 0
