## Why

The current tray menu has accreted complexity that no longer matches
how Tillandsias is actually used:

- A "Seedlings" submenu lets the user pick claude / opencode / opencode-web
  per project. We've converged on opencode-web as the only sensible default
  from the tray (the agent picker matters in CLI but not when the user
  click the icon).
- Per-project actions duplicate launcher / runner / cleanup paths
  (Attach Here, Start, Stop, Destroy, Serve Here, Terminal) — five buttons
  for one project.
- Every state change rebuilds the whole menu, causing visible flicker on
  GTK and KDE.
- The `tray-responsiveness-and-startup-gating` change drafted a four-stage
  gate but didn't simplify the menu shape. The gate logic doesn't help if
  there are 12 disabled items in the menu — the user still can't tell
  which one to wait for.

This proposal replaces the tray menu with a near-flat shape that mirrors
the user's mental model: **launch the project**, optionally drop into a
terminal, get out.

`tray-responsiveness-and-startup-gating` is **superseded** by this one
(its proposal stays in the archive for historical context but its tasks
roll into here).

## What Changes

### Menu shape — five lifecycle stages, all items pre-created

The tray pre-builds a single static menu structure on startup. State
transitions toggle `enabled` on individual items rather than rebuilding
the whole tree. The dynamic project list is the only piece that does
need rebuild-on-change, and even that fires only when the project set
actually changes (set comparison, not periodic polling).

| Stage          | Menu items (top → bottom)                                                                                  |
|----------------|------------------------------------------------------------------------------------------------------------|
| **Booting**    | `Building [forge/proxy/git/inference]` / divider / Language / version (disabled) / `— by Tlatoāni` (disabled) / Quit |
| **Ready**      | `Ready` (transient, fades) / divider / Language / version / `— by Tlatoāni` / Quit                         |
| **NoAuth**     | `Sign in to GitHub` / divider / Language / version / `— by Tlatoāni` / Quit                                |
| **Authed**     | `Projects ▸` / divider / Language / version / `— by Tlatoāni` / Quit                                       |
| **NetIssue**   | `Sign in to GitHub` / `(GitHub unreachable, using cached projects)` / Projects ▸ / Language / version / `— by Tlatoāni` / Quit |

The version line (e.g. `v0.1.168.224`) and the `— by Tlatoāni` signature
SHALL appear in every stage right above `Quit Tillandsias`, both
disabled (visual signature only — never clickable).

`Booting` may stay visible for several minutes the first time
(image build), seconds afterwards. `Ready` is a 2-second transient that
hands off to `NoAuth` or `Authed`.

### Projects ▸ submenu

```
Projects ▸
├── [ ] Include remote        (toggle; default off)
├── ──────────────────────
├── <local-project-1>     ▸  ├── Launch
├── <local-project-2>     ▸  ├── Maintenance terminal
├── ...                       └── ──────────────────
├── ──────────────────── (visible only when "Include remote" toggled on)
├── <remote-project-1>   ▸
├── <remote-project-2>   ▸
└── ...
```

- Local projects are listed alphabetically.
- Remote projects appear under a divider when `Include remote` is on.
- Each project entry has exactly two actions: **Launch** and
  **Maintenance terminal**. No more Attach/Start/Stop/Destroy split.

### Single forge per Tillandsias process

`Launch` always opens (or re-opens) a single `tillandsias-<project>-<genus>`
forge container running `opencode serve` + the SSE keepalive proxy.
Subsequent clicks on `Launch` reopen another browser window pointing at
the same container — opencode-web supports multiple concurrent
conversations in the same process. There is at most ONE forge container
per project per tray process. Tear-down on Quit only.

### Maintenance terminal — same container

`Maintenance terminal` opens a host terminal that runs
`podman exec -it tillandsias-<project>-<genus> /bin/bash` against the
running forge container. The user can run any tool already installed
(java/maven/gradle/python/rust/etc.) or kick the running opencode
process. Multiple maintenance terminals can be open against the same
forge — they're just shells inside the existing container.

### CLI behaviour preserved

`tillandsias <path>` from the command line keeps its current default:
drops into the forge with `entrypoint-terminal.sh` (interactive shell).
Tray launch and CLI launch are intentionally different defaults.
`tillandsias <path> --opencode` still works for forced opencode TUI in
CLI mode; that's an expert flag.

### Container hostname conventions for printing

The forge entrypoint sets `/etc/hosts` overrides inside the container
so URLs printed from inside resolve to the right enclave addresses for
human-friendly messages. Combined with `subdomain-routing-via-reverse-proxy`
the user-facing URLs look like:

- `http://<project>.opencode.localhost/`  — opencode-web
- `http://<project>.web.localhost/` — generic dev server alias
- Other `<project>.<service>.localhost` per `web-services.md`

The forge prints these strings (never `localhost:<port>`).

### Removed

- `MenuCommand::SelectAgent` — no agent picker.
- `MenuCommand::ServeHere` — folded into the new `Launch`.
- `MenuCommand::Destroy` — single forge per process; tear down on Quit.
- `MenuCommand::Start` — same as Launch.
- `MenuCommand::Stop` / `StopProject` — only Quit stops things.
- `Settings ▸` submenu — language is top-level; "credit" line goes too
  (low value, free real estate).
- `RootTerminal` from the tray (CLI keeps its equivalent via
  `tillandsias --bash` if anyone needs it).
- `seedlings_submenu()` — agent picker removed.

## Capabilities

### Modified Capabilities

- `tray-app` — full menu shape redefined; responsiveness invariant
  preserved (Quit + Language always responsive). The
  `tray-responsiveness-and-startup-gating` change is superseded.

## Impact

- `src-tauri/src/menu.rs` — drops from ~720 LOC to ~250.
- `src-tauri/src/event_loop.rs` — handles fewer MenuCommand variants.
- `src-tauri/src/main.rs` — calls `update_menu_state()` (toggles) instead
  of `rebuild_menu()` everywhere except project-list changes.
- `tillandsias-core::event::MenuCommand` — variants pruned.
- `images/default/entrypoint-forge-opencode-web.sh` — already prints a
  human-friendly URL; no change.

## Tasks rolled in from `tray-responsiveness-and-startup-gating`

- Quit always serviceable within 5s — kept; `biased; tokio::select!` in
  the event loop, cancel tokens for long-running spawns.
- Stale-container sweep on startup — kept; the "tools-overlay-tombstone"
  change already simplified the orphan set.
- GitHub credential health classifier (`CredentialHealth { Authenticated,
  CredentialMissing, CredentialInvalid, GithubUnreachable }`) — kept and
  drives the `NoAuth` / `Authed` / `NetIssue` stage selection above.

The complexity of the old four-stage gating model collapses into the
five-stage state machine above, which is small enough to enumerate and
test end-to-end.
