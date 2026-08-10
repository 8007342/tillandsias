# Local gate evidence case: the query_packets clippy failure

Date: 2026-08-09
Status: evidence
Packet: `local-gate-obligation-missing-from-the-loop` (order 598-znuv)
Release: v0.5

## Why this file exists

598-znuv requires the gate to be load-bearing, not a formality. This is the
recorded evidence case: the concrete instance where `./build.sh --check` was
the ONLY thing between a broken trunk and a downstream clone, because push CI
had been removed the same day.

## The failure

crates/tillandsias-plan/src/main.rs:327 carried:

```rust
.filter(|_| limit == 0 || true)
```

`limit == 0 || true` is unconditionally true, and clippy denies it. The line
landed on `linux-next` in the query-overlay work and was NOT caught: push CI
was removed the same day (litmus:github-actions-budget now enforces that only
the manually-dispatched release workflow may exist). The first agent to run
`./build.sh --check` before a push (the cycle recorded in this packet) was
refused, and the expression was fixed in that cycle.

## Why it matters now

- The workflow that used to "mark it red" exists nowhere on a working branch.
- Every agent push depends on the local gate. The gate must be a NAMED
  Finalization obligation in the loop skill, not an incidental habit, or the
  next unparseable/unformatted push poisons every downstream clone.
- The gate is cheap (a partial build + plan validation) and fails fast; the
  cost of skipping it is cross-host breakage (see
  `plan/issues/agent-pushed-unparseable-code-no-push-ci-2026-07-21.md`).

## Closure

598-znuv makes the obligation explicit in skills/meta-orchestration/SKILL.md
Finalization step 4, corrects the AGENTS.md push-CI claim (GEMINI.md and
.github/copilot-instructions.md inherit the correction via symlink), and pins
both with litmus:github-actions-budget steps that are RED before the edit.
