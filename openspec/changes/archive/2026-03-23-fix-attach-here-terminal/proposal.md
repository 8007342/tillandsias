## Why

"Attach Here" is completely broken. The tray app spawns a detached container that the user can't interact with. The whole point of Tillandsias is: click Attach Here → OpenCode appears. Zero manual steps. No "podman exec" commands.

## What Changes

- Attach Here: start container detached, then open a platform terminal window running `podman exec -it <name> /home/forge/entrypoint.sh`
- Simple platform terminal: Linux (ptyxis/gnome-terminal/xterm), macOS (open -a Terminal), Windows (cmd start)
- Entrypoint always launches OpenCode when TTY is available (the terminal provides it)

## Capabilities

### Modified Capabilities
- `environment-runtime`: Attach Here opens terminal with OpenCode, not detached-only

## Impact

- Modified: handlers.rs — start detached + open terminal
- Entrypoint unchanged (already handles TTY detection correctly)
