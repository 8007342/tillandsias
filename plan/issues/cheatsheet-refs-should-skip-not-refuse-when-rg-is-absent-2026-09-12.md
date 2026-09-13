# check-cheatsheet-refs.sh should emit a typed SKIP on stdout when ripgrep is absent, instead of refusing on stderr as though a reference failed

**Filed:** 2026-09-12 · **Kind:** bug (contract) · **Priority:** p2 · **Unclaimed** · **pickup_role:** any
**Filed by:** esme-windows at macuahuitl's order, split out of 1129-xm5z deliberately
**Capability tags:** gate, cheatsheets, tooling, fail-loud

trace: `scripts/check-cheatsheet-refs.sh`
       `scripts/gate-steps.d/165-1087-h2z9.step` — the data binding that carries one STEP_ERROR
       `scripts/check-cheatsheet-tiers.sh` — the correct convention, one check over
       plan/issues/gate-step-reports-absent-rg-as-unresolved-cheatsheet-ref-2026-09-12.md — the observation this comes from

## Claim

`check-cheatsheet-refs.sh` distinguishes two conditions by exit code: **exit 2**
= ripgrep is available neither on the host nor in the builder toolbox, nothing
was examined; **exit 1** = a reference genuinely did not resolve. Its exit-2
message goes to **stderr**.

The gate step that binds it is data (1072-b7eq) and carries exactly one
`STEP_ERROR` string, so both exits print:

```
a cheatsheet reference does not resolve (1087-h2z9)
```

A tooling gap is therefore reported as a verdict about content, and the
operator is sent to hunt a cheatsheet that is fine.

**The proposed contract:** on the tool-absent condition, print a typed token to
**stdout** and exit 0 —

```
skip:cheatsheet-refs:rg-absent (no ripgrep on this host or in the toolbox; check not run)
```

— leaving exit 1 to mean, exclusively, that a reference failed.

## Why stdout and a token, specifically

Three separate consumers need it and none can use the current shape:

1. **The operator.** A skip naming the absent tool is actionable; "a reference
   does not resolve" is a false lead.
2. **The convention already exists one check over.** In the same gate log,
   `check-cheatsheet-tiers.sh` reports
   `skip:cheatsheet-tiers:cargo-absent (no toolchain on this host; check not run)`.
   Absent tool reads as SKIP there, explicitly. This check departs from a rule
   its neighbour already follows.
3. **Falsifiability.** `scripts/test-host-tools.sh` falsifies a prover-backed
   row by hiding the tool and reading the prover's last **stdout** line. A
   refusal on stderr with a non-zero exit cannot be read by that arm at all —
   which is why 1129-xm5z had to add a separate presence probe
   (`check-ripgrep-available.sh`) rather than use this script as its prover. A
   typed stdout token would let one script serve both purposes.

## Measured

ESMERALDINHA, 2026-09-12, rg absent from the `tillandsias-build` WSL2 distro:
the land refused with `LAND_EXIT=3` and the content-failure sentence above,
having examined **zero** references. The real cause appeared only further down
the gate log, on stderr:

```
error: ripgrep (rg) is available neither on this host nor in the
       tillandsias-builder toolbox.
```

With rg present the same step passes in **4.2s** over **577** references.

## Scope note — why this is not inside 1129-xm5z

1129-xm5z provisions rg so the condition stops arising on this fleet. It does
not change what happens on a host where the condition arises anyway, and
changing a gate step's contract is a larger decision than adding a package to
an init set. Filed separately on that basis rather than widened into the
provisioning packet.

Order 799-tb7q already called the bare refusal "the mis-shaped" behaviour and
added the host-else-toolbox resolver; the remaining gap is that when BOTH
sources miss, the refusal is still shaped as a content failure.

## Exit criteria

- "on a host with no rg and no toolbox rg, the gate reports a SKIP naming the absent tool and does NOT refuse the land; pre-fix result: FAILS (LAND_EXIT=3 with the content-failure sentence, zero references examined)"
- "the skip token appears on STDOUT and the script exits 0, so a prover-backed host-tools row could read it; pre-fix result: FAILS (stderr, exit 2)"
- "NEGATIVE CONTROL: with rg present and a genuinely unresolvable reference, the step still refuses and still prints the 1087-h2z9 sentence — the fix must not downgrade a content failure to a skip"
- "NEGATIVE CONTROL: the skip path is reachable ONLY from the tool-absent condition, so an exit-1 content failure can never be silently converted"

## Open

Whether the gate-step data format should also grow a `STEP_SKIP_EXIT` field, so
other data-wired steps can express the same distinction without each script
inventing its own token. This packet does not need it — a stdout token plus
exit 0 requires no runner change — but the question recurs and is worth
deciding once. Only this one step was measured.
