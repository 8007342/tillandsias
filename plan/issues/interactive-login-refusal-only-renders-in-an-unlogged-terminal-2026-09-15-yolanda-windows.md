# WITHDRAWN: the login refusal IS logged — with a narrower residue that is not

**This row's original premise was false and is withdrawn.** It claimed the
`--github-login` refusal renders only in an ephemeral conhost window that
nothing records, and that the tray has no sink for it.

The Windows tray tees the login's full output to a file. From
the bash wrapper `WslLifecycle::inject_bootstrap_logic` injects into the guest
(`crates/tillandsias-windows-tray/src/wsl_lifecycle.rs`, raw-string literal
`github_login_wrapper`) — see the register note below:

```sh
LOG="$LOG_DIR/github-login-last.log"
...
printf '\n[tillandsias] github-login exited %s; full output saved to %s\n' "$rc" "$LOG"
```

Confirmed by the operator's own run on 2026-09-15T14:34 local:
`/root/.cache/tillandsias/github-login-last.log`, 1263 bytes, containing the
complete progress trace, the token prompt, the git-identity block and the entire
759-vceg refusal. The exit line names the path on the way out.

trace: order 759-vceg
host: yolanda-windows, v56.9.12.2

---

## Where the tee actually lives — register matters more than line numbers

The sink is **injected shell, not Rust**. In
`crates/tillandsias-windows-tray/src/wsl_lifecycle.rs` the enclosing symbol is
`WslLifecycle::inject_bootstrap_logic` (fn at :1530), and the `LOG=` line is
inside a Rust raw-string literal `github_login_wrapper` (`r#"…"#`, :1633-1648)
holding a bash script that the function writes into the guest:

```sh
LOG="$LOG_DIR/github-login-last.log"
/usr/local/bin/tillandsias-headless --github-login 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}
```

The compiler never sees that as code. An implementer told to edit "the function
that writes the log" would read Rust and not find it. Line numbers move; the
register does not. Correction raised by yoga-silverblue, verified here.

## This sink has already failed once BY EXISTING AND BEING EMPTY

A doc comment immediately above the literal (:1620-1632) records that a **0-byte
`github-login-last.log`** was the `v0.4.260809.2` field failure — fixed by
`should_own_process_group` in `tillandsias-headless` `main()`, which keeps an
interactive lane in the launching shell's foreground process group. The comment
also warns explicitly **not** to "fix" a recurrence by de-piping the wrapper:
piping is not the mechanism, and dropping the `tee` only costs the log that
makes the next failure legible.

**That is this row's own class, one layer down.** An empty sink and a silent
lane are indistinguishable from the reading side — the file exists, it is
readable, it is well-formed, and it contains nothing. Anyone reading this log to
diagnose a login must **check its SIZE before concluding anything from its
contents**.

Not a live defect here: the operator's 2026-09-15T14:34 run produced 1263 bytes
with the full refusal in it, so the sink is working on this build. Recorded
because the next reader of this row will be reading that file under exactly the
conditions where a 0-byte result is plausible. Raised by yoga-silverblue.

## How the wrong claim was reached, since that is the reusable part
The Windows-side tray log (`%LOCALAPPDATA%\tillandsias\logs\tray.log`) records
the login being spawned and the sign-in state flipping back to `signed-out`, and
records nothing about the outcome:

```
20:55:14  tray menu click menu_id=github-login action=GithubLogin
20:55:14  spawning in-VM PTY terminal=conhost intent=GithubLogin project="-"
20:55:19  github sign-in state resolved from="signing-in" to="signed-out"
```

That is a true observation about tray.log. The error was concluding from it that
the output was unrecorded ANYWHERE — generalising the absence in the log I
checked into an absence in every log. The actual sink is a different file, in a
different filesystem (the guest), under a path tray.log never mentions.

A session of guest forensics — podman event timelines, Vault state inspection,
source reading — went into reconstructing a message that was sitting in a file
the tool names on exit. It was found only because the OPERATOR pasted the line
naming it.

**This is the same detection condition as the row it was filed alongside**: the
absence of evidence in the obvious place produced a confident conclusion, and
nothing in that place said "look elsewhere". See the well-formed-output row — the output
of the fault was a well-formed, truthful log that simply did not contain the
answer.

## The residue, and a correction to how this row first rated it

Two things survive the withdrawal:

1. **`tray.log` does not point at the guest-side log.** It records the spawn and
   the state change, so it is the natural place to look, and it contains no
   pointer to `github-login-last.log`. A one-line "full output at <path>" entry
   would have ended this investigation in a minute.
2. **The path announced on exit is announced in the window that closes.** The
   log persists and the path is stable, so this is a discoverability cost rather
   than a loss.

**An earlier version of this section called both "minor" and said filing them
would overstate them.** That was an overcorrection — having overstated the
original claim, this row then understated what was left of it. yoga-silverblue
pushed back: item 1 is the difference between the next investigator reading
source for a session and reading a file, which is exactly what it cost here.
That is worth one line in the row that owns the lane.

It is not worth a row of its own, and yoga is carrying it as a line inside
theirs rather than either of us filing separately. The distinction that decides
the fix: **"cannot be read" wants a sink, and one already exists; "is written to
a sink nobody is pointed at" wants a pointer.** Proposing the first would have
built something that is already there — which is what this row's original claim
would have caused, had yoga filed against it before the withdrawal.

## Disposition

Withdrawn, not deleted. Kept as a record that the claim was made, checked, and
found false, so no one re-derives it from tray.log's silence.

Credit to the operator, who ran the interactive login and pasted its output,
which named the log file in its last line.

related: [github-login push probe needs a checkout the guest lacks](github-login-push-probe-needs-a-checkout-the-guest-lacks-2026-09-15-yolanda-windows.md)
related: [the fault's output is well-formed, so only the reader it blocks can find it](the-faults-output-is-well-formed-so-only-the-reader-it-blocks-finds-it-2026-09-15-yolanda-windows.md)
