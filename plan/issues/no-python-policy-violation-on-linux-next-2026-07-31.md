# CAPTURE: `check-no-python-scripts.sh` fails on linux-next HEAD (tlatoani_hard_no_python breach)

- date: 2026-07-31
- class: optimization/ (policy-gate breach; blocks the no-python CI gate for every host)
- found by: linux-immutable NPU bring-up cycle (incidental — running the checker
  before committing plan-only changes; the failure is NOT from this cycle's work)
- host: yoga (linux_immutable), branch linux-next @ 6ee743ac

## What

`scripts/check-no-python-scripts.sh` exits non-zero on the current
`linux-next` HEAD. The methodology pins it as the enforcement checker for
`runtime_language_policy.tlatoani_hard_no_python` (methodology.yaml). Three
offending call sites, all committed (not working-tree dirt):

- `scripts/check-plan-schema-divergence.sh:19` — `python3 -c "..."`
  (introduced by commit 4ad5f2b8, "chore(plan): normalize status vocabulary
  (order 440)").
- `images/default/config-overlay/mcp/project-info.sh:324` — `python3 -c "..."`
- `images/default/config-overlay/mcp/project-info.sh:375` — `python3 -c "..."`

Verified pre-existing via `git grep -n python3 HEAD -- <paths>`.

## Why it matters

`tlatoani_hard_no_python` is a hard policy: "Python is not allowed for
Tillandsias runtime, harness, or repository scripts." A committed `python3 -c`
in a `scripts/` gate script and in a shipped MCP config-overlay script both
violate it, and the very checker meant to enforce the policy now fails on the
mainline — so any cycle that runs `./build.sh --check` (or the no-python gate)
against linux-next sees red for reasons unrelated to its own work, which
masks real regressions and erodes trust in the gate.

## Smallest next action (for a linux worker)

1. `scripts/check-plan-schema-divergence.sh` — the schema-divergence check is a
   YAML parse + comparison; reimplement in Rust (or POSIX shell dispatching an
   existing Rust/binary tool) per the approved-language list. This is the
   higher-priority site because it lives in `scripts/` and gates plan work.
2. `images/default/config-overlay/mcp/project-info.sh` — the two `python3 -c`
   snippets run inside the forge MCP surface; rewrite in the approved runtime
   (Rust helper or POSIX shell over an existing binary). Note this ships in the
   forge image, so it is runtime Python, the exact case the policy forbids.
3. Re-run `scripts/check-no-python-scripts.sh` to green; the base64-injection
   checker already passes and must stay green (no decode-to-exec workarounds).

## Not in scope here

This cycle is the XDNA2 NPU inference redesign (research packet 541 + orders
542-544). This finding is filed per the meta-orchestration capture rule
("an unfiled finding is a lost finding") and left for `/advance-work-from-plan`
pickup by a linux host; it is intentionally NOT fixed in the same commit as the
plan-only NPU changes.
