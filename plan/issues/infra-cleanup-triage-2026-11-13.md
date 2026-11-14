# Infra and runtime cleanup triage (2026-11-13)

Operator direction 2026-11-13: "as the fleet rejoins, let's cleanup our mess,
and simplify our infra and runtime ... triage cleanup work for next."

This issue holds the three triage reports (forge cold storage, shell to Lua,
infra simplification) and the packets filed from them. Code is cited by symbol,
never by line. Claims below were re-checked on 2026-11-13 against the tree at
origin/linux-next and the host that filed this; where the audit's number and the
re-check disagree, both are given.

Packets filed in the same commit (fragment
`plan/index.d/20261113t233000z-2080-infra-cleanup-triage-macuahuitl.yaml`):

| Stream | Item | Packet order |
|--------|------|--------------|
| A | A1 cold volume | 2080-4t5d |
| A | A2 redirect build output | 2080-wbcw |
| A | A3 .git off tmpfs and source budget rule | 2080-d83n |
| A | A4 forge-df and banner | 2080-c4qv |
| A | A5 guidance seeds | 2080-vzda |
| A | A6 spec reconcile | 2080-ekm9 |
| B | B1 help/INDEX generator | 2080-k54x |
| B | B2 common Lua modules | 2080-zcur |
| B | B3 dedupe locals | 2080-xziq |
| B | B4 fixture-port pilot | 2080-553e |
| B | B5 ledger and git modules | 2080-vxrh |
| B | B6 toolbox guard | 2080-s2fd |
| B | B7 test-port waves | 2080-38yx |
| B | B8 lib-common, forge-plan, project-info | 2080-zadh |
| B | B9 whole-repo ratchet (BLOCKED, operator) | 2080-y8h7 |
| C | C1 metrics rotation and target sweep | 2080-zzv2 |
| C | C2 cut --check wall (needs operator) | 2080-h5i9 |
| C | C3 dead crates | 2080-8i25 |
| C | C4 stale OpenSpec changes | 2080-w8jh |
| C | C5 one model fetcher | 2080-5xkd |
| C | C6 merge images/web into web-wrangler | 2080-6364 |
| C | C7 login module consolidation | 2080-238r |
| C | C8 slim forge image stack | 2080-w7hb |
| C | C9 idle studio/flutter containers | 2080-tiw8 |
| C | C10 representation-testing guards | 2080-5qje |
| C | C11 compact plan/issues, steps, index | 2080-jrvv |
| C | C12 repo-root clutter allowlist | 2080-empx |

## Already covered by existing rows (linked, not duplicated)

- 2065-5vcv (forge src tmpfs fills under multi-agent Flutter) is ALREADY
  `obsoleted` as a duplicate of 1878-2cwt (disk preflight and worktree eviction),
  1866-ubtc (src tmpfs pruning) and the OpenSpec change
  `forge-storage-single-root-and-disk-discipline` task group 2. It is not
  reopened; it stays as the demon-attack-3e evidence. A6 records the successor
  chain on it with a note event.
- OpenSpec `forge-storage-single-root-and-disk-discipline` task group 2 already
  plans a per-lane scratch volume at `/home/forge/scratch` with TMPDIR moved
  (tasks 2.1 to 2.3, all unticked). A1 and A2 are the operator's `cold` ruling
  applied to that group: the name is `/home/forge/cold`, and the contents widen
  from TMPDIR to build output, blobs and worktrees. A1 must rename or fold 2.1
  to 2.3 rather than build a second volume.
- 2048-wu3h (forge-lua-helpers, five hot image helpers) is the existing home of
  B8's first slice. B8 depends on it and does not repeat its five helpers.
- 1443-6r3q (Lua bash replacement and command policies engine) is the umbrella
  for B. B1 to B9 are children by theme; a note event links them.
- 981-a4t4 (ten of seventeen OpenSpec changes over 90 days untouched) and the
  per-change triage rows beside it (for example artifact-namespace-prefix-versioning,
  control-wire-pty-attach, dev-control-mcp, vm-recipe-provisioning) own the over-90-day
  slice of C4. C4 owns the 30 to 90 day slice and the standing check.
- 2080-dhzf (Hugging Face login) is in flight; C7 coordinates with it and does
  not touch its files until it lands.
- 765-xpct (change-class gate selector) is the precedent C2 builds on; C2 is a
  bar decision and is marked as needing the operator.

## Report A: forge cold storage

Operator ruling: the forge `/home/forge/src` tmpfs is EXPENSIVE (RAM, counted
in the forge memory cgroup); it holds hot-path source only. Builds, blobs, temp
and worktrees go to cheap disk. Agents must learn this on landing.

Verified today:
- `compute_source_budget_with` in crates/tillandsias-core/src/config.rs clamps
  the high-water and declared sizing to `memory_max_mib / 2`, on top of
  `compute_source_budget`'s pack-size times `hot_path_inflation` rule with the
  `hot_path_source_floor_mb` floor. Those are the stale sizing rules A3 replaces:
  once only hot source lives there, neither the half-of-memory clamp nor the
  pack times four inflation describes anything real.
- Nothing in the tree mentions `TILLANDSIAS_COLD` or a `forge-df` helper.
- openspec/specs/forge-hot-cold-split/spec.md names four HOT paths
  (`/opt/cheatsheets`, `/home/forge/src`, `/tmp`, `/run/user/1000`) and says
  "build artefacts ... remain COLD" but defines no cold mount point, so the
  agent has no path to put cold things on. A6 reconciles the spec with the
  ruling.
- Seeds that must carry the guidance exist: the `forge-quick-intro` skill (in
  skills/ and the per-agent skill directories), images/default/config-overlay/mcp/forge-agent-guidance.md,
  images/default/opencode.json and its instructions, and images/default/forge-welcome.sh
  (194 lines). There is no forge-side CLAUDE.md or AGENTS.md seed.

Streams: A1 cold volume; A2 redirect CARGO_TARGET_DIR, TMPDIR, Flutter and
Gradle build dirs and agent worktrees to it; A3 .git off the tmpfs and the
sizing rule replaced; A4 `forge-df` plus a real-size banner; A5 guidance seeds;
A6 spec reconcile.

Order: A1, then A2 and A3 in parallel, A4, then A5 and A6 (guidance is written
once the paths are real).

## Report B: shell to Lua

Audit numbers (not re-measured here beyond the Lua count): 210.6K bash lines,
+66K net in 60 days, 57% of that test fixtures. Re-check: scripts/lua holds 290
Lua scripts, plus a handful in crates/tillandsias-plan/lua, images/default/lua and
crates/tillandsias-plan/hooks, and there is no shared library directory (no
lib/lua). The runtime is mlua via `tillandsias-plan script run`.

Rationale: every new fixture re-implements arm, run, git and read helpers; no
agent can discover what already exists; and the tree gains shell faster than it
loses it. The memory-recorded backlog direction applies: advisory, then gentle
(due PRs carry one item or a Carried-Waiver trailer), then enforced, shell-to-lua
first. B9 is the enforcement step and is a bar raise, so it is BLOCKED on the
operator.

Order: B1 first (discovery), B2 and B3 together, B4 as the pilot that proves B2,
B5, B6, then B7 waves and B8. B9 waits for the operator and for B4 to show the
port cost.

## Report C: infra simplification

Verified today:
- `command-policy-audit.jsonl` is written by crates/tillandsias-plan/src/command_policy.rs
  (`AUDIT_BASENAME`) with no rotation. In the checkout, `.cache/metrics/command-policy-audit.jsonl`
  is 3.46 GB (the audit's 3.4 GB). The per-host copy the runtime resolves to,
  `~/.cache/tillandsias/metrics/command-policy-audit.jsonl`, is 13.3 GB on the
  operator desktop, which is the larger problem. Other unrotated jsonl beside
  it: tillandsias-timing 161 MB, forge-expert-usage 84 MB, litmus-step-timing 51 MB.
  The host disk is 65% used (614 of 952 GB); target/ is reported at 405 GB. Disk
  fill-ups froze the operator desktop before.
- tillandsias-fleet-core: a workspace member (2 source files, about 400 lines:
  lib.rs and score.rs). Symbol-level search for `tillandsias_fleet_core` and
  `fleet-core` finds NO dependent in any Cargo.toml or Rust source; only the
  workspace member list, its own manifest, a comment in plan/fleet/services.yaml
  and the closed 1548 fleet-wan-rendezvous fragments. It is not strictly dead by
  intent: 1548-9n28 designed it to run unchanged inside a Cloudflare Worker
  (wasm32 build proven). So "no dependents today", not "dead"; C3 must decide
  delete versus an explicit allowlist reason.
- crates/tillandsias-litmus: no Cargo.toml, not a workspace member, contains a
  README.md and src/mock/podman.rs.example only. Referenced as file paths by
  methodology/litmus-framework.yaml and methodology/litmus-centicolon-wiring.yaml.
  Dead as a crate; removal must fix those methodology references. (The live
  crate is tillandsias-litmus-rust.)
- tillandsias-static-server is NOT dead: observatorium.sh builds and runs it.
  Evaluate only, after the observatorium-static-html change archived 2026-11-11.
- OpenSpec: `git log` shows about 20 active changes with no commit in 30 days
  (nanoclawv2-orchestration oldest at 146 days), and 11 more with none since
  before June; the audit counted 12 over 30 days by another measure. C4 uses the
  git last-touch date as the definition and states it.
- images/web and images/web-wrangler both exist and are both embedded by
  crates/tillandsias-embed/build.rs.
- scripts/check-issue-citation-convention.sh and the scorable-obligation checks
  gate the shape of what this issue files.

Model fetchers named by the audit: imagegen_models, restricted_fetch,
llama-server-lane and enclave-fetch. C5 is HIGH RISK because the licence gates
(accept-licence skill, restricted register, the 2071-um56 operator rulings) must
survive the merge byte for byte in behaviour.

Order: C1 first (it is a live hazard), then C3, C4, C12 (cheap), then C6, C9,
C10, C11; C2 and C5 and C7 and C8 wait on operator or in-flight work.
