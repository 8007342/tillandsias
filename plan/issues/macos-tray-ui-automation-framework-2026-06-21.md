# macOS Tray UI-Automation Framework (autonomous GUI smoke) — 2026-06-21

**Filed:** 2026-06-21T02:10Z (operator-attended interactive session, macOS host)
**Origin:** Operator request — "investigate if there is a framework we could
install to let you automate these [interactive tray] tests in the future."
**Trace:** `spec:macos-native-tray`, `plan/issues/macos-build-findings-*.md`
(skill blind spots), `memory:macos-build-skill-blind-spots`

## Problem

`/build-macos-tray` autonomous smoke (`SECTION_KIND=ok`) only verifies codesign
+ diagnose-schema + 3s-alive + clean-SIGTERM. It is **blind to the GUI**: it
cannot confirm the tray icon renders, the menu items are correct, auth-gating
works, or an interactive flow (GitHub login) actually presents a usable surface.
That blindness is exactly why the blank-login defect
(`plan/issues/macos-tray-github-login-blank-terminal-2026-06-21.md`) survived
multiple green autonomous builds — a human had to click the menu to find it.

## Finding: no install needed — macOS built-ins are sufficient

This session drove the *entire* interactive smoke (enumerate menu, click items,
click GitHub Login, read the attach terminal) from the shell using only
built-in macOS tooling. The reusable primitives, in priority order:

1. **Accessibility API via `osascript`/System Events (AUTHORITATIVE).**
   Deterministically enumerates and clicks the tray's `NSStatusItem` menu —
   no pixel-reading, locale-independent, immune to occlusion. This is what
   revealed the real menu tree and the logged-out/auth-gated state.
   - Requires one-time **Accessibility permission** for the controlling
     process (System Settings → Privacy & Security → Accessibility). Persists.
2. **`screencapture` + `sips` (SUPPLEMENTARY).** Pixel capture of a menu-bar
   region for a visual artifact. Caveat observed live: a macOS **notification
   banner occluded** the tray icon in the screenshot — so pixel capture is
   evidence, not ground truth. Prefer AX for assertions.
3. **`screen -X hardcopy [-h]` (TERMINAL FLOWS).** Dumps a PTY/`screen`
   attach surface (the GitHub-login terminal) to text so a finding can assert
   content (or its absence — a 130-byte all-blank dump *was* the bug signal).
   Caveat: races the Terminal/`screen` spawn and misses fast-exiting children;
   for those, hold the PTY open or read `history of tab` via AppleScript.

### Why not a heavier framework

- **XCUITest** targets app bundles with a test host; the tray is an
  `LSUIElement` status-bar agent driven over vsock — XCUITest adds a large
  harness for little gain over AX, and needs Xcode project scaffolding.
- **`cliclick` (brew)** gives scripted mouse clicks but is *pixel-coordinate*
  based (fragile vs. menu-bar reflow / notch / multi-display) — strictly worse
  than AX element-targeting. Keep as an optional fallback only.
- Net: **adopt the built-in AX harness; do not install third-party tooling.**

## Deliverable (prototyped this session)

`scripts/macos-tray-ax-smoke.sh` — subcommands `icon-present`, `menu`,
`assert-item <substr>`, `click <substr>`, `screenshot <out>`, `pty-dump <out>`.
Each is falsifiable (exit 0/non-zero) and fails loud if the tray process is
absent (silence must never read as success). Used end-to-end here to find and
re-test the blank-login defect.

## Reduction — proposed packets (verifiable closure)

- `tray-ax/harness-litmus` — pin the harness output grammar with a litmus test
  (`icon-present` → `ok:status-item-present`; `assert-item` → `ok:item-present:<x>`).
  Closure: `run-litmus-test.sh` green.
- `tray-ax/skill-integration` — call the harness from `/build-macos-tray` after
  install-locally: assert `icon-present`, enumerate `menu`, and assert the
  expected logged-out item set. Closure: a new `SECTION_KIND=gui-ok` (or
  `gui-regressed`) line in `macos-build-findings-<DATE>.md`, raising the
  autonomous bar from "process alive" to "menu correct".
- `tray-ax/accessibility-grant-preflight` — detect missing Accessibility
  permission and emit a clear `skip:no-accessibility-grant` rather than a
  confusing AppleScript `-1719`. Closure: probe returns the structured verdict.
- `tray-ax/headless-session-note` — document that AX + `screencapture` need an
  **active GUI login session** (won't work over pure SSH/headless launchd with
  no Aqua session); record the constraint so the autonomous macOS builder runs
  in a logged-in session. Closure: note in the skill + methodology host matrix.

## Bar-raise note (Tlatoāni-gated)

Raising the macOS smoke bar from "alive" to "GUI-verified" is a scan-bar
expansion. Per `methodology/convergence.yaml` → `bar_raise_governance`, this
packet *proposes* it; enabling it as a standing gate is an explicit
operator-approved decision. (Operator initiated this investigation 2026-06-21,
which covers the proposal; confirm scope before wiring it as a blocking gate.)
