<!-- @trace spec:simplified-tray-ux -->
# simplified-tray-ux Specification

## Status

active
promoted-from: openspec/changes/archive/2026-04-25-simplified-tray-ux/
annotation-count: 17

## Purpose

Replace the accreted, multi-submenu tray design with a minimal, static menu structure that mirrors the user's mental model: launch a project, optionally drop into a terminal, quit. Eliminates per-project action duplication, visible menu flicker, and the "Seedlings" agent-picker submenu (converged on OpenCode Web as the sole runtime). Pre-builds all menu items on startup and toggles `enabled` state on transitions rather than rebuilding the entire tree.

## Requirements

### Requirement: Startup Menu Structure

@trace spec:simplified-tray-ux

On application startup, the tray MUST display exactly 4 static menu items:

1. **Status Indicator** — Single dynamic entry that displays startup progress
   - Initially: `[<checklist> Verifying environment ...]` (animated, clickable suppressed)
   - Updates: `[<checklist> Building [image names] ...]` as stages progress
   - Removed: Once startup completes and GitHub auth state is determined
2. **Separator** — A divider line (─────────────────────────)
3. **Version & Attribution** — `vn.n.nnn.nnn - By Tlatoāni` (always present, disabled, never clickable)
4. **Quit** — `Quit Tillandsias` (always present, always immediately responsive, shuts down all containers on exit)

The status indicator is the only dynamic top-level item. No menu flicker; status updates in-place without rebuild.

#### Scenario: Cold start with image build required
- **WHEN** tray starts and images are missing
- **THEN** menu shows 4 static items: status indicator (building), separator, version, quit
- **AND** status indicator animates to show which subsystems are building (deterministic emoji order)
- **AND** menu does not flicker or rebuild

#### Scenario: Status completion — transition to authentication
- **WHEN** all images finish building
- **THEN** status indicator is removed from the menu
- **AND** the menu now shows: separator, version, quit (if no auth yet) OR separator, home/cloud menus, version, quit (if authed)
- **AND** no flicker; single property toggle (`enabled = false` on status indicator, then `hidden = true`)

### Requirement: Five-Stage Static Menu Structure

@trace spec:simplified-tray-ux

The tray MUST pre-build a single menu tree on startup with all items created upfront. State transitions MUST ONLY toggle the `enabled` property on individual items, never rebuild the tree. The project list is the sole exception (rebuild only when the project set changes, detected via set comparison, not polling).

Menu stages and their contents (after startup status indicator is removed):

| Stage | Menu items (top → bottom) |
|-------|---------------------------|
| **Booting** | `[<checklist> Verifying environment ...]` / Separator / Version / Quit |
| **Ready** | (status indicator removed) / Separator / Version / Quit |
| **NoAuth** | `[<key> GitHub Login]` / Separator / Version / Quit |
| **Authed** | `[<home> ~/src/ >]` / `[<cloud> Cloud >]` / Separator / Version / Quit |
| **NetIssue** | `[<key> GitHub Login]` (or cached) / `[<home> ~/src/ >]` (if cached) / `[<cloud> Cloud >]` (if available) / Separator / Version / Quit |

The version line (e.g., `v0.1.168.224`) and the signature `— by Tlatoāni` appear in every stage after the final separator, both disabled (visual signature only, never clickable), immediately above `Quit Tillandsias`.

#### Scenario: State transition from Booting to Authed
- **WHEN** all images finish building and GitHub auth is confirmed
- **THEN** the status indicator is hidden
- **AND** menu transitions to show `[<home> ~/src/ >]` and `[<cloud> Cloud >]` menus
- **AND** no menu rebuild, only property toggles

### Requirement: Home Menu ([<home> ~/src/ >])

@trace spec:simplified-tray-ux

When authenticated, MUST show all local projects found in `~/.tillandsias/watch/` (or configured watch path), alphabetically sorted. Each project MUST display exactly 4 tools:

```
[<home> ~/src/ >
├── <project-1> ▸
│   ├── 💻 OpenCode (terminal-based IDE)
│   ├── 🌐 OpenCode Web (browser-based IDE)
│   ├── 👽 Claude (AI assistant)
│   └── 🔧 Maintenance terminal (direct shell access)
├── <project-2> ▸
│   ├── 💻 OpenCode (terminal-based IDE)
│   ├── 🌐 OpenCode Web (browser-based IDE)
│   ├── 👽 Claude (AI assistant)
│   └── 🔧 Maintenance terminal (direct shell access)
└── ...
```

**Tool Descriptions:**
- **💻 OpenCode** — Terminal-based IDE. Opens an interactive session inside the forge container.
- **🌐 OpenCode Web** — Browser-based IDE. Opens the web interface in the system's default browser.
- **👽 Claude** — AI assistant. Launches Claude (host-side or in-container) for code assistance.
- **🔧 Maintenance terminal** — Direct shell access. Opens a terminal with `podman exec -it tillandsias-<project>-<genus> /bin/bash`.

**Behavior:**
- Selecting a tool launches the corresponding service for that project
- A single forge container `tillandsias-<project>-<genus>` persists for the lifetime of the tray app
- Multiple browser windows, terminals, or IDE sessions can connect to the same container concurrently

#### Scenario: User launches a local project via OpenCode Web
- **WHEN** user clicks 🌐 OpenCode Web for a local project
- **THEN** a single forge container `tillandsias-<project>-<genus>` starts (or reuses existing)
- **AND** the system's default browser opens pointing to `<project>.opencode.localhost:8080`
- **AND** subsequent tool clicks open new windows/sessions against the same running container

#### Scenario: User opens multiple tools for the same project
- **WHEN** user clicks different tools (e.g., Claude, then Maintenance terminal)
- **THEN** the same container continues running
- **AND** each tool attaches or launches a new session within that container
- **AND** all sessions share the same project state and git history

### Requirement: Cloud Menu ([<cloud> Cloud >])

@trace spec:simplified-tray-ux

When authenticated and remote projects are readable from GitHub, MUST show all remote projects available to the user, MINUS any projects that already exist locally in `~/.tillandsias/watch/`. Alphabetically sorted.

```
[<cloud> Cloud >
├── <remote-project-1> ▸
│   ├── 💻 OpenCode (clone to ~/.tillandsias/watch/<name>, then terminal IDE)
│   ├── 🌐 OpenCode Web (clone, then browser IDE)
│   ├── 👽 Claude (clone, then AI assistant)
│   └── 🔧 Maintenance terminal (clone, then shell)
├── <remote-project-2> ▸
│   ├── 💻 OpenCode
│   ├── 🌐 OpenCode Web
│   ├── 👽 Claude
│   └── 🔧 Maintenance terminal
└── ...
```

**Tool Descriptions:**
- Same 4 tools as Home menu, with checkout applied
- **💻 OpenCode** — Clone to `~/.tillandsias/watch/<project-name>` (if not already cloned), then open terminal IDE
- **🌐 OpenCode Web** — Clone, then open browser IDE
- **👽 Claude** — Clone, then launch AI assistant
- **🔧 Maintenance terminal** — Clone, then open shell

**Checkout Behavior:**
1. When user selects an action on a cloud project:
   - If not already cloned: clone repository to `~/.tillandsias/watch/<project-name>` in the background
   - Once cloned, launch the selected tool
2. Subsequent selections of the same cloud project reuse the cloned copy (no re-clone)
3. After clone completes, the project appears in the Home menu on next menu rebuild

#### Scenario: User launches a cloud project for the first time
- **WHEN** user clicks 🌐 OpenCode Web for a remote project
- **THEN** system begins cloning the repository to `~/.tillandsias/watch/<project-name>`
- **AND** once clone completes, a forge container starts and browser opens
- **AND** project now appears in Home menu ([<home> ~/src/ >])
- **AND** subsequent tool selections on this project reuse the cloned copy

#### Scenario: User selects a cloud project that is already cloned locally
- **WHEN** user clicks a tool for a remote project that is already in `~/.tillandsias/watch/`
- **THEN** the tool launches immediately (no clone needed)
- **AND** the project is NOT shown in Cloud menu (only in Home)

### Requirement: GitHub Login Menu ([<key> GitHub Login])

@trace spec:simplified-tray-ux

MUST be visible when the user is not authenticated or GitHub is unreachable.

**Menu Item:** `[<key> GitHub Login]`

**Behavior:**
- Selecting this item opens the GitHub OAuth flow in the system's default browser
- Upon successful authentication, the menu transitions from NoAuth to Authed stage
- After auth completes, the menu shows `[<home> ~/src/ >]` and `[<cloud> Cloud >]` instead of the login item
- During GitHubunreachable (NetIssue stage), this menu item displays but may use cached authentication state

### Requirement: Single Container Per Project

- There MUST be at most ONE forge container (`tillandsias-<project>-<genus>`) per project per tray process
- Container lifetime MUST be created on first "Launch" and MUST persist until tray Quit
- Multiple browser windows MUST be able to connect to the same container (OpenCode Web supports concurrent conversations in the same process)
- Multiple maintenance terminals SHOULD be able to exec into the same container
- Container teardown MUST happen on tray Quit (after `shutdown_all`)

#### Scenario: User launches and then attaches another window
- **WHEN** user clicks "Launch", then later clicks "Launch" again
- **THEN** the same container continues running
- **AND** a second browser window opens against the existing session

### Requirement: CLI Behavior Unchanged

Command-line invocation (`tillandsias <path>`) MUST preserve current defaults:

- Default action MUST be to drop into an interactive shell (via `entrypoint-terminal.sh`)
- `tillandsias <path> --opencode` flag SHOULD force OpenCode TUI
- This is intentionally different from tray default (tray launches OpenCode Web in browser)

## Sources of Truth

- `cheatsheets/runtime/tray-state-machine.md` — the five-stage menu projection, dynamic region composition, state transitions driven by enclave/credential/remote health
- `cheatsheets/architecture/event-driven-basics.md` — event-driven menu updates instead of polling or rebuilds
- `cheatsheets/welcome/tray-minimal-ux.md` — minimal launch UI with four static elements and progressive disclosure as environment readies

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:ephemeral-guarantee`

Gating points:
- Tray UX state is ephemeral; UI choices don't persist inappropriately
- Deterministic and reproducible: test results do not depend on prior state
- Falsifiable: failure modes (leaked state, persistence) are detectable
