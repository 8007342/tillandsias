---
tags: [tray, state-machine, tauri, menu, ux]
languages: [rust]
since: 2024-01-01
last_verified: 2026-04-27
sources:
  - https://tauri.app/learn/system-tray/
authority: high
status: current
---

# Tray State Machine

@trace spec:tray-app

## Overview

The tray menu has a stable bottom row (signature, `Quit Tillandsias`) built once at startup and never touched. Above it sits a **dynamic region** that is appended/removed via `Menu::insert` / `Menu::remove` driven by `(stage, state)` projection. There are no disabled placeholder rows — when something has nothing to say, it's hidden, not greyed out.

**Note:** The `Language ▸` submenu was removed in 0.1.169.227 — i18n is hard-defaulted to English until the translation pipeline catches up.

Stage selection is deterministic: given the triple `(enclave_health, credential_health, remote_repo_fetch_status)` there is exactly one correct stage.

## The five stages and their dynamic-region projection

The dynamic region is rendered top-to-bottom in this order whenever an item is enabled:

1. **Contextual status line** — disabled, single line, only when at least one condition holds (see *Status line truth table* below).
2. **`🔑 Sign in to GitHub`** — enabled action, only in `NoAuth` / `NetIssue`.
3. **Running-stack submenus** — one per project with at least one container of type `Forge`, `OpenCodeWeb`, or `Maintenance` running. Sorted by lowercase project name.
4. **`🏠 ~/src ▸`** — only when `state.projects` is non-empty.
5. **`☁️ Cloud ▸`** — only when at least one repo in `state.remote_repos` is not present locally.

| Stage      | Trigger                                                            | Dynamic region (top → bottom)                                                                                              |
|------------|--------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------|
| `Booting`  | One or more enclave images still building                          | status line (`Building […]…`)                                                                                              |
| `Ready`    | All enclave images ready, before credential probe completes        | optional status line (`<image> ready` flash within 2 s of completion)                                                      |
| `NoAuth`   | Probe returned `CredentialMissing` or `CredentialInvalid`          | `🔑 Sign in to GitHub`                                                                                                     |
| `Authed`   | Probe returned `Authenticated`                                     | running-stack submenus, `🏠 ~/src ▸` (if any locals), `☁️ Cloud ▸` (if any uncloned remotes)                              |
| `NetIssue` | Probe returned `GithubUnreachable` (cached projects available)     | `🔑 Sign in to GitHub`, status line (`GitHub unreachable — using cached list`), running stacks, `🏠 ~/src ▸` (if cached)   |

The static row at the bottom is ALWAYS present in every stage:

```
─────────── separator ───────────
v0.1.169.227 — by Tlatoāni     ← single combined disabled line
Quit Tillandsias
```

`Quit Tillandsias` is enabled in every stage. The signature line is the **only** disabled item in the menu — there is no `(No projects)`, `(Building…)`, or `(GitHub unreachable…)` placeholder elsewhere.

## Status line truth table

The contextual status line is composed by `tray_menu::status_text(state, stage)` (pure function, unit-tested):

| Condition                                         | Source                                                              | Fragment text                                  |
|---------------------------------------------------|----------------------------------------------------------------------|------------------------------------------------|
| Exactly one image build in progress               | `state.active_builds` with `BuildStatus::InProgress`, count = 1     | `Building <image>…`                            |
| Multiple image builds in progress                 | `state.active_builds` with `BuildStatus::InProgress`, count > 1     | `Building <a, b, …>…`                          |
| One or more builds completed within last 2 s       | `state.active_builds` with `BuildStatus::Completed`, completed_at < 2 s ago | `<image> ready` (one fragment per build)        |
| Stage is `NetIssue`                               | `stage == Stage::NetIssue`                                           | `GitHub unreachable — using cached list`       |
| None of the above                                 | (everything else)                                                    | `None` — status line omitted from the menu     |

Multiple active fragments are joined with `menu.status.separator` (default ` · `):

```
Building Forge… · GitHub unreachable — using cached list
```

A `Completed` build older than 2 s is dropped from the active set entirely by `event_loop.rs::prune_completed_builds`, which keeps the cached row gone forever once faded.

## Running-stack rendering

For each running project, `tray_menu::running_stacks(state)` returns a `RunningStack { project_name, project_path, bloom, tool_emojis }`. The submenu label is `<project>[ <bloom>][ <tool emojis>]`:

| Field         | Source                                                                      | Notes                                                                            |
|---------------|------------------------------------------------------------------------------|----------------------------------------------------------------------------------|
| `bloom`       | `display_emoji` of the `OpenCodeWeb` container, if one is running            | `None` when only `Forge` / `Maintenance` are alive — bloom = "live web session"  |
| `tool_emojis` | `display_emoji` of running `Maintenance` containers, in `state.running` order | Capped at 5; no overflow indicator                                               |

Children of every running-stack submenu (exactly two, in this order):

| Item                  | i18n key                          | Dispatches                                         | Behavior                                                                                          |
|-----------------------|-----------------------------------|----------------------------------------------------|---------------------------------------------------------------------------------------------------|
| `🌱 Attach Another`    | `menu.attach_another_with_emoji`  | `MenuCommand::Launch { project_path }`            | `handle_attach_web` reattach branch — opens an additional native browser window. No new container. |
| `🔧 Maintenance`       | `menu.maintenance`                | `MenuCommand::MaintenanceTerminal { project_path }` | Spawns a fresh terminal `podman exec`'d into the forge. Concurrent shells allowed.               |

There is **no Stop item.** The only way to tear down a running stack is `Quit Tillandsias`, which calls `handlers::shutdown_all`.

## Projects ▸ vs Remote Projects ▸

These are sibling top-level submenus, never nested. The legacy `Include remote` `CheckMenuItem` is gone — there is no toggle, and the `MenuCommand::IncludeRemoteToggle` variant has been removed.

| Submenu              | Appended when                                                                                          | Per-entry submenu       | Action                                                                                            |
|----------------------|--------------------------------------------------------------------------------------------------------|--------------------------|---------------------------------------------------------------------------------------------------|
| `🏠 ~/src ▸`         | `state.projects` is non-empty                                                                          | `<project> ▸`            | `🌱 Attach Here` (always); `🔧 Maintenance` (only when forge is running for that project)          |
| `☁️ Cloud ▸`         | At least one `state.remote_repos` entry is not in local projects AND not on disk under any watch path | `<repo-name> ▸`          | `⬇️ Clone & Launch` — dispatches `MenuCommand::CloneProject`, which clones then auto-attaches      |

When a submenu would have zero entries, it is **not** appended. There is no "(no projects)" placeholder.

## CredentialHealth → stage map

`src-tauri/src/github_health.rs` returns one of four variants. Each maps to exactly one stage:

| `CredentialHealth`       | HTTP signal                          | Stage      | Dynamic-region effect                                            |
|--------------------------|--------------------------------------|------------|------------------------------------------------------------------|
| `Authenticated`          | 200 from `GET /user`                 | `Authed`   | Running stacks + `Projects ▸` + `Remote Projects ▸` as applicable |
| `CredentialMissing`      | No token in OS keyring               | `NoAuth`   | Only `🔑 Sign in to GitHub`                                      |
| `CredentialInvalid`      | 401 / 403 from GitHub                | `NoAuth`   | Same as missing — re-auth flow                                   |
| `GithubUnreachable`      | DNS / timeout / 5xx / 429 / keyring D-Bus down | `NetIssue` | Sign-in offered + status line + cached `Projects ▸`              |

Probe budget: 10 seconds. A timeout is **always** classified as `GithubUnreachable` — never as `CredentialInvalid`. The tray must not fail closed on a slow probe.

## Allowed stage transitions

```
                    ┌──────────────────────┐
   start  ─────────►│      Booting         │
                    └──────────┬───────────┘
                               │ all enclave images ready
                               ▼
                    ┌──────────────────────┐
                    │       Ready          │ (≤ 2s transient)
                    └────┬──────────┬──────┘
                         │          │
       probe = Authenticated     probe = Missing/Invalid
                         │          │
                         ▼          ▼
                    ┌────────┐  ┌─────────┐
                    │ Authed │  │ NoAuth  │
                    └───┬────┘  └────┬────┘
                        │            │
          probe = Unreachable        │ user signs in
                        ▼            ▼
                  ┌─────────────┐    Authed
                  │  NetIssue   │
                  └─────────────┘
```

## Cache key for the dynamic region

`TrayMenu::apply_state` is gated on a `DynamicCacheKey`:

```text
status_text         : Option<String>
sign_in_visible     : bool
running_stacks      : Vec<(label, project_name)>
local_projects      : Vec<(name, forge_running)>
remote_only_projects: Vec<String>
```

Equality means the menu would render identically — the rebuild is skipped. This eliminates flicker on no-op state ticks. Caller side, the loop already debounces scanner events to 100 ms.

## Common debugging questions

### Why does "Sign in to GitHub" keep showing after I signed in?

Run `tillandsias --log-secrets-management` and look for the most recent `GitHub credential health probe complete` event. Cross-reference its `health = ...` field against the table above:

- `health = credential-missing` — keyring write didn't land. Check for `NoStorageAccess` errors (headless Linux, locked keyring).
- `health = credential-invalid` — token expired / revoked. Re-run `tillandsias --github-login`.
- `health = unreachable (...)` — probe timed out or got a 5xx. You're in `NetIssue`, not `NoAuth`. Sign-in still appears, alongside cached `Projects ▸` and the `GitHub unreachable — using cached list` status line.

### How do I tell `GithubUnreachable` from `CredentialInvalid`?

Look at the menu, not the logs:

| You see                                                                       | Stage      | Probe verdict        |
|-------------------------------------------------------------------------------|------------|----------------------|
| `🔑 Sign in to GitHub` only                                                    | `NoAuth`   | Missing or Invalid   |
| `🔑 Sign in to GitHub` + `GitHub unreachable — using cached list` status line | `NetIssue` | Unreachable          |

The status line is the discriminator. If you see it, the probe got a network/transient verdict.

### Why doesn't a running project show at the top?

The top-level running-stack submenus are derived from `state.running`. A project appears here only when at least one of its containers has `container_type ∈ {Forge, OpenCodeWeb, Maintenance}`. Containers like `GitService` or the bare `Web` server don't trigger a stack entry on their own.

If a forge IS running but the entry is missing, check that the project name carried by `ContainerInfo::project_name` matches `state.projects[i].name`. The dispatch `project_path` is filled from `state.projects` — if the project was deleted on disk, the path falls back to `<watch_path>/<project_name>`.

### Why doesn't the menu update when an image finishes building?

Stage transitions cause `apply_state` to recompute the dynamic region. If items are visibly stuck:

- Confirm the Cache key actually changed: every `BuildProgressEvent::Completed` mutates `state.active_builds`, which feeds `status_text`, which is part of the cache key.
- The 2-second `<image> ready` flash window is bounded by `BUILD_CHIP_FADEOUT` (10 s) in `event_loop.rs` for *removal from state*, but the status line itself shows `ready` only within the 2 s window inside `status_text`. After that the row disappears even though the entry lingers in `state.active_builds` for the full 10 s.

### What if the keyring D-Bus is down on Linux?

`probe_inner` catches this and returns `GithubUnreachable { reason: "keyring unavailable: ..." }` — you land in `NetIssue`, not `NoAuth`. This is intentional: a restarting Secret Service daemon should NOT force a sign-in dance.

## Static items (built once, never rebuilt)

| Item                          | Built at  | Updated by                                |
|-------------------------------|-----------|-------------------------------------------|
| `v<version> — by Tlatoāni`    | `setup`   | `set_text` on locale change only          |
| `Quit Tillandsias`            | `setup`   | `set_text` on locale change only          |
| Top-region separator          | `setup`   | never changes                             |

Everything else (status line, sign-in, running stacks, Projects, Remote Projects) is created on demand in the dynamic region and dropped when no longer needed. Item handles for the dynamic region are NOT recycled — each `apply_state` rebuild produces fresh items.

## Related

**Specs:**
- `openspec/specs/tray-app/spec.md` — requirements + scenarios for the menu shape
- `openspec/specs/remote-projects/spec.md` — Remote Projects fetch / clone flow

**Source files:**
- `src-tauri/src/tray_menu.rs` — `TrayMenu`, `apply_state`, `status_text`, `running_stacks`, `dispatch_click`
- `src-tauri/src/github_health.rs` — `CredentialHealth` enum + `probe()` (10s budget)
- `src-tauri/src/event_loop.rs` — `biased; tokio::select!`, cancel tokens, Quit priority
- `src-tauri/src/main.rs` — `rebuild_menu` calls `apply_state`

**Cheatsheets:**
- `docs/cheatsheets/secrets-management.md` — keyring backends, headless-Linux caveat
- `docs/cheatsheets/token-rotation.md` — what happens after `Authed`
- `docs/cheatsheets/logging-levels.md` — `--log-secrets-management` and friends

## Provenance

- https://tauri.app/learn/system-tray/ — Tauri system tray guide; TrayIcon, TrayIconBuilder, menu attachment, `on_tray_icon_event()`, `on_menu_event()`, tray events (Click, DoubleClick, Enter, Move, Leave), `features = ["tray-icon"]` in Cargo.toml
- **Last updated:** 2026-04-27
