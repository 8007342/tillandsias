# Proposal — lua-command-runtime-and-policies

Umbrella packet: `1443-6r3q`. Design note:
`plan/issues/lua-bash-replacement-and-policies-design-2026-09-27.md`.

## Why

The operator's direction (2026-09-27): "a LUA runtime for BASH execution
with named parameters and NO PIPES … the full LUA runtime to replace
unbounded bash, we'll add BASH POLICIES", and "land-on-platform-branch might
need to be a .lua … SEED some BRANCH DISCIPLINE, where … the git mirror
should then respond with the level of branch discipline being actively
enforced for the checked out project".

The fleet has measured every failure this answers, and each one happened in
the shell, before any file existed for a decider to read:

1. Unquoted heredocs executed prose — twice on 2026-09-27 (the 1430-rnpd
   correction, 1256-t3w8 before it); one run executed `openspec init` and
   `openspec update` in a protected checkout.
2. SIGPIPE under `pipefail` flipping a verdict (1130-qk7d twice, 792-ksr8,
   795-imz3; 1252-fg9e reproduced the inversion 5/5 on a 200,000-line input).
3. Commands that succeed wrongly and verdicts read through `| tail -1`.
4. Quoting lost across a boundary — `wsl.exe` running a poweroff as root
   (smoke findings v56.9.27.2 windows), MSYS rewriting `\.` in a cosign
   identity and breaking a release (1425-8wir).
5. Dialect drift — bash 3.2, BSD grep/sed/awk, `awk \b` silent on macOS
   (1132-r4mt, 1374-4u6i, 761-g36m).
6. A fixture writing into the real checkout's git dir and forging a green
   stamp (1442-22d2).
7. Destructive commands (`podman system reset`, `rm -rf`, `--reset-state`)
   run on an orchestrator's instruction rather than the operator's.

The runtime that deletes shapes 1–5 by construction already exists:
`crates/tillandsias-exec` (1252-fg9e) behind `proc.run`/`sh.run` in
`crates/tillandsias-plan/src/lua_predicate.rs` and the sandboxed
`tillandsias-plan lua` CLI (1375-btuf), with the 2026-09-26 no-pipes design
and its packets (1384-aixy, 1384-bqhy, 1384-bxhk, 1384-ddua, 1384-j3cv).
What is missing is the AGENT side of it — doors an agent calls instead of
the Bash tool — and any POLICY: today nothing decides whether a command may
run, on which host, under which regime, with whose consent; and branch
discipline is spread over three documents and a mirror env var that
disagree (methodology admits `work/<order>`; the mirror's
`TILLANDSIAS_BRANCH_CREATION_REGEX` does not).

## What Changes

- **ADDED** capability `command-runtime`: the agent doors onto the existing
  executor — `tillandsias-plan run … -- <argv>` with named flags, `--json`
  and `--argv-json -`; an MCP `run_command` tool; a capture bound on
  `tillandsias_exec::Command`; the base-environment rule; the typed result
  shape with `run_id`.
- **ADDED** capability `command-policies`: a compiled-in floor plus a
  per-project seed `.tillandsias/command-policies.yaml` that can only
  tighten it; evaluation keyed by command family, host kind and regime
  inside every door; why/remedy on every refusal; a fixture filesystem
  scope; per-run operator consent tokens; an audit log with redaction.
- **ADDED** capability `branch-discipline`: a per-project seed
  `.tillandsias/branch-discipline.yaml` carrying 1363-xp2v's two axes
  (level 0|1|2 forward-only; per-rule enforcement advised|warn|enforced;
  an absolute level-0 floor where nothing refuses a bare project's push);
  `tillandsias-plan discipline show|target|check-ref` and a
  `discipline_show` MCP tool; the land tool's discipline probe; the Lua
  land tool.
- **ADDED** to `branch-discipline` (operator rulings 2026-09-27): the level
  is DERIVED from observed facts and checked against the seed, refusing
  only where both agree; hook TEMPLATES per client and mirror event,
  embedded in the plan binary and installed on demand per project for its
  level (`discipline install-hooks`, `discipline raise`), a level-0 project
  pushing to main freely; every hook refusal carries
  `remedy: this project at level <n> … needs <X>; use /<skill> for instructions`;
  a generic `project-discipline` skill for the sentence to resolve to.
- **MODIFIED** `git-mirror-service`: pre-receive reads and enforces the seed
  at each rule's enforcement where seed and derivation agree (protected
  default branch refused before relay, grammar per rule), dispatches the
  project's own mirror-side hooks per push event (sandboxed, bounded, the
  affordance relayed to the client), and the reconcile tick publishes
  `refs/tillandsias/discipline/<level>/<enforcement>/<derived>/<digest>/<epoch>`.
  The probe-push namespace of the first draft is dropped (ruling 5).
- **ADDED** (temporary) a Claude Code PreToolUse hook for the Bash tool that
  classifies raw commands against the seven shapes through the policy
  engine and carries its own retirement condition; its settings entry is
  COMMITTED to the project's `.claude/settings.json` and the forge overlay
  (ruling 1).
- **Policy defaults and consent** (rulings 2 and 3): the allow default flips
  to deny after a MEASURED quiet period (`deny_after_quiet_days: 14`,
  operator-confirmed 2026-09-27: "14 days is a good starting point"); SOFT
  reset is pre-authorised in forges always,
  HARD reset needs a per-run operator token every time with no environment
  pre-authorisation.
- **MODIFIED** deciders: `check-bash-dialect`, `check-sigpipe-verdict-pipelines-added`
  and `check-jq-callsite-ratchet` report their population against a
  bootstrap-shell allowlist and retire by a number.

## Capabilities

### New Capabilities

- `command-runtime` — `openspec/specs/command-runtime/spec.md` (draft)
- `command-policies` — `openspec/specs/command-policies/spec.md` (draft)
- `branch-discipline` — `openspec/specs/branch-discipline/spec.md` (draft)

### Modified Capabilities

- `git-mirror-service` — delta in `specs/git-mirror-service/spec.md`

## Impact

- **Code**: `crates/tillandsias-exec` (capture bound),
  `crates/tillandsias-plan` (`command_policy.rs`, `run_verb.rs`,
  `branch_discipline.rs`, dispatch arms, `capabilities.txt`),
  `images/git/pre-receive-hook.sh` and a new `publish-discipline.sh`,
  `images/default/config-overlay/mcp/{forge-plan,project-info}.sh`,
  `scripts/land-on-platform-branch.sh` (probe, then stub),
  `scripts/lua/land-on-platform-branch.lua`,
  `scripts/lua/pre-push-main-branch-affordance.lua`,
  `scripts/hooks/claude-pretooluse-command-policy.sh`, three deciders.
- **Seeds**: `.tillandsias/command-policies.yaml`,
  `.tillandsias/branch-discipline.yaml`.
- **Methodology**: one pointer key `branch_discipline_seed` in
  `methodology/multi-host-development.yaml`; the credential and reset
  specs being amended by sibling sessions are referenced, not edited.
- **Packets**: 1443-6r3q umbrella and fourteen slices, plus the four
  ruling slices 1446-xqi6 (hook templates + install), 1446-664f (derive),
  1446-87cy (mirror dispatch), 1446-qkx4 (the skill); 1443-isrk, 1443-9f5w,
  1443-we89, 1443-uit6, 1443-z3vb and 1443-u66u re-scoped by note events
  (see tasks.md and the design note §7).
- **Forge**: the git image gains the plan binary (mirror dispatch);
  `images/default/lib-common.sh` installs hooks for every checked-out
  project, not only Tillandsias checkouts.
- **Not changed**: verdict tokens of every existing land fixture and hook
  (they are interfaces; new tokens are additive), the plan-only lane, the
  gate-before-push order, the stamp protocol.
