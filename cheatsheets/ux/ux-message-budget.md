---
tags: [ux, tray, status, windows, macos, curated-messages]
since: 0.3.260701
last_verified: 2026-07-01
sources:
  - plan/issues/curated-status-messages-2026-06-30.md
authority: plan-packet
status: bundled
tier: bundled
---

# UX Message Budget — Tray STATUS chip

@trace spec:windows-native-tray, spec:macos-native-tray

**Use when**: writing or reviewing any string that gets displayed in the
tray menu's STATUS chip (the first, always-disabled menu item). This is a
non-technical user surface — stack traces are never acceptable here.

## Character budget (authoritative)

| Surface | Hard cap | Preferred |
|---------|----------|-----------|
| STATUS chip (whole line) | 45 chars | ≤30 chars |
| `last_event` suffix (after `·`) | budget-aware (see below) | ≤20 chars |
| Tooltip / log detail | unlimited | — |

Characters are counted by `str::chars().count()` (Unicode scalar values, not bytes).
Emoji count as 1 scalar value each.

## The sanitizer (Windows + macOS both must implement this)

```rust
fn update_status_text(text: &str, hwnd: HWND) {
    let first = text.lines().find(|l| !l.trim().is_empty()).unwrap_or(text);
    let sanitized: String = if first.chars().count() > 45 {
        let mut s: String = first.chars().take(44).collect();
        s.push('\u{2026}');  // …
        s
    } else {
        first.to_string()
    };
    // store sanitized in MENU_STATE
}
```

## `last_event` clamping (compose_chip_text)

The headless sends a `last_event` string as a suffix. The combined
`"{base} · {event}"` must stay within 45 chars:

```rust
fn compose_chip_text(base: &str, last_event: Option<&str>) -> String {
    match last_event.map(str::trim).filter(|s| !s.is_empty()) {
        Some(evt) => {
            let evt_budget = 45usize.saturating_sub(base.chars().count() + 3);
            if evt.chars().count() > evt_budget && evt_budget > 1 {
                let short: String = evt.chars().take(evt_budget - 1).collect();
                format!("{base} \u{00B7} {short}\u{2026}")
            } else {
                format!("{base} \u{00B7} {evt}")
            }
        }
        None => base.to_string(),
    }
}
```

## Approved status message catalog

| Condition | Message | Chars |
|-----------|---------|-------|
| Setting up distro | `⚙ Setting up Fedora Linux…` | 26 |
| VM downloading rootfs | `🔵 Downloading Fedora rootfs…` | 29 |
| VM downloading agent | `🔵 Downloading Tillandsias…` | 27 |
| VM installing agent | `🔵 Installing Tillandsias…` | 26 |
| VM starting | `🔵 Starting Fedora Linux…` | 25 |
| Connecting | `🔵 Connecting…` | 14 |
| Wire unreachable | `🔴 Wire unreachable` | 19 |
| Wire recovered (internal) | `🟢 Ready` | 8 |
| VM ready, podman up | `🟢 Ready` | 8 |
| VM ready, podman not yet up | `🟡 Ready (VM may idle out)` | 26 |
| Provisioning failed | `🔴 Provisioning failed — Retry` | 30 |
| Dev mode (no provision) | `⚫ Dev mode — VM skipped` | 23 |
| Retry in progress | `🔄 Retrying provisioning…` | 24 |

## Rules

1. **Never** pass `format!("{err}")` or `format!("{:?}", err)` directly to
   `update_status_text`. Log the full error via `tracing::error!` first.
2. **Always** use a curated string from the catalog above, or a new entry
   that fits the 30-char preferred budget.
3. Multi-line strings are auto-stripped by the sanitizer, but callers must
   not rely on this — pass single-line strings.
4. Balloons/toasts are suppressed. The STATUS chip is the sole UX surface
   for live VM/wire status.

## litmus guard

`litmus:no-raw-error-in-status-chip` (pre-build, `openspec/litmus-tests/`)
enforces that `update_status_text` is never called with a raw format-error
argument in either tray crate.

## See also

- `runtime/windows-tray-dev.md`
- `ux/tray-notification-patterns.md`
