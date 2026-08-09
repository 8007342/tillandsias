# Plan `blocks` fields do not enforce dependency state

Date: 2026-08-05 (America/Los_Angeles)
Status: ready
Plan: `plan-blocks-dependency-reciprocity-integrity` (order 609-az85)

## Finding

The zero-trust audit added `blocks: [authenticated-forge-write-transport-impl]`
to two new security packets, but the folded plan graph and integrity validator
derive dependencies only from the target's `depends_on`. A later workaround
restored order 451's `depends_on` to order 322 alone. The ledger therefore
looked blocked in prose while the executable graph did not enforce orders 579,
606-bvnp, or 606-9wqd.

This was initially misdiagnosed as an expert closure bug. The expert returned
an empty inverse closure because that was the real winning graph. After a new
LWW fragment reinstated order 579 in order 451's `depends_on`, both
`plan_blocked_by 579` and `plan_closure 579` immediately returned order 451.

## Desired contract

`depends_on` remains the one authoritative direction. If authors use a
convenience `blocks` field, `tillandsias-plan check` must require each target to
contain the reciprocal `depends_on` edge (or provide a safe command that writes
the authoritative target-side update). A decorative `blocks` declaration must
never pass integrity while implying a dependency the scheduler ignores.

## Exit criteria

- a fixture reproduces a `blocks`-only edge and makes integrity fail loud with
  both packet IDs and the missing reciprocal edge;
- reciprocal `depends_on` passes and drives closure/blocked-by queries;
- existing live `blocks` declarations are migrated or verified reciprocal;
- expert ground truth distinguishes a correct empty closure from missing graph
  authoring, preventing the original false diagnosis.
