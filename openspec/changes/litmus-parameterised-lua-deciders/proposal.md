# Proposal — litmus-parameterised-lua-deciders

Packets: epic `1800-nvsc`; slices `1800-rutz` (library + first adopter),
`1800-93qs` (file-grep), `1800-juv4` (script-output), `1800-8uzh`
(structured-field), `1800-s44f` (podman-probe), `1800-h7rt` (cargo-test and
cargo-other), `1800-vq33` (process, plan-query, git-query, text-transform),
`1800-f56m` (burn-down counter and the edit-converts ratchet arm).

## Why

The operator, pointing at envelope-citability step 20 on 2026-10-19:

> This is what we want to convert to Lua. Notice the amount of piping it had
> to do. These nested weird commands with lots of pipes should be
> parameterized Lua scripts instead: `command: MyRobustLuaScript.lua`, which
> in its belly does all the parsing and capturing of error states gracefully
> and provides proper affordances for recoveries, retries, using caches, etc.
> Thousands of tests still remain as funky piped bash commands.

Measured on linux-next the same day (`scripts/lua/census-litmus-pipes.lua`):
3204 `command:` lines, 950 with a pipe outside quotes (1477 by raw `|`), 155
with three or more. By the decision they make: file-grep 421, script-output
205, structured-field 88, podman-probe 66, text-transform 49, cargo-other 37,
plan-query 36, cargo-test 28, process 12, git-query 8. About 55 files already
call Lua through `tillandsias-plan script run`.

Each piped step re-parses its producer in-line and fails its own way:
`grep -q` under pipefail inverts on SIGPIPE; `head` truncates the line a
reader needed; `|| true` swallows the producer; a `$(...)` capture with no
echo on the failing branch goes red with EMPTY output. The last one is
incident 1799-5kvy: step 20 went red on the v56.10.19.1 release gate and
nobody could tell which test had failed.

What exists today only stops growth. `check-shell-ratchet.lua` (1384-bxhk,
1577-57u3, 1624-bv73) refuses a NEW piped litmus command beyond each file's
floor; standing debt is never driven down. `methodology/convergence.yaml`
carries counter-based backlogs (shell-to-lua) that this change mirrors.

## What changes

- NEW `scripts/lua/litmus-decide.lua`: ONE script, one decider FAMILY per
  call, parameterised by options, so a step reads
  `command: "... script run scripts/lua/litmus-decide.lua -- cargo-test --package X --require-ok T --name N"`.
  The runtime nils `require`, so the shared library (argument parsing,
  affordances, transient-only retries, tree-state cache, tool-missing and
  empty-population verdicts) is a section of that file. Families land one
  slice at a time: `cargo-test` and `file-grep` with this change's first
  slice; `script-output`, `structured-field`, `podman-probe`, `cargo-other`,
  `process`, `plan-query`, `git-query`, `text-transform` with theirs.
- `litmus-framework`: a litmus step that judges a producer's output MUST do
  so through a Lua decider; an empty population is never a pass; a missing
  tool is could-not-run; a failing cargo run names its tests.
- `ci-release`: a `litmus-piped-commands` carried-obligation backlog,
  advisory (warnings only, the operator's ruling), with the census as its
  counter; editing an existing piped command converts it.
- First adopter: envelope-citability step 20 (the operator's example) is the
  `cargo-test` call above; its floor line descends 16 → 15.
- `./build.sh --check` runs the decider's fixture
  (`scripts/lua/test-litmus-decide.lua`, 10 arms, red-first against the
  1799-5kvy shape) and prints the census.

## What does not change

- `command:` strings stay the litmus form; the runner is not changed and no
  file is rewritten by a tool. 902-5bf9's `steps:` form, when it lands, is a
  second front door to the same deciders.
- The shell ratchet's refusal of NEW pipes stays as it is.
- The backlog starts and stays advisory until the operator approves a bar
  raise under `bar_raise_governance`.
