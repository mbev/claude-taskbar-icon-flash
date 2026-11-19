# taskbar-flash

Windows plugin for Claude Code. When a session finishes its turn or needs you (permission prompt, waiting for input), the window hosting it flashes: title bar and taskbar button, about once a second, until you switch to it. Sending a prompt also stops it.

Works in the Claude desktop app (Code tab), Windows Terminal, VS Code, or any window that hosts a `claude` session. Unattended runs (`claude -p` from Task Scheduler) have no window and do nothing.

## Install

```
/plugin marketplace add mbev/claude-taskbar-flash
/plugin install taskbar-flash@mbev-plugins
```

Then start a new session (or run `/reload-plugins`).

## Notes

- If the window is already in front when the session finishes, Windows doesn't flash it.
- The desktop app is one window for all sessions, so a session finishing while you are in that window (on another session) won't flash. The sidebar shows it.
- First run compiles a small helper into `%LOCALAPPDATA%\taskbar-flash` (about 1s); later runs take about 0.5s.
- Check which window it targets: `powershell -File scripts/flash.ps1 test`
