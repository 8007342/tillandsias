# Forge Claude harness login URL smears vs Codex/Antigravity graceful device flows

- **Date:** 2026-07-23
- **Class:** enhancement + bug — forge harness auth UX (device-flow parity) with a macOS PTY-fidelity root cause
- **Area:** forge harness auth UX (Claude login presentation) + macOS PTY/terminal-attach (Terminal.app `screen` → vsock → guest PTY → container PTY)
- **Severity:** P2 — the operator cannot reliably copy the Claude auth URL from the forge terminal, so the Claude harness cannot be logged into the forge (especially on re-auth). Codex and Antigravity log in cleanly in the SAME terminal. Usability block on one of three harnesses; not a data/security defect.
- **Owner host:** macOS (osx-next) for the terminal substrate; the auth-presentation half is cross-cutting (shared `provider-device-auth.sh` + `entrypoint-forge-claude.sh`).
- **Governance:** changes Claude login presentation (auth UX) AND terminal-attach winsize behavior → operator (Tlatoāni) sign-off before implementation.
- **Discovered by:** operator report during a live attended macOS forge session.

## Symptom

Launching the **Claude** harness in the forge, the login rendered its auth URL badly: "hyperlink style, the URL text present a few times." The operator copied the `https://…`-through-token once and logged in, but on **re-auth** the URL was no longer copyable — "Claude just spills the auth token." The pasted evidence shows the **same OAuth URL redrawn many times, each copy at a shifted offset**, interleaved with the login box affordances `(c to copy)` / `(Copied!)` / `Press Ctrl-C again to exit`. In the SAME forge terminal, **Codex** prints a plain clickable device URL + code, and **Antigravity** prints a graceful device URL + code.

The forge terminal is Terminal.app → `screen /dev/ttysNNN` → vsock bridge → guest → `podman -it` into the forge container.

## Root cause: TUI redraw smear from a terminal-WIDTH / cursor mismatch (OSC 8 ruled out)

The signature (same URL redrawn at shifted rows, interleaved with the copy-box affordances) is an **interactive-TUI re-render smear**, not escape-wrapped OSC 8 hyperlinks. Claude Code's login is an interactive "copy this URL" box that redraws on each keypress/state change; when its assumed terminal width ≠ Terminal.app's real width, its manual wraps + cursor moves land on shifted rows → the URL smears down the screen instead of overwriting in place.

The width mismatch is structural:
- Host + guest PTY are seeded at a hardcoded **24×80**: `crates/tillandsias-macos-tray/src/action_host.rs:1191` (`UnixPtyMaster::open(24, 80)`) and `:1194` (`launch_spec(&intent, …, 24, 80)`).
- The forge child is `podman run -it … entrypoint-forge-claude.sh` (`crates/tillandsias-headless/src/main.rs:10687` `spec.interactive().tty()`; entrypoint map `:10104-10127`). With `-t` the CONTAINER PTY is sized from podman's stdin tty (= the guest PTY slave) at start = **80 cols**. Claude's login box renders at 80 cols while Terminal.app is wider → smear.
- The only env delivered to the guest PTY child is `TERM=xterm-256color` (`crates/tillandsias-host-shell/src/pty/mod.rs:249`); no `COLUMNS`/`LINES`, no `FORCE_HYPERLINK`/`NO_COLOR` — width comes purely from the PTY winsize, so fixing the winsize IS the lever.

### Does the resize reach the container PTY? (refines commit 8292e198)

It CAN, but the width is still wrong at first render:
- The guest applies `TIOCSWINSZ` to the guest PTY master (`crates/tillandsias-headless/src/pty_handler.rs:334`, `set_winsize` `:455-466`) → SIGWINCH to the guest PTY foreground pgrp.
- The forge child is `podman … -it` (`main.rs:10687`), and podman `-it` forwards SIGWINCH-driven resizes into the container PTY via conmon — so the resize does NOT architecturally stop at the guest PTY.
- BUT the container is 80 cols when Claude first draws because: (1) the **24×80 seed** (`action_host.rs:1191/1194`) is the size at first render; (2) it is UNVERIFIED that `screen /dev/ttysNNN` pushes Terminal.app's real winsize onto the host slave (`macos-tray-pty-window-resize-not-forwarded-2026-07-23.md:37`); (3) the host watcher (commit `8292e198`, `action_host.rs` run_pty_attach) polls every 400ms and only fires on a change from `(24,80)`, leaving a startup window at 80 cols. **So `8292e198` forwards resize but does not eliminate the first-render 80-col window — this packet extends it.**

## Device-flow parity gap (why Codex/Antigravity are fine, Claude is not)

- **Codex = true device-code flow:** `images/default/codex-device-auth.sh:24-29` probes `codex login --help` for `--device-auth`, refuses any browser/paste fallback, then runs `codex login --device-auth` → one STATIC verification URI + short code. Launched via `entrypoint-forge-codex.sh:162,168`.
- **Antigravity = device-URL flow:** `images/default/provider-device-auth.sh:35-59` runs `agy auth login`, which auto-detects headless and prints a STATIC device URL + code (comment `:36-37`). Exec'd at `entrypoint-forge-antigravity.sh:127-141`.
- **Claude = NOT a device-code flow:** `provider-device-auth.sh:19-33` runs interactive `claude auth login --claudeai` (the OAuth box); in-forge re-auth is Claude Code's own interactive TUI login, exec'd at `entrypoint-forge-claude.sh:139` (note: `--dangerously-skip-permissions`, expected forge YOLO). Prior audit `provider-device-auth-capability-blocker-2026-07-14.md:11-18` records Claude exposes "none" compliant device flow, and the launcher help text MISLABELS `--claudeai` as a "device flow" (`main.rs:885`) while Codex `--device-auth` is correctly labeled (`main.rs:888`).

The others emit ONE static URL (nothing to redraw), so they survive the same terminal chain; only Claude's interactive redraw box smears.

## Impact

The operator cannot reliably copy the Claude auth URL from the forge terminal → the Claude harness cannot be logged into the forge, and re-auth is effectively broken. Because the same width mismatch corrupts ANY interactive in-container TUI (see the OpenCode prior art), it is broader than login alone.

## Recommended fix (ranked)

Operator principle: Claude's forge login should present like Codex/Antigravity — a plain, static, copyable URL — or skip interactive login entirely.

### PRIMARY-A (most robust — eliminates the box entirely): pre-authenticate via a long-lived token
Per Claude Code docs (headless/CI path): the operator runs `claude setup-token` ONCE on the Mac (prints a ~1-year OAuth token; needs Pro/Max/Team/Enterprise), and the forge launches Claude with **`CLAUDE_CODE_OAUTH_TOKEN=<token>`** in its env → no login flow, no redraw box, no browser. Wire it through the EXISTING forge-harness-auth-via-Vault architecture (plan order 112; `codex-oauth-vault.sh` already does Codex Vault-injection): store the Claude token in Vault (parallel to `secret/github/token`) and inject `CLAUDE_CODE_OAUTH_TOKEN` into the Claude launch — mirror `codex-oauth-vault.sh`.

### PRIMARY-B (if an interactive login must happen): plain static URL + no browser
- Set **`BROWSER=/dev/null`** in the Claude harness env (no browser spawn in the headless VM); it then falls through to Claude Code's automatic device-code-like fallback (redirect can't reach the VM localhost → the browser shows a login CODE to paste at "Paste code here if prompted"). NOTE: `BROWSER=/dev/null` alone does NOT remove the redraw box.
- Re-verify the CURRENTLY installed Claude CLI for a plain/device presentation (the 2026-07-14 "none" audit must be re-checked against the live version — Claude ships fast). If a plain mode exists, route `provider-device-auth.sh:27-33` (claude case) + `entrypoint-forge-claude.sh:126-139` through it exactly like `codex-device-auth.sh:24-29`. If not, WRAP the login so the forge captures the authorize URL and re-prints it once as a plain static line.

### SECONDARY (fixes EVERY in-forge TUI, not just login): make the container PTY width match Terminal.app
- Replace the hardcoded 24×80 seed (`action_host.rs:1191` and `:1194`) with Terminal.app's real geometry, OR emit an immediate `PtyResize` the moment `screen` establishes the winsize rather than waiting for the 400ms only-on-change poll (`action_host.rs` run_pty_attach watcher, commit `8292e198`).
- Verify `screen /dev/ttysNNN` pushes Terminal.app's winsize onto the host slave (the unverified assumption in `macos-tray-pty-window-resize-not-forwarded-2026-07-23.md:37`).
- Confirm the guest→container hop end-to-end (guest `TIOCSWINSZ` `pty_handler.rs:334` → SIGWINCH → `podman -it` forward → container PTY).

## Cross-references

- `plan/issues/research-auth-flow-state-machines-2026-07-23.md` — the login-flow FSM; per-provider device-vs-interactive divergence is a concrete instance of that.
- `plan/issues/macos-tray-scroll-arrowkey-spill-during-build-2026-07-23.md`, `plan/issues/macos-tray-pty-window-resize-not-forwarded-2026-07-23.md` — the two PTY-attach fidelity packets; this is the third face (state must reach the CONTAINER PTY).
- `plan/issues/provider-device-auth-capability-blocker-2026-07-14.md` — prior audit: Claude exposes no compliant device flow; operator amendment = plain URI + short code, no hyperlinks/paste.
- `plan/issues/macos-opencode-pty-resize-not-propagated-2026-07-12.md` — same width-mismatch symptom for the OpenCode TUI (the SECONDARY fix helps every harness).
- Commit `8292e198` (feat(macos-tray): forward terminal resize to the guest PTY) — landed the host→guest winsize watcher but did not close the first-render 80-col window; this packet extends it into the container PTY.
