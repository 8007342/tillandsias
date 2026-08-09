# Litmus guards that pin an EXPRESSION instead of a PROPERTY (2026-08-09)

Classification: `enhancement/`
Order: 621-2re2 (filed during the unstable-channel cycle)
Host: linux_mutable

## What happened

`./build.sh --ci-full` went red on three litmus steps in one cycle. All three
were FALSE REDS, and all three had the same root cause: the step greps for a
literal source expression, so a refactor that **preserves every property the
step exists to protect** still turns it red.

| Step | Pinned expression | Legitimate change that broke it |
|---|---|---|
| `litmus:forge-plan-expert-build-shape` step 2 | `ensure_forge_experts >>/tmp/forge-lifecycle.log 2>&1 &` | 619-vwau moved the `&` onto an enclosing subshell so the generic-project index could be discovered in the same background fork. Still backgrounded, still fail-soft. |
| `litmus:forge-experts-ephemerality-shape` step 5 | allowlist of literal redirect prefixes | 619-vwau wrote the index through a local `$index_dir`, which **is** `$FORGE_EXPERTS_STATE_DIR/project-index` — genuinely ephemeral. The enumeration cannot follow one level of indirection. |
| `litmus:smoke-release-channel-shape` step 4 | `TILLANDSIAS_RELEASE_BASE:-https://github.com/${REPO}/releases/latest/download` | 621-2re2 introduced the unstable channel, so the default moved into a `case`. Override still honored, default still stable. |

Two of these landed on `linux-next` on 2026-08-08 and sat red through the next
cycle. The v0.4.260804.1 release notes record `237/237 litmus`, so the release
gate had been green four days earlier.

## Why this is worth filing rather than just fixing

A false red is not a harmless inconvenience — it is *actively corrosive to the
gate*. The release gate is now the ONLY verification (push CI was removed
2026-08-03, order 599-w5jd). An agent that meets a red it believes is spurious
has exactly two moves: spend a cycle proving it spurious, or start treating
reds as noise. The second is how a gate dies. Three at once in a single cycle
is enough signal to name the class.

It also costs real cycle time: proving the two forge reds were pre-existing
required standing up a worktree at the pre-merge commit and re-running the
suite there, purely to answer "did I break this?".

## The distinction

A guard should assert **what must be true**, not **how it is currently
written**:

- Property: "the expert build is backgrounded and cannot fail the launch."
- Expression: "this exact string appears in lib-common.sh."

They agree until someone refactors, and then only the property is still right.

## What was done in this cycle

All three steps were rewritten to assert properties:

- Backgrounding is now checked structurally (the call is fail-soft; whatever
  construct contains it is backgrounded), not by literal string.
- `scripts/check-installer-channel.sh` (new) executes an installer's own
  channel-resolution prologue and reports the resolved base under a falsifiable
  grammar, so the release-channel litmus tests behavior. It gained a negative
  control: an unknown channel must be REFUSED, not silently defaulted.
- The ephemerality allowlist gained `$index_dir`, plus the rule the file already
  applied to `$stamp`: **every allowlisted name pays for itself with its own
  step proving it resolves into tmpfs.** Allowlisting a name without that proof
  is precisely how a persistent surface would slip in behind a local variable.

## Residual — not closed by this cycle

No sweep was done. Only the three steps that fired were repaired; the same
brittleness is presumably spread across the rest of the ~239-test corpus, and
each instance is a future false red at some future refactor.

Proposed next rung (smallest useful slice): a corpus scan classifying steps by
whether their command is a literal `grep -F`/`grep -q` against a source file
with no execution and no negative control. That set is the candidate list. It
does not need to be fixed all at once — ranking it makes the debt visible and
lets later cycles burn it down where it is cheapest.

Note the bar-raise boundary: converting the scan's output into an enforced
requirement ("no new expression-pinning guard may be added") is a scope
expansion of the loop's contract and is **Tlatoāni-gated**. This issue proposes
the candidate scan only.

## Related

- `plan/issues/meta-orch-enhancement-opportunities-2026-06-20.md` — capture →
  reduce → promote worked example.
- `methodology/convergence.yaml` → `bar_raise_governance`.
