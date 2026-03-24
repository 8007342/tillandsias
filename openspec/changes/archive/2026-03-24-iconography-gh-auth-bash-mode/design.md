## Context

The tray menu already uses emoji for container lifecycle states (🌱 bud, 🌺 bloom, 🍂 dried, 🌿 pup) in the "Running Environments" section. The "Attach Here" items currently have no visual indicator. The GitHub auth flow spawns a `podman run -it` inside a terminal emulator via `open_terminal()`, but the double indirection (terminal emulator → podman → bash script) breaks interactive prompts. CLI attach mode works but lacks a `--bash` escape hatch.

## Goals / Non-Goals

**Goals:**
- Prefix "Attach Here" items with lifecycle emoji reflecting container state
- Create a working standalone GitHub auth script
- Add `--bash` CLI flag for troubleshooting
- Remove dead skill file

**Non-Goals:**
- Custom icon rendering in menu items (Tauri v2 limitation — emoji only)
- Implementing a full settings/preferences UI
- Auto-detecting git identity from system config

## Decisions

### Decision 1: Emoji prefix on Attach Here items

**Choice**: Prefix each "Attach Here" label with 🌱 when no container is running for that project, 🌺 when one is running.

The existing `TrayState` already tracks which containers are running and which project they belong to. The menu builder already has access to this state. We just need to cross-reference the project's scanned path against running containers to determine the emoji.

**Rationale**: Consistent with the existing emoji convention for container lifecycle. Users immediately see which projects have active environments.

### Decision 2: Standalone `gh-auth-login.sh` script

**Choice**: Create a standalone bash script at the project root that:
1. Runs `podman run -it --rm` directly in the current terminal (no terminal emulator indirection)
2. Mounts the same secrets directories as the current handler
3. Prompts for git identity interactively
4. Runs `gh auth login` with full TTY access
5. Applies security flags (cap-drop, userns, no-new-privileges)

**Alternatives considered**:
- *Fix the terminal emulator approach*: The double indirection (terminal → podman → script) is fundamentally fragile. Different terminal emulators handle `-e` arguments differently. Running directly in the user's current terminal is reliable.
- *Use Tauri's shell plugin to exec*: Still has the TTY problem — Tauri captures stdout/stderr.

**Rationale**: Interactive `gh auth login` needs a real TTY. Running `podman run -it` in the user's terminal gives it one. The tray handler can then call `open_terminal("./gh-auth-login.sh")` which is a single command, not a complex inline script.

### Decision 3: `--bash` CLI flag

**Choice**: Add `--bash` to `CliMode::Attach`. When set, override the container entrypoint with `/bin/bash`.

The runner already builds the `podman run` command dynamically. Adding `--entrypoint /bin/bash` when `--bash` is true is a one-line change.

**Rationale**: Essential for troubleshooting container issues — "is the image broken or is my project broken?"

### Decision 4: Remove forge skill, keep tray handler

**Choice**: Delete `images/default/skills/command/gh-auth-login.md`. Update the tray `GitHubLogin` handler to call the new script via `open_terminal()`.

**Rationale**: The skill was a bad idea (user's words). The tray handler is still useful as a discoverable entry point — it just needs to delegate to the working script.

## Risks / Trade-offs

- **[Emoji rendering]** → Platform-dependent. All target platforms (GNOME, macOS, Windows 10+) render these emoji correctly in system menus.
- **[gh-auth-login.sh needs forge image]** → Script checks for image and offers to build it. Same pattern as `tillandsias attach`.
