# EXPERTS first-person audit — 2026-08-05

## Scope and verdict

This audit exercised the real `forge-plan.sh` and `project-info.sh` stdio MCP
servers at `81b153f2`, rather than inferring behavior from source. The compiled
deterministic expert is fast and useful for canonical queries, but it does not
yet satisfy the operator's cold-start contract: an agent cannot simply ask
"what's next?" and receive a small, current, release-aware action. Fragment
provenance can also be wrong while `verify-answer` reports success.

This session's native tool registry exposed neither server (`codex mcp list
--json` listed only GitHub), so direct stdio proved server behavior, not
transparent session attachment. OpenCode, Claude, and Codex image wiring exists;
fresh harness-native validation remains the acceptance boundary.

## Fresh OpenCode forge observation

The live rate-limited smoke after local build run `20260806T045626Z` crossed a
stronger boundary than the direct-stdio audit. The freshly installed
`tillandsias . --opencode --prompt ...` path launched the real forge image and
had persistent `forge-plan.sh`, `project-info.sh`, and `git-tools.sh` MCP child
processes. The skill completed with `MO-SMOKE: PASS` and the outer launcher
reported `FORGE_EXIT=0`. This proves automatic OpenCode process attachment for
that image/run; it does not prove that answers were useful or even selected.

In fact, the cold agent first attempted the unavailable direct
`tillandsias-plan` CLI, then inspected status/files and ran a broad litmus rather
than asking the attached expert. `base_state=ok` and `expert_sources=present`
were truthful, yet availability did not become substitution. This is the
product gap behind `plan-expert-actionable-next`: the warmed expert needs a
small natural first action that the harness reliably discovers and prefers,
not merely a background process an agent may ignore.

## Reproduction surface

The real server was driven with JSON-RPC frames equivalent to:

```bash
printf '%s\n' '<JSON-RPC>' |
  TILLANDSIAS_PLAN_BIN="$PWD/target/release/tillandsias-plan" \
  TILLANDSIAS_PLAN_INDEX="$PWD/plan/index.yaml" \
  TILLANDSIAS_METHODOLOGY_ROOT="$PWD" \
  bash images/default/config-overlay/mcp/forge-plan.sh
```

Baseline evidence:

| Surface | Result |
|---|---|
| `forge-plan` initialize / tools | PASS, 11 valid tool schemas |
| `project-info` initialize / tools | PASS, 13 valid tool schemas |
| compiled ledger check | PASS, 554 packets, unique IDs and sound live references |
| committed ground truth | PASS, 17/17 in about 0.2 s |
| small plan answer | 103–108 ms warm |
| methodology answer | 42 ms warm |
| `project-info` project type | 14 ms, `git,nix,rust,rust-workspace` |
| ready-for-Linux answer | 212 ms, 145 citations, 46,177-byte envelope |
| `spec_answer` | honest `unsupported`; the RAG index/endpoints are absent |

## Cold-start questions that fail

All three operator-level questions are unsupported with zero citations:

```text
what's next?
what v0.5 work can I do on linux?
what blocks the experts milestone?
```

Near-canonical phrasing can be more dangerous than refusal:

- `what is ready for linux for v0.5` returns `confidence=exact` with the full
  Linux-ready queue and silently ignores `v0.5`.
- `what blocks forge-local-experts-milestone` returns downstream consumers,
  not the milestone's upstream nonterminal prerequisites.
- A ready response contains non-claimable milestone/criteria-holder packets and
  up to 145 rows. This is enumeration, not action selection.
- `query --json` omits `desired_release` and `release_target`, although the TSV
  projection includes release data; MCP consumers cannot preserve the caller's
  release constraint.
- An initial `plan_blocked_by 579` / `plan_closure 579` returned empty because
  the winning ledger value really had restored order 451's dependencies to
  order 322 alone; sibling packets' `blocks:` declarations are not part of the
  folded dependency graph. After a later fragment reinstated 579 in 451's
  actual `depends_on`, both tools immediately returned order 451. The expert
  was correct and exposed a ledger-authoring hole: `blocks:` can look
  authoritative while the validator and graph ignore it.

The current 17-case ground-truth set does not cover these questions, release
constraint preservation, criteria-holder exclusion, ranked concision, fragment
citations, or upstream dependency semantics. Its green verdict is therefore a
coverage result, not proof of the desired product contract.

## Critical folded-provenance defect

The fragment overlay is query-visible but not citation-correct:

- Fragment-only packet `plan-append-event-blind-to-fragment-packets` is visible
  through `status` and `query`, while `answer status ...` refuses because no
  source span exists.
- Packet 570 is folded to `in_progress`, but its exact answer cites base
  `plan/index.yaml` lines whose status is still `ready`.
- `verify-answer` accepts that mismatch and also accepts a deliberately changed
  `authority.status="fabricated"`.
- Answer freshness uses the base index mtime, not the newest folded fragment.
- Eight fragment-born ready rows were omitted from an otherwise exact answer
  because they had no base source span.

An exact envelope must cite the winning source for each authoritative field. A
folded value with a stale base citation is not exact.

## `project-info` protocol drift

The sibling wrapper does not share `forge-plan`'s safer JSON-RPC behavior:

- numeric request IDs are returned as strings;
- an ID containing an escaped quote produces invalid JSON;
- unknown tools return success-shaped text instead of error `-32601`;
- unavailable engine/index state is indistinguishable from a legitimate empty
  query result;
- unknown arguments such as `desired_release` are silently ignored;
- README-first-line metadata can classify this repository as a Markdown fence.

## Generic-project contract mismatch

The current startup contract deliberately treats a non-Tillandsias checkout as
`degraded(no-plan-crate)` / `expert_sources=n/a`. The resolver probes hardcoded
Tillandsias locations and does not build a generic index from
`$TILLANDSIAS_PROJECT_PATH`. `project-info` supplies structured shell facts, but
there is no uniform natural `project_answer` / "what's next?" surface.

Meeting the operator's new-project/new-session contract therefore requires a
product contract and bootstrap design, not merely another path fallback: an
image-baked project-agnostic engine, ephemeral indexing of the active project,
and one natural answer surface that is warmed before the harness starts.

## Tracking and deduplication

New shaped packets are filed in the 2026-08-06 fragment:

- `expert-fragment-provenance-and-freshness`
- `plan-expert-release-and-upstream-query-primitives`
- `plan-expert-actionable-next`
- `generic-project-expert-bootstrap-contract`
- `project-info-jsonrpc-contract-parity`
- `plan-blocks-dependency-reciprocity-integrity`

Do not duplicate existing owners: 457 owns the cheatsheet inference replacement;
548/549/552 own spec RAG construction; 557/558 own fresh Claude/Codex validation;
568/570/605 own attachment and harness identity; 575 owns usage telemetry;
600-c266 owns append-event's fragment read path. Existing harness acceptance
must be ratcheted so direct stdio is diagnostic evidence only, never a substitute
for a harness-native tool call.
