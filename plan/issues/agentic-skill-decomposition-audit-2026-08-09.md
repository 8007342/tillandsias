# Agentic skill decomposition — audit (2026-08-09)

Classification: `research/`
Packet: 630-vpmq (`agentic-skill-decomposition`), milestone 630-67jk
Method: delegated to a dedicated sub-agent; findings verified against the tree
before recording.

## The operator's framing

Skills read "do A, then do B", so the orchestrator performs every small task
itself and accumulates the debris of all of them. Rewritten as "have an agent do
A", the orchestrator spends context on orchestration and each sub-agent spends a
fresh context on one task, then discards it. The primary win is not concurrency
— we are not concurrency-constrained — it is that bloated context stops
propagating, so the orchestrator sustains longer sessions and can afford more
sophisticated triage.

## The rule this audit produced

> **Delegate reading, not running.** If a step is already a script with a pinned
> one-line grammar, it is *already* delegated — the executable IS the sub-agent.

Tillandsias has built roughly a dozen such executables (`check-credential-channel.sh`,
`check-committable-branch.sh`, `e2e-preflight.sh`, `trace-coverage.sh`,
`select-work-batch.sh`, …). Wrapping any of them in an agent adds a skill-text
prompt and a repo orientation to save eight lines of output — a net loss by an
order of magnitude.

The corollary is the useful half: the wins are wherever a step reads a LOT to
produce a LITTLE.

## Highest-value delegation targets

| Step | Why | Required result shape |
|---|---|---|
| `advance-work-from-plan` §1.6 "read authoritative ledgers" | Pulls ~40k lines of addressable ledger surface (`plan/index.yaml` is 31,678 lines, `loop_status.md` 7,875, 405 issue files) into the orchestrator to extract a paragraph | ≤25 lines: `## Direction` verbatim, canonical branch, 3–5 flagged packet ids, any blocker naming this host |
| `coordinate-multihost-work` mediation detection | `git log -p -n 5 <shared-file>` is the single biggest blob in the library | ≤6 lines: `deadlock\|thrash\|divergence: <hostA> <hostB> <file>` or `none` |
| `advance-work-from-plan` §5 pre-implementation read | The canonical "read six files exhaustively" case — exactly what a disposable context is for | ≤15 lines of `path:line` + invariant names |
| `merge-to-main-and-release` §7 `gh run watch` | Blocks and returns a large log | `release:green <asset-url>` or `release:red <job> <run-url>` |
| §6 integration verification gate | Three mechanical checks, one verdict | one line: `gate:pass` / `gate:fail <check> <path>` — **first failing path only, never the build log** |

Estimated recoverable orchestrator context: **45–60%** of a full-mode cycle,
dropping toward 25% on a cycle that includes a merge/release pass (that skill is
nearly all authority).

## Where delegation LOSES — the half that makes the audit usable

1. **The guards and the batch selector.** One command, one grammar-pinned line.
   Pure overhead to delegate.
2. **The implementation itself.** The orchestrator has already loaded the packet,
   the direction, and the write-scope table. A coding sub-agent re-derives all of
   it and hands back a diff the orchestrator must re-read — double-paying for the
   same files.
3. **Finalization steps 2–8.** Commit, YAML-validate, `--check`, boundary verify,
   emit `MO-FULL:` — one causal chain over state only the orchestrator holds.
   Splitting it opens a window where the marker's invariants are unverifiable.
4. **Anything inside the forge budget** (order 264, one packet/cycle). Context
   never grows enough to amortize the overhead.
5. **Cycle metrics.** The skill demands the tool output *verbatim* and forbids
   reporting unproduced metrics. Routing it through a summarizing agent invites
   precisely the fabrication that rule exists to prevent. This one is a
   correctness constraint, not a cost one.
6. **Smoke mode.** ~5-minute budget; spawn latency is a material fraction of it.

## The cheaper alternative the audit surfaced

Much of the §1.6 saving needs **no agent at all**. The skill names whole files to
read, while the MCP path (`plan_query` / `plan_ready` / `plan_answer`) is offered
as optional. *Mandating the MCP path* recovers a large share of the same context
at lower cost than spawning anything. Do that first; delegate what remains.

This matters for sequencing: 630-vpmq should not become "spawn agents
everywhere" when the first increment is "stop reading whole ledgers".

## Separate finding — the skill tree has a second, unversioned source of truth

The documented layout says each runtime accesses skills via a symlink to
canonical `skills/`, "so there is exactly one source of truth". Verified false:

- `.claude/skills/` holds **10 symlinks and 14 real directories**.
- 13 skills exist ONLY under `.claude/skills/`: `build-macos-tray`,
  `haiku-delegate`, and the 11 `openspec-*` skills.
- Other harnesses carry their own counts: `.opencode/skills` 21,
  `.codex/skills` 19, `.github/skills` 19, `.gemini/skills` 9.

The consequential one is **`build-macos-tray`**: a macOS build skill visible only
to Claude-harness agents. A macOS agent running under opencode, codex, or gemini
does not have it. `haiku-delegate` — which already states the correct delegation
doctrine this packet generalizes — is likewise Claude-only.

Filed as its own packet rather than folded in here, because it is a
distribution/consistency defect independent of the delegation rewrite.

## Residual

- No measurement yet. Every number above except the line counts and the
  symlink census is an estimate. 630-d2jv (velocity measurement harness) exists
  precisely so this packet's claims become falsifiable; it should land first.
- The sub-agent contracts above specify result SHAPES but no enforcement. A
  sub-agent that returns a large blob re-imports the bloat and silently defeats
  the change — that needs a check, not a convention.
