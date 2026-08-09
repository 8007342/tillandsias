# windows-github-login-blank-terminal — the login window is STOPPED, not slow

Filed 2026-08-09 from the **peke** Windows 11 field host running the published
`v0.4.260809.2` release (tag == `origin/main` `c3b5b633`), installed manually.
Cross-host companion to `wsl-github-login-vault-misroute-2026-08-09.md`
(packet 620-9xpg) and to F2 of `windows-first-launch-cold-start-findings-2026-08-09.md`
(packet 626).

trace: crates/tillandsias-headless/src/main.rs (`should_own_process_group`),
crates/tillandsias-windows-tray/src/{wsl_lifecycle.rs,notify_icon.rs},
packet 620-9xpg, packet 626 F2.

---

## Headline for the sibling host

**F2 is not a UX defect. It is a hard hang.**

626-F2 recorded the zero-byte `github-login-last.log` and concluded
"`--github-login` runs a multi-minute silent preflight", i.e. the operator closed
a window that was merely working quietly. That reading is wrong, and it matters:
adding progress output — the fix F2 implies — would have printed a few lines and
then hung anyway, in exactly the same place, forever.

The login process is **stopped by the kernel** (state `T`, `do_signal_stop`)
before it emits a single byte. Waiting does not help. On this host the operator
waited 15 minutes across three attempts.

**620-9xpg's "real-token login VERIFIED end-to-end" does not cover this lane.**
That verification went through `--with-token` (the BOM finding proves a
PowerShell pipe). `provider_login_exec_args` adds `--tty` **only** for
`LoginInputMode::Terminal`; the stdin-token lane never allocates a tty and so
never touches the trap. The tray-menu lane — the one still unchecked in
620-9xpg's exit criteria — is the broken one.

---

## Root cause

`crates/tillandsias-headless/src/main.rs`, first statement of `main()`:

```rust
let _ = unsafe { libc::setpgid(0, 0) };   // "so we can signal the whole group on exit"
```

The tray's login terminal runs the injected wrapper, so bash **forks**
`tillandsias-headless` rather than exec'ing it. The forked child is not a
session leader, so `setpgid(0, 0)` genuinely succeeds and moves it into a **new,
background** process group. `run_provider_login` then ends in
`podman exec --interactive --tty`, which drives the controlling terminal
(tcsetattr to raw mode, then reads stdin) from that background group — and the
kernel answers a background group's terminal access with SIGTTIN/SIGTTOU. podman
is stopped before writing anything.

`/proc` snapshot of the hang (guest, reproduced live):

```
18494  bash /tmp/v5.sh                       PGRP=18494  SID=18494  TPGID=18494  S
18495  tillandsias-headless --github-login   PGRP=18495  SID=18494  TPGID=18494  T  do_signal_stop
18839  podman exec --interactive --tty …     PGRP=18495  SID=18494  TPGID=18494  T  do_signal_stop
```

`PGRP != TPGID` is the whole bug. `PGRP == PID == 18495` can only come from
`setpgid(pid,pid)`; non-interactive bash never creates process groups.

### Why it looked intermittent

`setpgid(0, 0)` returns EPERM for a session leader, so it is a **no-op every
time the binary is exec'd directly** (`wsl.exe -d … -- tillandsias-headless …`,
systemd, a pty session leader) and only bites when something forks it. The call
was inert everywhere it was wanted and fatal everywhere it was not.

Controlled A/B on the guest, same binary, same containers:

| launch form | result |
|---|---|
| `pty.spawn(["tillandsias-headless","--github-login"])` | prompt in seconds |
| script with `exec tillandsias-headless --github-login` | prompt in seconds |
| script with `tillandsias-headless --github-login` (fork) | 0 bytes, hangs |
| the shipped wrapper (`… 2>&1 \| tee "$LOG"`) | 0 bytes, hangs |

### The pipeline is NOT the mechanism

An early hypothesis blamed `2>&1 | tee "$LOG"`. It is wrong, and the correction
is worth recording so nobody "fixes" this by de-piping the wrapper: a
non-interactive bash pipeline does **not** move children out of the foreground
process group (job control is off; every stage stays in the script's group).
The pipeline matters only because it is one of many non-`exec` forms, and any
non-`exec` form lets `setpgid` succeed. Verified after the fix: the original
tee wrapper works unchanged.

---

## Fix (this branch)

1. `main.rs` — `should_own_process_group(terminal_foreground_pgrp, our_pgrp)`:
   claim our own process group **unless** we are currently the controlling
   terminal's foreground group. Terminal-less lanes (systemd service, piped
   harness) are unaffected and still own their group.
2. `main.rs` graceful shutdown — the `kill(-getpgrp(), SIGTERM)` sweep is now
   gated on `getpgrp() == getpid()`. **This gate is load-bearing**: without it,
   a lane that deliberately stayed in the launching shell's group would SIGTERM
   that shell, escalating a blank terminal into a killed session.
3. `run_provider_login` — unconditional progress for interactive lanes
   (`--with-token` stays quiet so scripted callers keep a clean stdout). This is
   626-F2's ask, and it is still worth having: it turns a legible wait into a
   legible wait *and* pinpoints where a future failure lands.
4. Wrapper comment rewritten to record the real mechanism; the tee is kept
   deliberately (see the guard test).

### Verified on the field host

Guest binary rebuilt in-VM at `0.4.260809.2` and installed; tray relaunched
(same version, so reconciliation correctly skipped re-injection). Real console,
tray's own argv:

```
state=S pgrp=7760 tpgid=7760  bash /usr/local/lib/tillandsias/github-login.sh
state=S pgrp=7760 tpgid=7760  tillandsias-headless --github-login
state=S pgrp=7760 tpgid=7760  tee -a /root/.cache/tillandsias/github-login-last.log
state=S pgrp=7760 tpgid=7760  podman exec --interactive --tty tillandsias-github-login-7763
```

All four in the terminal's foreground group, state `S`, sitting at the token
prompt. **The operator then authenticated successfully with a real token.**

---

## Second defect, found immediately after: every PROJECT lane crashes

With login working, the operator clicked a project and got, instantly:

```
/bin/bash: -c: line 1: unexpected EOF while looking for matching `"'
[process exited with code 2 (0x00000002)]
```

This is 620-9xpg's wt.exe re-parse crash — on the lanes that fix deliberately
left behind ("wt keeps the other intents"). The project argv from `tray.log`:

```
["/bin/bash", "-lc", "export HOME=\"${HOME:-/root}\" && … && exec tillandsias-headless --cloud '8007342/tillandsias' --opencode"]
```

That is *more* quoting than the login argv that already crashed twice. Scoping
the console spawn to `GithubLogin` was too narrow.

**Fix:** `argv_survives_wt_reparse()` — wt.exe is used only when every argv
token is quote-free; anything requiring quotes takes `spawn_wsl_console`, where
argv reaches CreateProcess verbatim. Login stays pinned to the console
independently.

**Field workaround with no rebuild** (useful for any host on the published
release): launch the tray with `%LOCALAPPDATA%\Microsoft\WindowsApps` removed
from `PATH`. `Command::new("wt.exe")` then fails to resolve and
`spawn_wsl_terminal` takes its existing plain-console fallback — the same
verbatim-argv path. Confirmed on peke: `where wt.exe` returns 1 under the
filtered PATH.

---

## Open asks / follow-ups

- **Re-evaluate the forge CLI amputation.** `build_opencode_forge_args` drops
  `--interactive --tty` with the comment "so podman does not attempt to claim
  the terminal (which causes SIGTTIN/SIGTTOU / stopped T state when the parent
  is in a harness PTY)". That is this same bug, previously misattributed to the
  harness and worked around by removing the interactive TUI. With the real cause
  fixed, the TUI may be restorable.
- Other forked interactive lanes (`--claude-login`, `--codex-login`,
  `--antigravity-login`) had the identical defect and are fixed by the same
  change; none were verified end-to-end here.
- Confirms 620-9xpg's known limitation: **same-VERSION wiring changes never
  redeploy**, because `reconcile_adopted_guest` returns early on a version
  match. A wrapper-only or binary-only fix shipped without a VERSION bump will
  not reach any existing guest. A wiring content hash alongside the version
  would close it.
- Which signal actually fires (SIGTTIN vs SIGTTOU) is not isolated; both produce
  the identical `T` + `do_signal_stop` + `PGRP != TPGID` signature and share the
  one root cause, so the fix does not depend on it.

## Evidence / handoff

- Branch: `windows/sigttou-login-hang`, based on `origin/windows-next`.
- Host: peke (Windows 11 26200.8875, WSL 2.7.11.0), guest distro `tillandsias`.
- Owned files: `crates/tillandsias-headless/src/main.rs`,
  `crates/tillandsias-windows-tray/src/{wsl_lifecycle.rs,notify_icon.rs}`.
- Next action for the sibling host: this needs a **VERSION bump** to reach any
  already-provisioned guest. If the N100 host is mid-opencode-lane work, the
  project-lane crash above will hit it the moment it clicks a project on a
  wt-launched tray — the PATH workaround unblocks it without a rebuild.
