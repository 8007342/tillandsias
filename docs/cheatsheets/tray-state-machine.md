# Tray State Machine

@trace spec:simplified-tray-ux

## Overview

The tray menu is a five-stage state machine. Every stage has a fixed item layout — items are pre-built once at startup and toggled via `set_enabled` / label swap, never rebuilt. The only piece that ever rebuilds is the `Projects ▸` submenu, gated on a debounced set comparison.

Stage selection is deterministic: given the triple `(enclave_health, credential_health, remote_repo_fetch_status)` there is exactly one correct stage.

## The five stages

| Stage      | Trigger                                                                  | Visible items (top → bottom)                                                                                                       | What the user can do                                |
|------------|--------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------|-----------------------------------------------------|
| `Booting`  | One or more enclave images still building (forge / proxy / git / inference) | `Building [forge/proxy/git/inference]` / divider / `Language ▸` / version (disabled) / `— by Tlatoāni` (disabled) / `Quit Tillandsias` | Switch language. Quit. Wait.                        |
| `Ready`    | All four enclave images report ready, before credential probe completes | `Ready` (transient ≤2s) / divider / `Language ▸` / version / `— by Tlatoāni` / `Quit Tillandsias`                                  | Switch language. Quit. (Auto-advances within 2s.)   |
| `NoAuth`   | Credential probe returned `CredentialMissing` or `CredentialInvalid`    | `Sign in to GitHub` / divider / `Language ▸` / version / `— by Tlatoāni` / `Quit Tillandsias`                                      | Sign in. Switch language. Quit.                     |
| `Authed`   | Credential probe returned `Authenticated` (or local-only mode)          | `Projects ▸` / divider / `Language ▸` / version / `— by Tlatoāni` / `Quit Tillandsias`                                             | Launch a project. Open maintenance terminal. Quit.  |
| `NetIssue` | Probe returned `GithubUnreachable` and a cached project list exists      | `Sign in to GitHub` / `(GitHub unreachable, using cached projects)` / `Projects ▸` / `Language ▸` / version / `— by Tlatoāni` / `Quit Tillandsias` | Use cached projects. Retry sign-in. Quit.           |

`Language ▸` and `Quit Tillandsias` are present and enabled in every stage. The version line and `— by Tlatoāni` are present in every stage and always disabled (visual signature only).

## CredentialHealth → stage map

`src-tauri/src/github_health.rs` returns one of four variants. Each maps to exactly one stage:

| `CredentialHealth`       | HTTP signal                          | Stage      | UI consequence                                            |
|--------------------------|--------------------------------------|------------|-----------------------------------------------------------|
| `Authenticated`          | 200 from `GET /user`                 | `Authed`   | `Projects ▸` becomes the primary action.                  |
| `CredentialMissing`      | No token in OS keyring               | `NoAuth`   | `Sign in to GitHub` is the only action.                   |
| `CredentialInvalid`      | 401 / 403 from GitHub                | `NoAuth`   | Same as missing — re-auth flow.                           |
| `GithubUnreachable`      | DNS / timeout / 5xx / 429 / keyring D-Bus down | `NetIssue` | Sign-in offered, cached `Projects ▸` still works.         |

Probe budget: 10 seconds. A timeout is **always** classified as `GithubUnreachable` — never as `CredentialInvalid`. The tray must not fail closed on a slow probe.

## Allowed stage transitions

```
                    ┌──────────────────────┐
   start  ─────────►│      Booting         │
                    └──────────┬───────────┘
                               │ all 4 images ready
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

## Common debugging questions

### Why does "Sign in to GitHub" keep showing after I signed in?

Run `tillandsias --log-secrets-management` and look for the most recent `GitHub credential health probe complete` event. Cross-reference its `health = ...` field against the table above:

- `health = credential-missing` — the keyring write didn't land. Check for `NoStorageAccess` errors (headless Linux, locked keyring).
- `health = credential-invalid` — the token is expired / revoked. Re-run `tillandsias --github-login`.
- `health = unreachable (...)` — probe timed out or got a 5xx. You're in `NetIssue`, not `NoAuth`. Sign-in still appears, but `Projects ▸` is also there.

### How do I tell `GithubUnreachable` from `CredentialInvalid`?

Look at the menu, not the logs:

| You see                                             | Stage      | Probe verdict        |
|-----------------------------------------------------|------------|----------------------|
| `Sign in to GitHub` only                            | `NoAuth`   | Missing or Invalid   |
| `Sign in to GitHub` + `(GitHub unreachable, …)` + `Projects ▸` | `NetIssue` | Unreachable          |

If the banner item `(GitHub unreachable, using cached projects)` is visible, the probe reached an unreachable / transient verdict. If not, the token itself is the problem. The banner is the discriminator.

### Why is Quit slow?

Quit must service within 5 seconds even mid-image-build. The event loop uses `biased; tokio::select!` so Quit takes priority, and long-running spawns hold a `CancellationToken` the Quit handler aborts. If Quit is taking longer:

1. Confirm you're on a release that landed `simplified-tray-ux` (`tillandsias --version`).
2. Look in the log for `shutdown_all` — it should start within 1s when idle, within 5s during a build.
3. If you see `shutdown_all` start but the process hangs after, the bottleneck is `podman rm -f` on the enclave network or a forge container — not the tray.

### Why doesn't the menu update when an image finishes building?

Stage transitions toggle `set_enabled` on pre-built items. If items are visibly stuck:

- Check the log for `Stage flip` or label-swap events — confirm they're firing.
- Tauri 2 doesn't expose `set_visible` on every native menu platform; the tray emulates hide-by-disable + label-update. On platforms with quirky menu redraw (some GTK themes), the item may need a parent-menu re-open to repaint.
- If `rebuild_menu()` is being called for a stage flip (it shouldn't be), that's a bug — file under `simplified-tray-ux`.

### Why is the project list flickering?

Projects submenu IS rebuilt — but only when `(local_set, remote_set, include_remote)` actually changes, debounced to 100ms. If you see flicker, the scanner is emitting non-idempotent events (same set, different ordering) or the debounce is bypassed.

### What if the keyring D-Bus is down on Linux?

`probe_inner` catches this and returns `GithubUnreachable { reason: "keyring unavailable: ..." }` — you land in `NetIssue`, not `NoAuth`. This is intentional: a restarting Secret Service daemon should NOT force a sign-in dance.

## Pre-built menu items, never rebuilt

| Item                    | Built at      | Updated by                                  |
|-------------------------|---------------|---------------------------------------------|
| `Building [...]` label  | `setup`       | label swap as each image reports ready      |
| `Ready` (transient)     | `setup`       | shown for ≤2s on Ready stage, then hidden   |
| `Sign in to GitHub`     | `setup`       | `set_enabled` toggle                        |
| `Projects ▸` submenu    | `setup` (root) | submenu **content** rebuilt on project-set change only |
| `(GitHub unreachable…)` | `setup`       | `set_enabled` toggle (NetIssue only)        |
| `Language ▸`            | `setup`       | always enabled                              |
| version line            | `setup`       | never changes during a process lifetime     |
| `— by Tlatoāni`         | `setup`       | never changes                               |
| `Quit Tillandsias`      | `setup`       | always enabled                              |

The static portion of the menu is never `rebuild_menu()`'d. Only the project list is, and only on a real set change.

## Related

**Specs:**
- `openspec/changes/simplified-tray-ux/proposal.md` — full menu shape rationale
- `openspec/changes/simplified-tray-ux/specs/tray-app/spec.md` — requirements + scenarios
- Supersedes: `tray-responsiveness-and-startup-gating`

**Source files:**
- `src-tauri/src/github_health.rs` — `CredentialHealth` enum + `probe()` (10s budget)
- `src-tauri/src/menu.rs` — pre-built items, stage toggles
- `src-tauri/src/event_loop.rs` — `biased; tokio::select!`, cancel tokens, Quit priority
- `src-tauri/src/main.rs` — `update_menu_state()` calls (toggles, not rebuilds)

**Cheatsheets:**
- `docs/cheatsheets/secrets-management.md` — keyring backends, headless-Linux caveat
- `docs/cheatsheets/token-rotation.md` — what happens after `Authed`
- `docs/cheatsheets/logging-levels.md` — `--log-secrets-management` and friends
