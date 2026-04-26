## Context

Today's tray (`src-tauri/src/tray_menu.rs`) is built around a five-stage state machine where each stage projects to a fixed set of pre-built items, toggled via `set_enabled(bool)`. Because Tauri 2 does not expose `set_visible` reliably across platforms, "hide" is emulated as "disable + grey out". The visible result is a menu littered with greyed-out rows: a `Building [...]` chip when nothing is building, a transient `Ready` line, a disabled `Sign in to GitHub` banner whenever the auth state is in flux, a `(GitHub unreachable, using cached projects)` line, two stacked disabled lines for version + signature, and `No local projects` / `No remote projects` placeholders inside the Projects submenu. Users read these as broken UI.

Two further problems:

1. The `Include remote` `CheckMenuItem` inside `Projects ▸` triggers a full submenu rebuild on click. The cache key includes `include_remote` so toggling flips the gate and forces re-population. Visually, the menu collapses and re-opens — the user calls this a "reload".
2. The original spec called for running per-project stacks to render at the **top level** of the menu (above `Projects ▸`) so the user can see active work at a glance. Today running projects are buried under `Projects ▸ → <project> ▸ Launch / Maintenance`. Promoting them back is also part of this change.

The five-stage machine itself (`Stage::{Booting, Ready, NoAuth, Authed, NetIssue}`) is the right semantic backbone — it correctly captures `(enclave_health × credential_health × remote_repo_fetch_status)`. We keep the enum; we change how it projects to the menu.

## Goals / Non-Goals

**Goals:**
- Forbid disabled placeholder rows. The only disabled item in the menu is the single signature line `v<version> — by Tlatoāni`.
- Surface at most one optional contextual status line (still disabled — it's status, not action), shown only while a relevant condition holds. Otherwise the menu has no status line at all.
- Replace the `Include remote` checkbox with a sibling `Remote Projects ▸` submenu shown next to `Projects ▸`. Empty submenus are hidden, not shown disabled.
- Promote running per-project stacks to the top level. Each stack's submenu carries `🌱 Attach Here` and `🔧 Maintenance` only.
- Keep `Quit` always serviceable within 5 s and `Language ▸` always enabled — the existing biased `tokio::select!` guarantees this and is not in scope.
- Keep the i18n key `menu.attach_here` as the canonical name; deprecate `menu.launch`.

**Non-Goals:**
- Rewriting the five-stage state machine. Stage transitions and the `stage_from_health` function are unchanged.
- Reworking `handle_attach_web`, `handle_clone_project`, or `handle_maintenance_terminal`. The "Attach Here from a running stack" semantic (open another browser window) already exists at `handlers.rs:3347–3386` (the reattach branch). The maintenance-terminal handler already supports concurrent shells (each invocation `podman exec`s a fresh process). We are not touching the handlers.
- Adding per-stack Stop. Containers are torn down only on `Quit` per the user's directive.
- Fixing `*.opencode.localhost` ERR_CONNECTION_REFUSED. That is a separate change.

## Decisions

### Decision 1: One pre-built menu, but show/hide via append/remove rather than set_enabled

**Choice**: Keep the "build once, mutate handles" pattern for static items (signature, Quit, Language ▸). For the variable region (status line, Projects ▸, Remote Projects ▸, running-stack submenus), use `Menu::append`/`Menu::remove` to add/remove items dynamically. This gives genuine hiding rather than greyed-out placeholders.

**Why**: Tauri 2's `set_visible` is unreliable cross-platform — that's what produced the greyed-out workaround in the first place. `append`/`remove` works on every platform Tauri supports. The static signature + Language ▸ + Quit row stays at the bottom and is never touched, so libappindicator's blank-label bug (the historical reason for "build once, never rebuild") doesn't fire on those handles.

**Alternative rejected**: Pure `set_enabled(false)` to hide. Tried — that's the current state. Users misread it.

**Alternative rejected**: One full `Menu::rebuild` on every state change. Hits the libappindicator blank-label bug when items are recycled across rebuilds. The `simplified-tray-ux` change explicitly avoided this, and we keep that protection for the static row.

### Decision 2: Status line is a single optional `MenuItem`, owned by the menu and conditionally appended

**Choice**: Maintain a single `MenuItem` handle for the contextual status line. It is appended as the first menu item only when `status_message()` returns `Some(_)`. When the condition clears, the item is `remove`d. Label updates use `set_text` on the same handle so the click-target stays stable.

**Why**: The status semantics map cleanly to a single string. Multiple concurrent conditions (e.g., "Building forge" + "GitHub unreachable") get joined into one line: `Building forge · GitHub unreachable`. This avoids menu height changes when individual conditions flip.

**Status conditions and their text** (computed in pure function `status_text(state) -> Option<String>`):
| Condition | Source | Text |
|---|---|---|
| Forge image building | `state.active_builds` contains `Forge`/`Updated Forge` `InProgress` | `Building forge…` |
| Enclave step building | `state.active_builds` contains other `InProgress` | `Building {image}…` |
| Forge build just completed | `state.active_builds` `Completed` within 2s | `Forge ready` |
| Enclave step just completed | other `Completed` within 2s | `{image} ready` |
| GitHub unreachable | `Stage::NetIssue` | `GitHub unreachable — using cached list` |
| Otherwise | none | `None` (no row appended) |

Build chips already auto-fade after 10s via `BUILD_CHIP_FADEOUT`; we reuse that signal so the status line clears itself.

**Alternative rejected**: One handle per condition (`building_chip`, `ready_indicator`, `net_banner`). That's the current design. It produced the disabled-row clutter we're removing.

### Decision 3: Sign-in is an enabled action, not a disabled banner

**Choice**: When `Stage::NoAuth` or `Stage::NetIssue`, the menu shows a single enabled action item `🔑 Sign in to GitHub`. It is a real click target that dispatches `MenuCommand::GitHubLogin`. It is not a status indicator and is never disabled. When credentials are healthy, the item is `remove`d entirely.

**Why**: An action that the user can click is never disabled in a healthy menu — disabled actions are noise. The status of "no credentials" is implicit in the presence of the sign-in action.

### Decision 4: `Projects ▸` and `Remote Projects ▸` are sibling top-level submenus, both conditionally appended

**Choice**: 
- `Projects ▸` is appended when `state.projects` is non-empty.
- `Remote Projects ▸` is appended when `state.remote_repos` contains at least one repo not present in `state.projects` AND not present on disk under the watch path.
- Empty → not appended. Never shown disabled.

The `INCLUDE_REMOTE` `CheckMenuItem` and `MenuCommand::IncludeRemoteToggle` are removed. `state.remote_repos_loading`, `state.remote_repos_error`, and the existing fetch loop are unchanged — fetch happens automatically every 5s when authed (existing `event_loop.rs:226–244`).

**Why**: Two siblings are cheaper to render and easier to read than a toggleable section inside one submenu. The "include remote" preference becomes meaningless when the two lists are visually separated.

### Decision 5: Running per-project stacks render at the top, above the Projects submenus

**Choice**: For each project with at least one container in `state.running` of type `Forge | OpenCodeWeb | Maintenance`, append a top-level submenu with:
- Label: `<project> <bloom> [<tool emojis>]` — name first per the user's spec sketch, then the bloom emoji from the OpenCodeWeb container's `display_emoji` (today: `🌺`) when present, then up to **5** tool emojis from running Maintenance containers (in `state.running` order). When more than 5 maintenance containers run for one project, only the first 5 emojis are shown — no overflow indicator. Five is the cap because (a) tray labels are width-constrained on Linux indicators and macOS menu bars, (b) more than 5 concurrent maintenance shells per project is a power-user edge case the user did not request a solution for.
- Children:
  - `🌱 Attach Another` — dispatches `MenuCommand::Launch { project_path }`. The `handle_attach_web` reattach branch (`handlers.rs:3347–3386`) already opens another browser window when a forge is already running. No code change needed. Label is "Attach Another" (not "Attach Here") to communicate that this is the *additional-window* action, not the *cold-start* action — the cold-start path lives under `Projects ▸ → my-project ▸ 🌱 Attach Here`.
  - `🔧 Maintenance` — dispatches `MenuCommand::MaintenanceTerminal { project_path }`. Each click spawns a fresh terminal exec'd into the container. Concurrent maintenance shells are already supported by the handler.
- No Stop item. Stack lifetime is `app lifetime` per the spec.

These appear in stable order (project name, ASCII-sorted). The same project also appears under `Projects ▸` — that's fine; the top-level entry is the active-work shortcut.

**Why**: The original spec had this and the user wants it back. It's the highest-signal information in the menu — what's running right now.

### Decision 6: Locale keys

- Repurpose existing `menu.attach_here` (already in `locales/en.toml:20`) for the per-project cold-start action. Today's `menu.launch` (`🚀 Launch`, line 44) is removed.
- Add `menu.attach_here_with_emoji = "🌱 Attach Here"` for use under the `Projects ▸ → <project> ▸` cold-start submenu.
- Add `menu.attach_another_with_emoji = "🌱 Attach Another"` for use under the top-level running-stack submenu — different label, same `MenuCommand::Launch` dispatch. (The existing `menu.attach_here` value is "Attach Here" — no emoji — used by the CLI; we leave it as-is and add tray-specific keys with the plant emoji.)
- Drop locale keys: `menu.launch`, `menu.include_remote`, `menu.no_local_projects`, `menu.no_remote_projects`, `menu.maintenance_terminal` (replaced by `menu.maintenance` which already exists, line 27 — `"⛏️ Maintenance"`).
- Keep keys: `menu.sign_in_github`, `menu.signature`, `menu.quit`, `menu.language`, `menu.projects`, `menu.github.remote_projects`.
- Add `menu.signature_with_version = "v{version} — by Tlatoāni"` so the collapsed line is one i18n string with version interpolation. Falls back gracefully on locales that haven't been updated.
- Add `menu.status.building_one = "Building {image}…"`, `menu.status.building_many = "Building {images}…"`, `menu.status.ready = "{image} ready"`, `menu.status.github_unreachable = "GitHub unreachable — using cached list"` for the contextual status line.

### Decision 7: Cache key for the variable region

The `ProjectsCacheKey` becomes a `MenuRegionCacheKey` covering everything dynamic (running stacks, local projects, remote-only projects, status text). The dynamic region is wiped and rebuilt only when the key changes. The static region (signature, Language ▸, Quit) is never rebuilt.

## Risks / Trade-offs

- **Risk**: append/remove on Tauri 2 native menus may trigger a brief flicker on libappindicator when items are added/removed simultaneously. → **Mitigation**: batch the dynamic region under a single lock and use a single `update_dynamic_region` pass guarded by the cache key. We already debounce on a tuple-equality check.
- **Risk**: The status line appearing/disappearing changes the menu height, which can move other items under the cursor. → **Mitigation**: The status line is the topmost item, so cursor positions for all other items are unchanged when only the status line toggles. Other items only move when running stacks or projects appear/disappear, which is rare and tied to user actions (attach, clone, exit container).
- **Risk**: A project visible both as a top-level running-stack entry AND inside `Projects ▸` could confuse users into thinking they are different projects. → **Mitigation**: The top-level entry uses the bloom emoji prefix (`🌺`) so it's clearly the "live" shortcut; the `Projects ▸` entry is the cold catalogue. The user explicitly asked for this layout.
- **Trade-off**: Removing the `Include remote` toggle means power users can't suppress the Remote Projects submenu when they want a clean menu. → **Accepted**: The submenu is hidden when empty, which covers the main "I don't care about remote" case. Users with many remote repos can either ignore the submenu or sign out.
- **Trade-off**: Status line text is composed in English-with-locale-template, not a fully composable i18n surface. Locales without `menu.status.*` keys fall back to English. → **Accepted**: Status text rotates frequently and we'd rather ship working English than block on translation parity.
