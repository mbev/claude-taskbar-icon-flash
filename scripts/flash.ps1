# taskbar-flash: flash the window hosting this Claude Code session until it is focused.
# Usage: flash.ps1 start|stop|test [-RateMs 500]
#   start  flash caption + taskbar button continuously until the window comes to the foreground
#   stop   stop flashing (used on prompt submit)
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

    delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")] static extern bool FlashWindowEx(ref FLASHWINFO pwfi);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr hWnd, uint cmd);
    [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr hWnd, StringBuilder s, int n);
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32FirstW(IntPtr snap, ref PROCESSENTRY32 e);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32NextW(IntPtr snap, ref PROCESSENTRY32 e);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);

    const uint FLASHW_STOP = 0, FLASHW_ALL = 3, FLASHW_TIMERNOFG = 12;

    // pid -> (parent pid, exe name) for every running process
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

    // First visible, unowned, titled top-level window of a process.
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

    public static bool Flash(long hwnd, bool start, uint rateMs)
    {
        var fi = new FLASHWINFO
        {
            cbSize = (uint)Marshal.SizeOf(typeof(FLASHWINFO)),
            hwnd = new IntPtr(hwnd),
            dwFlags = start ? (FLASHW_ALL | FLASHW_TIMERNOFG) : FLASHW_STOP,
            uCount = 0,
            dwTimeout = start ? rateMs : 0
        };
        return FlashWindowEx(ref fi);
    }
}
'@

    # Compile once per source version and cache the DLL; Add-Type compiles take about a second.
    $sha = [System.Security.Cryptography.SHA1]::Create()
    $hash = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($src))[0..5] | ForEach-Object { $_.ToString('x2') })
    $cacheDir = Join-Path $env:LOCALAPPDATA 'taskbar-flash'
    $dll = Join-Path $cacheDir "TaskbarFlash-$hash.dll"
    if (-not ([System.Management.Automation.PSTypeName]'TaskbarFlash').Type) {
        if (-not (Test-Path $dll)) {
            New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
            Add-Type -TypeDefinition $src -OutputAssembly $dll -OutputType Library
        }
        Add-Type -Path $dll
    }

    $host_ = [TaskbarFlash]::FindHostWindow()
    if (-not $host_) {
        if ($Action -eq 'test') { 'No host window found (unattended run or no windowed ancestor).' }
        exit 0
    }
    $hwnd, $exe, $title = $host_ -split '\|', 3

    switch ($Action) {
        'test'  { "Would flash: $exe  hwnd=$hwnd  title='$title'" }
        'start' { [void][TaskbarFlash]::Flash([long]$hwnd, $true, [uint32]$RateMs) }
        'stop'  { [void][TaskbarFlash]::Flash([long]$hwnd, $false, 0) }
    }
}
catch {
    if ($Action -eq 'test') { "Error: $_" }
}
exit 0
