# The interactive login's only diagnostic renders in a terminal nobody records

`--github-login` writes an excellent refusal — it names the cause, the
consequence, and two remedies — and then sends it to an ephemeral conhost
window spawned by the tray. Nothing captures that stream. When the window
closes, the diagnosis is gone.

**This is not a missing message. It is a good message with no reader.** It
blocks the next investigator regardless of what the underlying defect turns out
to be, which is why it is filed separately from the defect that exposed it.

trace: spec:host-shell-architecture, order 759-vceg
host: yolanda-windows (Windows 11, WSL guest distro `tillandsias`), v56.9.12.2

---

## 1. How it was hit

The operator ran GitHub Login from the tray three times. Each attempt threw an
error they described only as "a nasty error". The tray log records that the
attempts happened and that sign-in resolved back to `signed-out` — and records
nothing whatsoever about why:

```
20:55:14  tray menu click menu_id=github-login action=GithubLogin
20:55:14  spawning in-VM PTY terminal=conhost intent=GithubLogin project="-"
20:55:14  opened in-VM PTY in a native terminal (wsl.exe) intent=GithubLogin
20:55:19  github sign-in state resolved from="signing-in" to="signed-out"
```

That is the complete record of a failed authentication. Reconstructing the
cause took a full session of guest forensics — podman event timelines, Vault
state inspection, and source reading — to recover a message the program had
already written correctly and thrown away.

## 2. The plumbing is honest end to end

This was checked, because "the error was swallowed" was the first and wrong
hypothesis:

- `run_podman_command_silent` (`main.rs:1576-1595`) captures stderr, trims it,
  and returns it **as** the error string; it falls back to
  `"Command exited with status N"` only when stderr is empty.
- The call sites interpolate it: `format!("in-container vault write failed: {e}")`.
- The 759-vceg refusal is a fully-formed multi-paragraph string returned as
  `Err`.

So no layer discards anything. The message reaches the process's stderr exactly
as written. **The gap is that the tray's login PTY is the only sink, and it is
not recorded anywhere.**

## 3. Why this lane is the worst one to leave unrecorded

- It is interactive, so the operator is a participant and the failure is
  witnessed but not captured.
- It cannot casually be re-run to reproduce: order 1025-a896 records that
  `gh auth login` evicts every other host's credential. "Run it again and read
  the error" costs the fleet.
- It is the lane whose entire job is minting a credential, so its failures are
  exactly the ones that strand a host.

The combination means a one-line diagnosis is destroyed at the moment it is
produced, and the only sanctioned way to see it again is an action with
fleet-wide cost.

## 4. Suggested remedy

Tee the login flow's stderr to the tray log (or to a file under the app's
`logs/` directory) in addition to the PTY. The tray already owns a log at
`%LOCALAPPDATA%\tillandsias\logs\tray.log` and already records the PTY spawn —
it should record the outcome too, not just the intent.

Any implementation must keep the **token** off disk: the login script reads it
inside the container and it never reaches host argv, env, or disk today. This
change must preserve that. Diagnostics are not secrets; the two streams need to
stay separated rather than merged wholesale.

## 5. Credit and provenance

Framing by macuahuitl-fedora, who identified that an unrecorded interactive
diagnostic is separable from whatever defect produced it and worth a row on its
own merits. The specific branch was established here: not empty stderr and not
a swallowed message, but a complete, well-written refusal that only ever
rendered in an unlogged conhost window.

related: [github-login push probe needs a checkout the guest lacks](github-login-push-probe-needs-a-checkout-the-guest-lacks-2026-09-15-yolanda-windows.md)
