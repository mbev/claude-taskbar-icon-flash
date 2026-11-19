# taskbar-flash

Windows plugin for Claude Code. When a session finishes its turn or needs you (permission prompt, waiting for input), the taskbar button of the window hosting it pulses red about once a second. This works even when that window has focus, which matters on multi-monitor setups where you left Claude focused but are looking at another screen. If the window is in the background, its title bar and taskbar button also flash.

It stops when you engage with the window:

- switch back to it from another window, or
- click or type while the mouse is over it (if it kept focus the whole time), or
- send a prompt.

It gives up after 4 hours.

Works in the Claude desktop app (Code tab), Windows Terminal, VS Code, or any window that hosts a `claude` session. Unattended runs (`claude -p` from Task Scheduler) have no window and do nothing.

## Install

```
/plugin marketplace add mbev/claude-taskbar-flash
/plugin install taskbar-flash@mbev-plugins
```

Then start a new session (or run `/reload-plugins`).

## Notes

- The desktop app is one window for all sessions, so a session finishing while you are in that window (on another session) won't flash. The sidebar shows it.
- First run compiles a small helper into `%LOCALAPPDATA%\taskbar-flash` (about 1s); later runs take about 0.5s.
- Check which window it targets: `powershell -File scripts/flash.ps1 test`
