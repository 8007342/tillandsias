# Two defects in the smoke runbook's §3 Windows block: a benign stderr line aborts the run, and the evidence directory is never cleared

**Filed:** 2026-09-12 · **Kind:** bug · **Capability tags:** smoke, windows, runbook
**Host:** ESMERALDINHA (Windows 11, Windows PowerShell 5.1), during the v56.9.12.1 smoke
**Ordered by:** macuahuitl-fedora (coordinator), 2026-09-12

trace: skills/smoke-curl-install-and-test-e2e/SKILL.md §3 Windows
       plan/issues/smoke-e2e-findings-v56.9.12.1-2026-09-12.md

## Defect 1 — `*>&1` under `$ErrorActionPreference='Stop'` aborts on healthy stderr

The §3 Windows block sets `$ErrorActionPreference = 'Stop'` and runs

```powershell
& $tray --provision-once *>&1 | Tee-Object target\smoke-e2e\03-provision.log
```

In **Windows PowerShell 5.1**, redirecting a NATIVE executable's stderr wraps
each stderr line in a `NativeCommandError` ErrorRecord. With `Stop` in force
that record is terminating. The tray prints

```
Failed to set locale, defaulting to "C.UTF-8"
```

on a healthy run. The pipeline therefore aborted mid-provision — the tray had
reached "Installing systemd + podman in Fedora base" — and the tray process
died with it. `$LASTEXITCODE` was never consulted: the failure happened at the
pipe, not in the program.

So the lane fails on a host whose release is fine, and the abort is
indistinguishable at a glance from a genuine provision failure.

**Fix shape:** do not combine `*>&1` with `Stop` around a native call. Set
`Continue` for the call and assert `$LASTEXITCODE` explicitly — which is what
the block already does everywhere else, and what its own §0 note prescribes
for exit-code discipline.

## Defect 2 — the evidence directory is never cleared, so a stale PASS can be read as today's

`target/smoke-e2e/` accumulates across runs and no step clears or timestamps
it. After the abort in Defect 1, `03-provision-exit.txt` read:

```
provision_exit=0
cold_provision_seconds=129
```

Neither line was written by this run. Both were from **2026-09-04**. Of the 21
files present, **15 predated this run**, some from 2026-08-14.

Any block that aborts partway leaves every later assertion reading a PRIOR
run's `03-status.json`, `03-diagnose.json` and exit files — and each of those
assertions would have PASSED on stale bytes. The §3 block's own
destruction-marker check is the only step that is immune, because it compares
timestamps.

This is the 1033-iycs family: evidence not pinned to the run that produced it.

**Severity ordering:** Defect 1 makes a good run look bad — loud and
self-correcting. Defect 2 makes a bad run look good, silently. Defect 2 is the
one that matters. The Windows lane improvised for a long time before
1004-fue3 gave it a block, so it should not be assumed that every past Windows
PASS was reading its own bytes.

**Fix shape:** clear or timestamp `target/smoke-e2e/` at §0, and have each
assertion verify the file it reads postdates the run's start marker.

## What this run did about it

Archived the 15 stale files to `target/smoke-e2e-stale-before-v56.9.12.1/`
before recording any verdict, so the v56.9.12.1 report rests only on bytes that
run wrote.

## Exit criteria

- "a healthy tray run that writes to stderr completes §3 without aborting; pre-fix result: FAILS (locale line terminated the pipeline mid-provision)"
- "an aborted §3 cannot produce a PASS from a previous run's files; pre-fix result: FAILS (a 2026-09-04 provision_exit=0 was present and readable as today's)"
- "NEGATIVE CONTROL: a genuine non-zero `$LASTEXITCODE` still fails the step loudly — the stderr fix must not swallow real failures"

---

## CORRECTION 2026-09-12 — `ErrorActionPreference='Continue'` is NOT a sufficient fix

The fix shape given above for Defect 1 is wrong, and I disproved it by relying
on it. I wrote a bisect runner that set `$ErrorActionPreference = 'Continue'`
and kept the redirect:

```powershell
& $tray --provision-once 2>&1 | Out-File -Encoding utf8 "$ev\03-provision.log"
```

It aborted at exactly the same point as the runbook's own block — mid-provision,
on the same benign `Failed to set locale, defaulting to "C.UTF-8"` line, with
the same `NativeCommandError`. Twice, on two different tags.

**The redirect itself is the defect, not the preference variable.** In Windows
PowerShell 5.1 the merge of a native executable's stderr into the success
stream is what manufactures the ErrorRecord; `Continue` does not reliably
prevent that record from killing the pipeline in a script context, and
`$?` is set false even when the exe exits 0.

Corrected fix shape — **do not let PowerShell touch the native stderr stream at
all.** Redirect outside it:

```powershell
& cmd.exe /c "`"$tray`" --provision-once > `"$log`" 2>&1"
$provisionExit = $LASTEXITCODE
```

`Start-Process -Wait -NoNewWindow -RedirectStandardOutput -RedirectStandardError`
is the other acceptable shape. Both keep the exit code authoritative, which is
the property the block needs.

This correction matters for whoever implements the fix: a patch that only
changes the preference variable will look right, pass a casual review, and
still abort on the next host whose tray writes a locale warning.
