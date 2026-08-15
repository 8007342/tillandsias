# "provision failed — retry" neither retries nor is actionable (648-jv69, 648-772y)

- Date: 2026-08-10
- Reporter: operator, at the terminal, on the Windows host
- Class: `optimization/` — a dead affordance over a stopped process
- Also records a **correction to my own 644-a3wj PASS report**

## Operator report

> "it says 'provision failed - retry' but 'retry' is not actionable, I don't know
> if it's retrying at all"

**It was not retrying.** The log is unambiguous:

```
04:34:09 → 04:40:10   control wire not ready; backing off  attempt=1 … attempt=9
04:41:10  ERROR WSL recipe provisioning failed
          err=control-wire handshake did not succeed within budget:
              attempt 10: connect+handshake timed out after 30s
04:41:42  ERROR launch-failure diagnostics bundle written
```

Nothing after `04:41:42`. The tray exhausted its 10-attempt budget, stopped, wrote
a diagnostics bundle, and left a control labelled "retry" that did nothing. The
operator found it ~15 minutes later with the machine dead behind a live-looking
button.

## Defect 1 — the affordance lies about the state (648-jv69)

After budget exhaustion the tray is in a terminal state, but the UI presents an
action. Two acceptable fixes; the choice is a design call:

- keep retrying on a long backoff and say so ("retrying every 5 min, attempt 14"), or
- state plainly that provisioning has stopped, and make the control actually
  start a fresh attempt.

What must not survive is the current combination: a stopped process, a button
that suggests otherwise, and no way for the operator to tell which. This is the
same shape as the counterfeit-completion defects fixed elsewhere this session
(`632-retq`, `643-bnag`, `647-i98k`) — a terminal state wearing the costume of a
live one — but here it is the UI rather than an exit code.

Recovery, for the record: `Stop-Process tillandsias-tray` →
`wsl --terminate tillandsias` → relaunch. Control wire came up in seconds,
`--diagnose` HEALTHY. **The tray could do this itself**, which is what makes the
dead button worse: the fix was mechanical and available.

## Defect 2 — a tray/guest version skew wedges the control wire (648-772y)

Root cause of the failure, from the preserved diagnostics bundle:

```
04:33:27  adopted guest wiring is stale — re-injecting bootstrap logic
          guest_version="0.4.260810.1"  tray_version=0.4.260809.2
```

A **0.4.260809.2** tray found a guest provisioned by **0.4.260810.1**, judged the
wiring stale, and re-injected *older* bootstrap logic. Seven seconds later a
**0.4.260810.1** tray started against that downgraded guest and its hvsocket
handshake (vsock 42420) never completed — ten timeouts, then failure.

The skew detection is not itself wrong; downgrading the guest wiring to match an
older tray is defensible. What is missing is recovery: once the handshake fails
repeatedly against a guest whose wiring was just rewritten, terminating the VM
and re-provisioning is the known fix and nothing attempts it.

"Install an older build over a newer guest" is not an exotic sequence — it is
exactly what an operator does when an unstable-channel build misbehaves and they
roll back. `WARN build version skew` lines already appear in this host's log from
2026-08-03 and 2026-08-05, so the condition recurs.

## Correction to my 644-a3wj report

I closed `644-a3wj` as **PASS on all four steps**, and the ledger and commit
`b9c8f99b` say so. That verdict was taken from a `--diagnose` at **04:32:20**,
which was genuinely HEALTHY.

I then ran one more thing: the downgrade-to-stable and restore-to-unstable round
trip that proves the channel default resolves correctly. **That sequence is what
broke the host**, at 04:33:27, and I did not re-check afterwards. The machine sat
in a failed provisioning state for roughly 25 minutes until the operator found it.

The smoke's four steps did pass, and the evidence for each stands. But the report
implied the host was left healthy, and it was not. The verification error is
specific and worth naming: **I checked convergence at the point that suited the
narrative rather than at the end of what I actually did.** A post-condition check
belongs after the last mutating step, not after the last interesting one.

`644-a3wj` stays `completed` — the steps were really executed and really passed —
with this correction recorded against it, and the two defects the incident
exposed filed as their own packets.
