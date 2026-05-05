# OpenCode

@trace spec:agent-source-of-truth

**Version baseline**: OpenCode v0.2+ (baked at /opt/agents/opencode, web mode via Bun 1.0+)  
**Use when**: Launching web-based visual IDE, running OpenCode CLI, debugging web sessions, parallel coding

## Provenance

- https://opencode.dev/ — OpenCode documentation
- https://bun.sh/ — Bun JavaScript runtime (powers OpenCode web)
- **Last updated:** 2026-04-27

## Quick reference

| Command | Purpose |
|---------|---------|
| `opencode --help` | Show CLI commands |
| `opencode serve --port 5173` | Start web IDE on port 5173 |
| `opencode session list` | Show all active sessions |
| `opencode session new` | Create a new session |
| `opencode config get theme` | Read config value |
| `opencode config set theme dark` | Set config value |

## Common patterns

**Start web IDE for the current project:**
```bash
cd $HOME/src/my-project
opencode serve --port 5173
# Browser opens at http://localhost:5173 (app mode; OS native browser, not Tauri webview)
```

**Run multiple OpenCode sessions in parallel:**
```bash
# Terminal 1: Session A on port 5173
cd $HOME/src/project-a
opencode serve --port 5173

# Terminal 2: Session B on port 5174
cd $HOME/src/project-b
opencode serve --port 5174

# Access both in separate browser windows
# http://localhost:5173  (Project A)
# http://localhost:5174  (Project B)
```

**Check session state:**
```bash
opencode session list
# Shows: session ID, port, project dir, status (active/idle), last activity
```

**Configure OpenCode:**
```bash
# Default theme is light; switch to dark
opencode config set theme dark

# Set font (must be installed in forge)
opencode config set font "Fira Code"

# List all config options
opencode config list
```

## Common pitfalls

❌ **Binding to `0.0.0.0` instead of `127.0.0.1`**: Forge is network-isolated; binding to all interfaces doesn't help. → Use `--port 5173` (defaults to localhost); that's sufficient.

❌ **Port conflicts on the same forge**: Two agents try to start on port 5173. → Increment the port: 5173, 5174, 5175. Session DB keys off port + working dir; no collisions.

❌ **Assuming a Tauri webview**: OpenCode web runs in the OS native browser (Chrome, Firefox, Safari), not a Tauri container. → Debugging tools are your browser's DevTools (F12), not Tauri's.

❌ **Expecting the browser to be pre-installed**: The forge does NOT ship a browser. → The host OS's browser is launched by the tray; the forge agents cannot spawn browsers directly (network isolation). OpenCode prints the URL; a human (or the tray) opens it.

❌ **Leaving sessions orphaned**: If you kill `opencode serve` without `opencode session delete`, the session DB leaks. → Always `opencode session delete <id>` before exiting.

## See also

- `agents/claude-code.md` — Claude Code CLI for text-based analysis
- `agents/openspec.md` — OpenSpec workflow; often run alongside OpenCode in visual mode
