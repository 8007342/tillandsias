# Ultra-Minimalistic Tray UX — Most Important Notification in Status Line

**Date:** 2026-07-09
**Classification:** ux+design
**Host:** any
**Observed by:** linux-big-pickle-20260709

## Observation

The tray status line currently shows the VM phase or a generic state string.
Multiple events can happen in parallel (container launches, git operations, vault
bootstrap) but only the latest phase string is displayed. There is no mechanism to
show the "most important thing that just happened."

From order 149 (curated-status-messages), the hard cap is 45 chars, and stack
spillage is banned. But the curation is phase-oriented, not event-oriented.

The vision is: a single status line that reduces the latest N log entries to the
single most important one, shown until seen or superseded by a more important event.

## Impact

The tray is the primary UX surface, but it shows phase state rather than user-
relevant activity. Users don't know if their `git push` succeeded, if the vault
is healthy, or if a build failed without opening a terminal.

## Required Agents

At least 3 agents must verify this packet as complete:
- `claude-opus-highthink`
- `opencode-bigpickle`
- `antigravity-gemini`

## Deliverable

1. **State-vs-Event Model**: Define when the status line shows the current phase
   (steady state) vs. the most recent event (transition/activity). The steady
   state is the fallback; events are shown transiently with a TTL.

2. **Priority Ordering**: All possible status messages ranked by importance.
   Error > Auth failure > Push success > Commit > Clone > Build > Health ok.
   The highest-priority event in the last 20-60s wins the status line.

3. **37-Char Event Messages**: For each event type in the event taxonomy (order
   event-push-architecture), a 37-char-max template. E.g.:
   - `🔴 Auth failed` (13 chars)
   - `⬆️ Pushed 3 commits` (19 chars)
   - `✅ Cloned owner/repo` (22 chars)
   - `🏗️ Built forge image` (20 chars)

4. **Sticky-Until-Seen**: Once shown, an event stays until a higher-priority
   event arrives OR the user opens the tray menu (ack). This prevents events
   from being missed during brief glances.

5. **Screen Reader / Accessibility**: The status line must be accessible as a
   live region for screen readers. Events are announced.

6. **Spec/Implementation Plan**: Map to existing tray code paths (Linux headless,
   Windows tray, macOS tray) with minimal changes to each.
