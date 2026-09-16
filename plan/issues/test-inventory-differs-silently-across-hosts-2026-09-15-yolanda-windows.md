# A host's test inventory differs silently from its siblings, and only the filtered-out count shows it

Two hosts ran the same command against the same crate at the same commit and
got two green, complete-looking results describing **different test suites**:

```
yoga-silverblue (Linux)    0 passed;  18 filtered out
yolanda-windows (Windows)  1 passed; 123 filtered out
```

`cargo test -q -p tillandsias-windows-tray github_login_wrapper_captures`

105 tests exist on one host and not the other. **Neither output says so.** Each
is independently truthful, green, and gives no indication it measured a
different world than its sibling.

This needs no accident and no recurrence. It is the steady state.

trace: 913-27ex (zero-executed is not a pass), 1213-ysme (the instance that exposed it)
host: yolanda-windows, with yoga-silverblue

---

## 1. Why the usual reading fails

The cause in the observed instance was a `#[cfg(target_os = "windows")]`
module with a non-Windows stub, so an entire module's tests were absent from
the Linux build. That is ordinary and intended.

What is not intended is that **the absence is unobservable from either side**:

- `0 passed` on Linux reads as "the filter matched nothing here", which is a
  normal, frequent, unalarming result.
- `1 passed` on Windows reads as a healthy pass.
- Both exit 0. Both print `ok`.

An agent reading its own host's output has no signal at all. The discrepancy
exists only *between* hosts, and nothing routinely compares them.

## 2. The actionable half: pass counts cannot detect this, filtered-out counts can

This is the part worth keeping:

| signal | Linux | Windows | discriminating? |
|---|---|---|---|
| exit code | 0 | 0 | no |
| verdict word | `ok` | `ok` | no |
| passed count | 0 | 1 | **no** — both plausible |
| **filtered-out count** | **18** | **123** | **yes** |

`0 passed` and `1 passed` are both entirely plausible outcomes of a filter, so
comparing them proves nothing. `18` against `123` for the same crate at the same
commit cannot both be right about the same source tree — the *inventory* differs,
and the filtered-out count is the only field in the output that exposes it.

**A cross-host check should compare test INVENTORY, not test RESULTS.**

## 3. Scope — what is measured and what is inferred

Stated explicitly so this row is not read as broader than its evidence.

**Measured:** one crate (`tillandsias-windows-tray`), two hosts, one filter, one
commit. The counts above are verbatim.

**Inferred, not measured:** that the same blindness applies to other crates and
other cfg splits. It is plausible — the mechanism is generic to conditional
compilation, and the repo carries ~17 `#[cfg(target_os = …)]` module
declarations, including `linux`-gated blocks in `tillandsias-headless` and
`macos`-gated ones in `tillandsias-macos-tray` — but **no second instance has
been measured.** An implementer should expect to find more and should not assume
it.

**Not claimed:** that any of those other gates currently hides a guard. Only the
1213-ysme instance is known to have done so.

## 4. Why this is worse than the instance that exposed it

1213-ysme is one unenforced assertion, now fixed. This is the property that let
it hide, and that property is untouched by the fix: **any** future
platform-gated guard is invisible to every host that does not compile it, and
its host's output will say `ok`.

It is also the sharper member of the family this session has been filing all
day — an unexercised guard whose silence reads as a pass; a 0-byte log
indistinguishable from a silent lane; a mangled expansion printing a plausible
value. Those need a runtime accident. This one does not: the output of the fault
is not merely well-formed, it is **correct**. Two right answers about different
worlds, neither naming which world it measured.

## 5. Suggested disposition

A cross-host inventory comparison, not a new gate step on any single host — a
single host cannot detect this by construction. The cheapest form is to record
each host's per-crate test inventory (names, or failing that the total count)
and diff them across the fleet, flagging crates whose inventory differs by
platform without a declared reason.


**The boundary of this proposal.** Not every `cfg`-gated test is misplaced, and
the distinction decides whether there is anything to fix:

- Where the assertion is **already a source scan** — it reads the artifact as
  text and never needs the module it lives in — the gate is GRATUITOUS. Moving
  the assertion somewhere un-gated costs nothing and is a real fix. 1213-ysme is
  this case: the test was already an `include_str!`.
- Where the assertion is a **real behavioural test** of platform API (actual
  Win32 calls, a live registry, a real WSL round-trip), the gate is CORRECT and
  must stay. Such a test genuinely cannot run elsewhere.

For the second kind there is still a gap, but it is a DIFFERENT gap: the fleet
under-samples that platform. That is a cadence problem — how often anyone gates
on Windows at all — and not a test-placement one, and this row does not propose
a fix for it. It is named here only so an implementer does not "fix" a correct
gate by moving a test that cannot survive the move.

What survives in both cases is §2: the filtered-out count is what reveals that
the two hosts ran different suites, whether or not that difference is
legitimate.


Found while measuring the Windows half of yoga-silverblue's 1213-ysme; they
carried it in that row and asked that it be filed on its own, on the grounds
that it is not really about that bug.

related: 1213-ysme (yoga-silverblue) — the instance; commit 6d2597f6b
related: [the fault's output is well-formed, so only the reader it blocks can find it](the-faults-output-is-well-formed-so-only-the-reader-it-blocks-finds-it-2026-09-15-yolanda-windows.md)
