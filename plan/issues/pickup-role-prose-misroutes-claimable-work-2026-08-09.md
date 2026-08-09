# `pickup_role` prose hands one lane's work to another (evidence for 632-39p3)

- Date: 2026-08-09
- Host: windows (windows-next), meta-orchestration cycle 2
- Class: `research/` — measurement feeding an open p0 decision, not a fix
- Related: `632-39p3` query-and-next-disagree-on-role-eligibility (p0, linux-owned)

## The other half of a known defect

The linux coordinator filed `632-39p3` earlier the same day: `query --role X`
matches the field literally and so **drops** all 56 `any` packets, while
`next X` includes them. Two readers, two answers, and the Windows and macOS
lanes starved.

This is the same field failing in the **opposite** direction, from the other
matcher:

| consumer | matcher | failure |
|---|---|---|
| `crates/tillandsias-plan/src/lib.rs:533` | `pr == r \|\| pr == "any"` | exact — **under**-matches |
| `crates/tillandsias-plan/src/main.rs:563` | case-insensitive substring | **over**-matches |

Under-matching hides work. Over-matching is worse, because it does not look like
a failure at all: it hands a host work that belongs to another lane, and the
host cheerfully claims it.

## Worked example, found while draining

```
packet 513  dev-end-user-gating-litmus
pickup_role: "linux (litmus harness); Windows/macOS replicate later"
```

`tillandsias-plan query --status ready --role windows` returns this packet,
because the string "Windows" occurs in the prose. The owner is linux, the
harness is linux, and the clause naming Windows says explicitly that Windows
comes **later**. A greedy Windows cycle draining its queue claims a linux p0 and
then blocks on a forge it cannot launch.

This was not hypothetical — it is how the packet surfaced. Cycle 2 on this host
queried its 7 "claimable windows packets" and the third one it opened was owned
by linux.

## Measurement

`scripts/check-pickup-role-grammar.sh --detail`, live ledger 2026-08-09:

```
pickup-role: total=637 canonical=608 prose=29 multi_host=6 sequenced=3 verdict=attention:sequenced-prose
```

Of 637 values, 608 are canonical tokens and 29 have drifted to prose. Six name
more than one host lane, and those split cleanly in two:

**Co-owned (3) — correct, not damage.** Both lanes genuinely own a half, and the
substring matcher offering it to both is the right answer by accident:

```
windows + macos hosts
macos + linux
linux (XDNA2 lane) + macos (Metal lane)
```

**Sequenced (3) — always wrong.** The second lane is named only as a follower,
verifier, or supporter, so it is explicitly *not* the owner:

```
linux (Rust launcher + lib-common.sh); Windows/macOS verify
linux (litmus harness); Windows/macOS replicate later
windows/macos with linux control-wire support
```

Counting all six as damage would have inflated the number and taught readers to
ignore it. Only the three sequenced values set a non-zero exit.

## Why this cycle measured instead of fixing

Which semantics `query --role` should carry is an **open decision owned by
632-39p3** — "both are defensible; having both simultaneously is not" — and that
packet's own notes warn that drain-queue and the `plan_query` MCP tool both
consume it. Changing the matcher from a sibling host, mid-decision, would be
drift dressed as helpfulness. The number is the contribution; the decision stays
where it belongs.

Note also that 3 of 637 is a *small* number. It is filed because the failure
mode is silent misclaiming across lanes, not because the count is alarming.

## Deliverables

- `scripts/check-pickup-role-grammar.sh` — falsifiable verdict line, exit 1 only
  on sequenced prose, `--detail` naming owner and wrongly-claimable lanes.
- `openspec/litmus-tests/litmus-pickup-role-grammar-shape.yaml` — asserts against
  fixtures with known answers via a `TILLANDSIAS_PICKUP_ROLE_INPUT` seam,
  including a negative control for a follower lane, a guard that co-ownership
  stays legal, and a refusal check so an unreadable input never reads as clean.

The checker deliberately uses grep/sed/awk only — no jq, yq, python, or ruby —
and the litmus pins that. Its sibling `scripts/select-work-batch.sh` cannot run
on Windows at all for want of jq (packet `632-retq`), and a report about
cross-host routing that only runs on one host would be self-defeating.
