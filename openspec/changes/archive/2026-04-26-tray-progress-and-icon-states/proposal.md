## Why

Today's status chip is a comma-joined fragment list (`Building Forge … · GitHub unreachable …`). Users at launch see only `Quit Tillandsias` + a disabled signature line for several seconds while infrastructure spins up — the menu reads "broken" until the chip first appears. Then individual fragments come and go without any visual sense of cumulative progress.

The user wants the chip to be **additive**: a single line whose emoji prefix grows as each subsystem comes online. At-a-glance the user sees "checklist in progress, X done so far". Plus a `🥀 Unhealthy environment` collapse state when any subsystem fails, replacing the menu's normal contents.

## What Changes

- **MODIFIED** `status_text(state, stage)` returns an additive chip:
  - Constant `✅` prefix
  - Per-completed-subsystem emoji in deterministic order: `🧭` (browser runtime) → `🕸️` (enclave) → `🛡️` (proxy) → `🧠` (inference) → `🔀` (router) → `🪞` (git mirror) → `🔨` (forge)
  - Tail action: `Building <name> …` while building, `<name> OK` for the 2-second flash after completion
  - On `Stage::NetIssue`: ` · GitHub unreachable — using cached list` appended to the same chip line
- **NEW** `Stage::Unhealthy` variant. When detected (`current_stage` finds a `BuildStatus::Failed` row with no concurrent retry), the menu collapses to `🥀 Unhealthy environment` / divider / signature / Quit. Detail of which subsystem failed lives in the log (per "single line, detail in logs" preference).
- **MODIFIED** `menu.sign_in_github` localised value: `🔑 Sign in to GitHub` → `🔑 GitHub Login` (shorter, matches user's UX wording).
- **NEW** Locale keys: `menu.unhealthy_environment`, `menu.status.verifying_environment`, `menu.status.ready_one`, `menu.build.chip_browser_runtime`, `menu.build.chip_proxy`, `menu.build.chip_router` (en/de/es).
- **NEW** Chip baseline at cold start: when nothing has built yet AND stage is Booting, chip text is `✅ Verifying environment …` so the menu reads "loading" instead of "ostensibly empty".
- Tray icon state machine refinements (10s post-click bloom→green revert, withered-on-quit lifecycle) are tracked but DEFERRED to a follow-up change to keep this one tractable.

## Capabilities

### New Capabilities
None.

### Modified Capabilities
- `tray-app`: chip is additive with deterministic emoji ordering; new `Unhealthy` stage; sign-in renamed to `🔑 GitHub Login`; cold-start chip baseline.

## Impact

- `src-tauri/src/tray_menu.rs`:
  - New helper `subsystem_emoji_and_order(image_name) -> Option<(u8, &'static str)>` mapping chip names to emoji + sort order.
  - `status_text` rewritten to additive shape (~40 lines net change). Old comma-joined fragment logic tombstoned with `@tombstone superseded:tray-progress-and-icon-states`.
  - `Stage` enum gains `Unhealthy` variant.
  - `apply_state` early-returns with the `🥀 Unhealthy environment` item when stage is Unhealthy, hiding sign-in / running stacks / project submenus.
- `src-tauri/src/main.rs::current_stage`: new precedence rule — Unhealthy beats Booting when builds have failed and no retry is in flight.
- `locales/en.toml`, `locales/de.toml`, `locales/es.toml`: new keys + sign-in rename. Locale-parity tests (`every_en_key_exists_in_es`, `every_en_key_exists_in_de`) enforce the mirroring.
- Tests in `tray_menu.rs::tests`: existing `status_text_*` tests adjusted; the new chip shape changes their assertions.
- Tray icon lifecycle (pup/green/blushing/bloom/withered + 10s revert + withered-on-quit) is NOT in this change — separate follow-up so this one can land quickly.

## Sources of Truth

- `cheatsheets/agents/openspec.md` (DRAFT) — the workflow.
- `cheatsheets/runtime/forge-container.md` (DRAFT) — runtime context.
