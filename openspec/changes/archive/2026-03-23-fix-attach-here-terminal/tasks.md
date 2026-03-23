## 1. Fix Attach Here

- [x] 1.1 handlers.rs: open platform terminal running full `podman run -it --rm` command — terminal provides TTY, opencode gets real terminal
- [x] 1.2 Add open_terminal function: ptyxis/gnome-terminal/xterm on Linux, osascript on macOS, cmd on Windows
- [x] 1.3 Simplified entrypoint: always exec opencode (terminal always provides TTY), fall back to bash
- [x] 1.4 Build, install, rebuilt image with new entrypoint
