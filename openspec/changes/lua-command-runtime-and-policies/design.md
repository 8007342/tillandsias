# Design — lua-command-runtime-and-policies

Umbrella packet: `1443-6r3q`. Code is cited by SYMBOL; nothing here is a
line number. Companion note with the packet table and the open questions:
`plan/issues/lua-bash-replacement-and-policies-design-2026-09-27.md`.

## Context

What exists (read before designing; none of it is re-filed):

- `crates/tillandsias-exec` (1252-fg9e): `Command::new(argv)` with
  `current_dir`, `env`, `env_clear`, `stdin_bytes`, `timeout`, `group`;
  `Output { completion, stdout, stderr, run: RunId, argv }`;
  `Completion::{Exited, Signaled, TimedOut}`; `Pipeline::pipe_to` that passes
  bytes in memory (no OS pipe); process-group kill on Unix, a job object on
  Windows. No capture bound.
- `crates/tillandsias-plan/src/lua_predicate.rs`: `PredicateClass::{Cacheable,
  Observing}`, `build_environment`, `proc_run` (fields `PROC_RUN_FIELDS`,
  default `PROC_RUN_DEFAULT_TIMEOUT_MS`, base env
  `PROC_RUN_BASE_ENV_PASSTHROUGH` / `PROC_RUN_BASE_ENV_FIXED`,
  `is_shell_string_call` over `SHELL_PROGRAMS`), `sh.run`/`expert.shell`,
  repo-rooted `fs.read` and the Observing-only `register_fs_write_verbs`
  with the symlink containment of `containment_path` (1411-b5fk, 1412-n5cp).
- `crates/tillandsias-plan/src/lua_std.rs`: `json`, `yaml`, `hash`, `path`,
  `time` tables; sorted `pairs`, `next` withheld (1384-bp6t).
- `run_lua_cli` (`tillandsias-plan lua`, sandboxed by default, 1375-btuf)
  and `run_predicate_cli`; `scripts/archive-plan-packets.lua` is the one
  script already ported.
- 1363-xp2v (research, ready): the progressive branching-discipline
  ladder and the operator's 2026-09-22 ruling (levels forward-only; a
  per-level advised → warn → enforced ratchet; an absolute floor where a
  bare project pushes freely to its default branch). This change files the
  evaluator slice that row anticipated and leaves the ladder's
  determination to it.
- The 2026-09-26 design (`plan/issues/scripting-runtime-lua-no-pipes-design-2026-09-26.md`)
  and its rows: 1384-aixy (`proc.spawn`, streams — in progress), 1384-bqhy
  (`script run` + `verdict`), 1384-bxhk (shell ratchet), 1384-ddua (three
  deciders ported), 1384-j3cv (build.sh launcher); 1375-amye (`run` verb);
  902-5bf9 (litmus `steps:`).
- Landing: `scripts/land-on-platform-branch.sh` (one attempt loop, no
  functions, thirteen `refused:land:*` tokens, `ok:land`,
  `ok:land-adopts-valid-stamp`; gate is `./build.sh --check`; proof is
  `merge-base --is-ancestor` after fetch; it never reads freeze refs and
  never writes a stamp). `scripts/hooks/pre-push-local-gate.sh`
  (`refuse`, `work_lane_affordance`, `enforce_stamp_scope`,
  `enforce_release_freeze`, `attempt_plan_only_lane`).
- Mirror: `images/git/pre-receive-hook.sh` (`warn_if_outside_branch_grammar`
  is warn-only; no protected-branch refusal; grammar from
  `TILLANDSIAS_BRANCH_CREATION_REGEX` in `entrypoint.sh`, which lacks
  `work/`), `relay-refs.sh` (GH006 → ADVICE after the fact),
  `probe-upstream-auth.sh` (`refs/tillandsias/upstream-auth/<state>/<epoch>`,
  one ref kept, on `run_auth_probe`'s 120 s tick), `publish-sync-state.sh`,
  `reconcile-exported-heads.sh` (exports `refs/heads/*` only — 1429-4y9f).
- Policy today: none. `crates/tillandsias-policy` is a check CLI, not an
  engine. Host kind is `TILLANDSIAS_HOST_KIND` (self-declared) plus
  `/run/.containerenv` and the `.forge-startup-context.md` marker
  (`tillandsias_agent_platform` in `scripts/agent-identity.sh`). Consent:
  the smoke skills' `TILLANDSIAS_DESTRUCTIVE_RESET_OK` and the workstation
  rule in `skills/smoke-curl-install-and-test-e2e/SKILL.md` (1004-vsh2);
  `clear-vault-host-credentials.sh` refuses `no-destructive-consent`.
  Credential rules live in skills (1025-a896), not methodology.
- Claude Code hooks: none in the repo (`.claude/settings.json` only
  enables the two MCP servers).

## Goals / Non-Goals

**Goals**

- Agents execute commands as argv with named parameters through the
  runtime, with no shell string anywhere on the path, on every locus.
- A declarative, versioned, tighten-only command policy decides allow /
  deny / consent per command family, host kind and regime; every refusal
  carries why and remedy; every decision is audited with secrets redacted.
- A temporary bridge catches the seven measured shapes at the Bash tool
  boundary and carries its own removal criterion.
- Branch discipline is seeded per project, enforced and published by the
  mirror, and the land tool asks the runtime where to land; today's land
  guarantees hold by construction.
- Every packet fails on today's code and closes on a runnable fixture.

**Non-Goals**

- Re-filing the executor, `proc.spawn`, `script run`, the ratchet, the
  decider pilot or the litmus step form.
- A general bash parser: the bridge classifier is lexical over seven named
  shapes; 1252-r72q's tree-sitter lint is the parser and the classifier
  hands over to it.
- Signing or attesting Lua script provenance (1252-hsrz already names it
  as its own row).
- Enforcing a deny-by-default posture in this phase (operator decision).
- Editing the credential and reset specs sibling sessions are amending.

## Decisions

1. **The runtime is the existing one; this change adds doors, not a second
   executor.** `tillandsias_exec::Command` stays the only spawn path.
   `run_verb.rs` (1375-amye and 1443-8pur share it) and the MCP
   `run_command` tool both call it after `command_policy::evaluate`. The
   Lua doors already do (`proc_run`, the `sh.run` closure) and gain the
   policy call before `Command::new`.

2. **Named parameters are flags and fields, never a string.** `run` takes
   `--cwd`, `--env K=V`, `--timeout-ms`, `--capture-bytes`, `--stdin-file`,
   `--json`, `--exit-with-child`, then `--` and the argv. `--argv-json -`
   reads the argv as a JSON array from stdin. That form is REQUIRED on Git
   Bash and for any cross-locus dispatch, because both failure-shape-4
   incidents were an argument crossing a shell boundary as text (MSYS
   `\.`→`/.`; `wsl.exe … bash -lc` losing quotes). Cross-locus dispatch
   itself stays in the one constructor 795-jjw3 allows (`wsl.rs`).

3. **Bounded output is an executor property with a visible field.**
   `Command::capture_bytes(n)` (default 8 MiB) keeps draining past the cap
   (no deadlock), reports `truncated:true` and `dropped:<n>`, and every door
   maps that to `ok:false`. A clipped capture that looks whole is the
   `tail -1` defect in another form (1252-fg9e); a timed-out run still
   returns no partial output.

4. **The policy engine is a compiled-in floor plus a tighten-only seed.**
   `command_policy.rs`: `Request { argv, cwd, env_keys, host_kind, platform,
   regime, caller }`, `Rule { id, match, decision, hosts, class, why,
   remedy }`, `Decision::{Allow{rule}, Deny{rule, why, remedy},
   Consent{class, why, remedy}}`. The floor: `no-shell-strings`
   (`is_shell_string_call` moves here), `no-credential-mutation`,
   `substrate-reset` (consent on bare metal, deny in a forge). The seed
   `.tillandsias/command-policies.yaml` may add rules or tighten; a
   loosening rule is refused at load (`refused:policy-seed:cannot-loosen`)
   and the engine answers from the floor — a seed must never be the way
   around a fail-closed rule. Unmatched requests ALLOW in this phase
   (migration, not enforcement; same posture as `work_ref_lane`), and the
   seed's `default:` field is where the operator flips it.

5. **Host kind and regime are inputs, not trust.** Host kind is derived
   from the env var, the container file and the forge marker together and
   a disagreement is reported in the decision (a self-declared host kind is
   not a security fact, per the mirror architecture audit). Regime is
   `interactive | gate | fixture | hook | relay`, set by the caller that
   owns the run (the litmus runner exports `fixture`; build.sh's loop
   exports `gate`; hooks export `hook`).

6. **Refusals carry the 1247-amcu shape.** Verdict token on stdout,
   `  why:` and `  remedy:` on stderr; the remedy names a concrete
   alternative (argv spelling, `policy consent grant`, the operator-only
   `--github-login --with-token` path). The land tool's and the mirror's
   discipline refusals print the seed's own message.

7. **Consent is per run, operator-minted, host-bound, consumed once.**
   `policy consent grant <class> [--ttl]` writes a 0600 token under the
   runtime dir; `evaluate` consumes it on first use. Never grantable in a
   forge (a peer cannot commit operator spend). The smoke skills' env
   pre-authorisation maps to `substrate-reset` only for the two registered
   skills, with `consent_source=env` in the audit, so the fleet rule
   (1004-vsh2) and the methodology rule (`destructive_reset_policy`) both
   survive and stay distinguishable.

8. **Fixture filesystem scope makes 1442-22d2 a class, not a case.** Under
   `regime: fixture`, `fs.write`/`fs.mkdir` and write-shaped argv
   (`gate-stamp.sh write`, `git update-ref`, `git push`, `rm` under the git
   dir) are refused outside `TILLANDSIAS_FIXTURE_SCOPE` and always inside
   the real checkout's git dir. The litmus runner exports both. 1442-22d2's
   own fix (snapshot/restore, `refuse_borrowed_stamp`) stays; this removes
   the write before it happens.

9. **The audit is a per-host JSONL under `.cache`, redacted before
   formatting.** Never the shared timing path (1204-3s2s). The bridge
   hook's retirement condition is computed from it.

10. **The bridge is a PreToolUse hook whose brain is Rust.** The stub is
    bash-3.2-clean and under sixty lines; it hands the tool JSON to
    `tillandsias-plan policy classify-bash`. Deny = exit 2 with the refusal
    on stderr; ask = `permissionDecision: "ask"` JSON; allow = exit 0
    silently; unknown shapes allow (a bridge that refuses what it does not
    understand stops the fleet). The seven shapes and their lexical grammar
    are in the classifier header; `--status` prints the counts and the
    retirement condition; `TILLANDSIAS_PRETOOLUSE_HOOK=off` is the logged
    kill switch. Removal: 1443-8pur and 1443-r4cj closed on every locus,
    zero deny/ask from `caller=pretooluse` for fourteen fleet days, and the
    operator flipping the Bash tool default.

11. **Branch discipline is a per-project seed carrying 1363-xp2v's two
    axes, with an absolute floor.** `.tillandsias/branch-discipline.yaml`
    (`level` 0|1|2 — bare, integration branch + PRs, work refs into
    integration; forward-only — per-rule `enforcement` advised|warn|enforced,
    `default_branch`, `integration` per platform, `work_ref`, `salvage_ref`,
    `plan_only_lane.paths`, `freeze_namespace`,
    `messages.default_branch_denied`). The operator's ruling of 2026-09-22
    on 1363-xp2v binds: a level once earned is never given back, each level
    ratchets advised → warn → enforced per rule, and a bare project (no
    seed) pushes freely including to its default branch — NOTHING refuses
    at level 0. Tillandsias's seed is level 2 with default-branch
    protection enforced and the ref grammar at warn (work_ref_lane:
    migration, not enforcement); it reproduces
    `multi_host_development.branch_inventory` and `branch_namespaces`
    exactly, and the methodology gains one pointer key and stays the prose
    authority. `branch_discipline.rs` parses, validates (integration ≠
    default at level ≥ 1; regex compiles; level never lower than last
    published), and answers `show`, `target`, `check-ref` with level and
    enforcement on every answer; forge-plan exposes `discipline_show`. The
    level is DECLARED by the seed today; whether it is derived from
    observable facts is 1363-xp2v's research and is not pre-empted.

12. **The mirror answers with a published ref, because a dry-run cannot
    be answered.** `git push --dry-run` sends no ref commands, so the
    server's pre-receive never runs; the operator's "dry-run push" is
    realised as (a) `refs/tillandsias/discipline/<level>/<enforcement>/<sha256[:12]>/<epoch>`
    pointing at the seed BLOB, kept single by `publish-discipline.sh` on
    the same tick as `run_auth_probe`, read by `ls-remote` (level,
    enforcement, digest — "the level of branch discipline being actively
    enforced", in the operator's words) or `fetch` + `cat-file` (bytes);
    and (b) an opt-in probe push to `refs/tillandsias/discipline-probe/<epoch>`
    that the hook always rejects with the discipline lines — a rejected
    push mutates nothing and the local pre-push gate already exempts
    `refs/tillandsias/*`. Pre-receive reads the seed from the integration
    branch's tree (level 0 advised when absent) and applies each rule at
    its enforcement: under an enforced rule it refuses
    `refs/heads/<default_branch>` with the seeded message BEFORE
    `tillandsias-relay-refs` and refuses grammar violations; under warn it
    warns (today's `warn_if_outside_branch_grammar`, but with `work/` now
    admitted); a project with no seed is never refused. Freeze visibility
    in forges is 1429-4y9f's fix, a dependency here.

13. **The land tool asks first, in bash, then becomes Lua.** 1443-z3vb adds
    the probe at the top of the attempt loop (`check-ref` on the target,
    the platform's integration branch when none is named, digest compare
    against the mirror ref) with new additive tokens
    (`refused:land:discipline:*`, `land:target:<b>:from=<src>`). 1443-u66u
    ports the whole tool to `scripts/lua/land-on-platform-branch.lua`: every
    existing token byte-identical (the thirteen land fixtures are the
    interface), every git/gate command a `proc.run` with a deadline,
    `gate-stamp.sh verify` read as a value (a `stale:fixture-borrowed-stamp`
    is never adopted), the freeze read through the exported refs and
    refused before the gate (`refused:land:frozen:<b>`), and the `.sh` a
    fail-closed stub. Guarantees kept: gate-before-push, proof against the
    remote, freeze, stamp integrity.

14. **Deciders retire by a number.** A bootstrap-shell allowlist names what
    must stay shell (installers, the cargo bootstrap, hook stubs, image
    entrypoints before the binary ships). The three bash deciders print
    `population=<n> bootstrap=<b>` on STDERR (their stdout verdict is an
    interface) and `check-decider-retirement.sh` prints `retire:<decider>`
    when the two are equal. 1384-bxhk's ratchet counts the whole tree; this
    gives each decider its own denominator.

## Risks / Trade-offs

- **False denies stop the fleet.** The bridge classifier is lexical; its
  negative arms (quoted heredoc with backticks, a pipe with no verdict
  consumer) are the guard against over-matching, and unknown shapes allow.
- **A self-declared host kind.** Until the mirror architecture audit's
  recommendation lands, `TILLANDSIAS_HOST_KIND` can be set by anything; the
  engine reports disagreement with the container file and the marker but
  cannot prove either.
- **Allow-by-default is a migration posture.** It means the engine only
  bites on named families until the operator flips `default:`; the audit
  makes the moment measurable.
- **Two seeds are two more files a project can get wrong.** Both fail
  closed at load and fall back to the built-in floor/default with
  `source=default` in every answer, so a broken seed cannot loosen anything.
- **Pre-receive changes are the fleet's only server-side gate.** The scratch
  mirror fixture is hermetic and the negative arm keeps relay behaviour
  identical for the integration branch.
- **The Lua land tool is the push decision.** It is the last slice of its
  chain, gated by all thirteen existing fixtures plus two new ones.

## Migration Plan

1. Drain the vertical slice: 1443-esm5 → 1443-isrk → 1443-8pur, with
   1443-w79y and 1443-sb9b in parallel, then 1443-z3vb and 1443-we89.
2. Wire the bridge hook (operator decides project settings vs per host);
   measure one day of decisions before widening the shapes.
3. Mirror enforcement (1443-uit6) after 1429-4y9f; fixture scope
   (1443-fpck); consent (1443-9f5w); audit (1443-w9hf).
4. MCP door (1443-r4cj); Lua land tool (1443-u66u).
5. Deciders' retirement rule (1443-xkwb) alongside 1384-bxhk; port scripts
   on touch per 1384-ddua; litmus steps per 902-5bf9; launcher per
   1384-j3cv.
6. Retire the bridge when its printed condition holds.

Rollback: every slice is additive (new verbs, new tokens, new files); the
policy default is allow; the bridge has a kill switch; the mirror's
discipline refusals are behind the seed's presence (a project can remove its
seed to fall back to the default, which still protects the HEAD branch).

## Open Questions

Listed for the operator in the design note §8; the two that shape the first
slice: where the PreToolUse settings entry lives (committed project
`.claude/settings.json` vs per-host), and whether the policy default flips
to deny-by-default at a date or at a measured number.
