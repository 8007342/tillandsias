# macOS Tray — GitHub Login opens a BLANK terminal (interactive smoke finding) — 2026-06-21

**Filed:** 2026-06-21T01:35Z (operator-attended interactive session on macOS host)
**Host:** Darwin (Apple Silicon), `osx-next @ d273daff`, built `v0.3.260620.7`
**Trace:** `spec:macos-native-tray.lifecycle.terminal-attach@v1`, `spec:gh-auth-script`,
`plan/issues/github-e2e-lifecycle-interactive-2026-06-20.md` (P2 login UX glitches)

## Summary

On the macOS tray, clicking **🔑 GitHub Login** opens a Terminal.app tab running
`screen <pty-slave>`, but the surface renders **completely blank** (a gray
ncurses surface with no content) — no `gh auth login` prompt, no device code, no
error. The login is therefore un-completable from the tray. Operator confirmed
the blank surface live; a `screen -X hardcopy` dump of the PTY buffer was also
empty.

This is the macOS instance of the known-but-unenumerated P2 login UX glitch.

## What we verified (deterministic, via Accessibility API)

The tray itself is otherwise healthy:

- Build green: `cargo build --release -p tillandsias-macos-tray` 17.9s, ad-hoc
  codesign valid, bundle + tarball produced (sha256
  `32b62bc475efefb30bf5eddb7a85045e4b9c32bdec7c9e9b4dbb42ab5888ef1c`).
- Status item renders (AX `description = "status menu"`).
- Logged-out menu is exactly: `🟢 Ready · tillandsias-in-vm` / `🔑 GitHub Login`
  / `v0.3.260620.7 — By Tlatoāni` / `❌ Quit Tillandsias`. Auth-gating is
  correct: project submenus are hidden while logged out. (Confirms the parity
  audit #2 logged-out collapse.)
- VM is up and the control-wire is reachable (status chip `🟢 Ready`, not
  `🔴 Wire unreachable`); the tray's `GithubLoginStatusRequest` poll returns
  `logged_in=false` because the VM Vault holds no GitHub token yet. This is
  **expected** — Tillandsias keeps its own credential set in the VM Vault,
  independent of the host's `gh auth` (operator-confirmed; not a bug).

## Click trace (tray stderr, `RUST_LOG=trace`)

```
click: id=github-login action=GithubLogin
GitHub login: spawning attach worker (project=None)
GitHub login: PTY attached at /dev/ttys001
```

Terminal.app became frontmost with a `screen /dev/ttys001` session — but blank.

## PRIMARY ROOT CAUSE — CONFIRMED: macOS PTY-attach EIO teardown race

**This breaks EVERY tray PTY attach on macOS (Open Shell, GitHub Login, agent
attach) — not just login.** Established by bisection this session: replacing the
login intent with a plain interactive `/bin/bash -l` (the `Shell` intent)
*also* flashes a prompt and dies instantly with `[screen is terminating]`.

Mechanism:

1. The attach worker creates a host PTY via `UnixPtyMaster::open`
   (`crates/tillandsias-host-shell/src/pty/unix.rs`), which **retains** the
   slave fd, and returns `slave_path`.
2. `run_pty_attach` (`crates/tillandsias-macos-tray/src/action_host.rs:1006-1011`)
   calls `pump_io(session, master)`. `pump_io`'s first line
   (`crates/tillandsias-host-shell/src/pty/mod.rs:426`) does `master.split()`,
   which **drops the retained slave fd** (unix.rs:226-230: "self._slave drops
   here — the slave fd CLOSES").
3. `screen` only re-opens the slave (by path) *after* `run_pty_attach` returns
   and the main thread spawns Terminal.app. In that handoff window there are
   **zero open slaves**.
4. On **macOS**, `read()` on a PTY master with no slave open returns **EIO
   immediately** (Linux blocks instead). `pump_io`'s input task
   (`pty/mod.rs:437-438`) treats any error as terminal-closed:
   `Ok(0) | Err(_) => break`. It breaks, the output task's
   `input_task.abort()` fires (mod.rs:462), the session closes, and the guest
   child is SIGHUP'd → the shell/login dies before `screen` ever attaches.

This is why the surface is blank/flashes and why it's **macOS-specific** —
Linux-tested code never hit the EIO path.

### Fix (primary) — keep a slave open across the attach handoff

Option A (macOS-local, lowest blast radius): in `run_pty_attach`, after getting
`slave_path`, open an independent keepalive slave fd
(`OpenOptions::new().read(true).write(true).open(&slave_path)`) and hold it
until just after `spawn_terminal_pty_attach` runs (e.g. drop it ~3-5s later or
when the first guest output arrives), so the master never sees zero slaves.

Option B (shared, more correct): make `pump_io`'s input task tolerate a
pre-attach `EIO` (retry with backoff until the first slave attaches) instead of
`Err(_) => break`. Touches Linux too — needs a litmus test to confirm no
regression.

**IMPLEMENTED (operator chose Option B), 2026-06-21:**
`crates/tillandsias-host-shell/src/pty/mod.rs` — both the input (read) and
output (write) tasks now tolerate a pre-attach error until the first successful
read/write (a shared `attached` `AtomicBool`), bounded by `ATTACH_GRACE` (10s)
with `EIO_BACKOFF` (50ms) retries; afterwards an error is a real close and tears
down immediately. Linux blocks pre-attach so its behavior is unchanged. Added
regression test `pump_input_tolerates_pre_attach_eio` (a master that returns
`EIO` 3× before a byte must still forward the byte). `cargo test -p
tillandsias-host-shell --lib pty::` → **17/17 pass**. The GithubLogin argv is
also corrected to `/bin/bash -lc "exec tillandsias-headless --github-login"`
(login shell rebuilds PATH; correct guest binary name; orchestrated flow).

Closure (verifiable): with the fix, clicking GitHub Login (or any attach) holds
the `screen` surface open; `scripts/macos-tray-ax-smoke.sh pty-dump` returns
non-empty content; a plain-shell probe shows a usable prompt that does NOT
self-terminate. **End-to-end re-test pending operator click this session.**

---

## SECONDARY: login command parity (correct, but masked by the EIO bug above)

The macOS/Windows shared PTY path and the Linux native tray launch GitHub login
**differently**, and only the Linux path is correct:

- **Linux native (golden).** `handle_github_login`
  (`crates/tillandsias-headless/src/tray/mod.rs:1999-2007`) launches a terminal
  running the orchestrated subcommand **`tillandsias --github-login`**.
  `run_github_login` (`crates/tillandsias-headless/src/main.rs:3890`) runs
  `gh auth login --hostname github.com --git-protocol https --with-token`
  **inside the `git` service container** (which ships `gh` + `vault-cli`,
  dual-homed onto `tillandsias-egress` to reach api.github.com), reads a pasted
  PAT via a cooked-mode shell `read` from `/dev/tty`, and writes the token to
  Vault `secret/github/token` entirely in-container — the host never sees it.
  This is the "vault container" flow the operator described.

- **macOS/Windows (broken).** `launch_spec` for `PtyIntent::GithubLogin` with
  `project=None` (`crates/tillandsias-host-shell/src/pty/mod.rs:141-142`,
  `160-161`) runs **bare `["gh","auth","login"]` directly in the VM rootfs** —
  not the git/vault container, not the orchestrated subcommand. `gh` is not
  provisioned in the bare VM rootfs (it lives in the container images), so the
  exec produces no usable output → the `screen`/Terminal surface renders blank.
  It never reaches the container, never touches Vault.

Operator direction (2026-06-21): the login must run **in the vault/git
container, not the forge and not the bare VM**, and this is how the **Linux
native build already works** — macOS (and Windows) must match it.

## Fix — point the shared login intent at the orchestrated subcommand

In `crates/tillandsias-host-shell/src/pty/mod.rs`, change the
`PtyIntent::GithubLogin` inner argv from:

```rust
vec!["gh", "auth", "login"]                  // bare, in VM rootfs — BLANK
```

to the orchestrated subcommand the Linux tray already uses:

```rust
vec!["tillandsias", "--github-login"]        // runs the git/vault-container flow + Vault write
```

The in-VM headless binary is `tillandsias`, so `--github-login` runs the *same*
`run_github_login` path as Linux. This is the minimal cross-platform parity fix
and benefits Windows simultaneously (both consume this shared `launch_spec`).

### Caveats to verify during implementation

- `run_github_login` calls `require_desktop_user_session("tillandsias
  --github-login")` (`main.rs:3891`). Confirm this gate is satisfied (or
  appropriately bypassed) when invoked through the tray PTY inside the VM,
  rather than from a host desktop session — it may need adjustment.
- The flow is **paste-a-PAT**, not a device-code/web flow; the terminal prompts
  "Paste your GitHub authentication token". UX note: ensure the macOS Terminal
  attach renders that prompt (the whole point — it was blank before).

## Reduction — proposed packets (verifiable closure)

- `macos-login/wire-orchestrated-subcommand` — change the shared `launch_spec`
  GithubLogin argv to `tillandsias --github-login`; rebuild macOS tray; click
  login. Closure: the Terminal surface shows the
  `Paste your GitHub authentication token` prompt (non-blank), verified via
  `screen -X hardcopy`.
- `macos-login/desktop-session-gate` — confirm/adjust
  `require_desktop_user_session` for the in-VM tray-PTY invocation. Closure:
  the subcommand reaches the paste prompt without erroring on the session gate.
- `macos-login/poll-flip` — after a successful paste-token login, assert the
  tray `GithubLoginStatusRequest` poll flips logged-out → logged-in and reveals
  the project submenus. Closure: AX menu enumeration shows the authenticated
  8-item body and no `github-login` leaf.

## How this was found (reusable method — see automation packet)

Driven entirely from the shell via the macOS Accessibility API
(`osascript`/System Events) to enumerate + click tray menu items, plus
`screencapture`/`sips` and `screen -X hardcopy` to read surfaces. This is the
seed of an autonomous macOS GUI-smoke harness — see
`plan/issues/macos-tray-ui-automation-framework-2026-06-21.md`.
