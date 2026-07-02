# Curated status messages — character budget + no stack spillage

**Order 139** — filed 2026-06-30

## Problem

The tray menu's STATUS chip (the first, always-disabled menu item) sometimes
showed raw multi-line stack traces or long error strings from provisioning
failures, headless `last_event` strings, or in-VM error replies. These surfaces
are for non-technical users; raw errors are never acceptable there.

## Immediate fix (landed 2026-06-30)

**`update_status_text`** now sanitizes all strings before storing:
- First non-empty line only (strips multi-line content)
- Hard cap at 45 chars with `…` appended if exceeded

**`compose_chip_text`** now clamps `last_event` so the combined
`"{base} · {evt}"` string stays within the 45-char budget. The event suffix
is truncated with `…` if needed.

**Full error detail** always goes to the tray log (`tracing::error!`) — never
directly to the status chip.

## Character budget spec (authoritative)

| Surface | Hard max | Preferred target |
|---------|----------|-----------------|
| STATUS chip text | 45 chars | ≤30 chars |
| `last_event` suffix (after `· `) | budget-aware (see compose_chip_text) | ≤20 chars |
| Tooltip text | no limit (not visible by default) | — |

**No stack traces, no multi-line content, no raw error types ever on
the STATUS chip.**

## Status message catalog (authoritative after this packet)

| Condition | Message | Chars |
|-----------|---------|-------|
| Starting | `⚙ Setting up Fedora Linux…` | 26 |
| VM phase: Booting | `⚙ Booting…` | 10 |
| VM phase: Ready, podman up | `🟢 Ready` | 8 |
| VM phase: other | `⏳ {phase_name}` | varies |
| Wire unreachable | `🔴 Wire unreachable` | 19 |
| Provisioning failed | `🔴 Provisioning failed — Retry` | 30 |
| Dev mode (no provision) | `⚫ Dev mode — VM skipped` | 24 |

`last_event` from the headless is appended as `· {truncated_event}` when
non-empty and within budget.

## Remaining work

- [ ] Audit all `update_status_text(...)` call sites; replace any raw
      `format!("{err}")` with curated strings
- [ ] Add `litmus:no-raw-error-in-status-chip` — static grep: assert no
      `update_status_text(&format!("{:?}", ...)` or `format!("{err}")` without
      prior sanitization in the tray source
- [ ] Audit `phase.status_text()` in `ProvisionPhase` — all strings must
      be within 30 chars
- [ ] Shared spec: add the character budget table to
      `cheatsheets/ux-message-budget.md` so macOS tray can adopt the same
      constraint (it has the same STATUS chip surface)
