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
   the consent classes `soft-reset` (`--reset-state`, Linux `--reset-guest`,
   the podman reset inside them — `host-state-lifecycle` SOFT; allow in a
   forge), `hard-reset` (`--reset-guest` on a guest regime, `wsl
   --unregister`, the VM dir wipe; deny in a forge), `workspace-destroy`
   and `force-push`. The seed `.tillandsias/command-policies.yaml` may add
   rules or tighten; a loosening rule is refused at load
   (`refused:policy-seed:cannot-loosen`) and the engine answers from the
   floor — a seed must never be the way around a fail-closed rule.
   Unmatched requests ALLOW until the default flips, and the flip is
   MEASURED, not dated (operator ruling 2, 2026-09-27: "Deny after a
   measured time period"): `default: {deny_after_quiet_days: N}` flips to
   deny once the host's audit shows N consecutive days with zero deny and
   zero ask from `caller=pretooluse`; N = 14, operator-confirmed
   2026-09-27 ("14 days is a good starting point").

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

7. **Consent is per run and operator-minted; SOFT reset is pre-authorised
   in forges, HARD reset never is.** Operator ruling 3 (2026-09-27),
   verbatim: "Forges should keep pre-authorizing SOFT RESET always. HARD
   RESET should require explicit approval each time." `policy consent
   grant <class> [--ttl]` writes a 0600 token under the runtime dir;
   `evaluate` consumes it on first use; the grant verb refuses in a forge
   (a peer cannot commit operator spend). `soft-reset` is allowed in a
   forge always (`consent_source=forge-policy`) and on bare metal by the
   two registered smoke skills' `TILLANDSIAS_DESTRUCTIVE_RESET_OK=1`
   (`consent_source=env`; `=0` stays the one opt-out) or a token.
   `hard-reset` takes a per-run token EVERY time, has no environment
   pre-authorisation and none may be added, and is never grantable in a
   forge. The fleet rule (1004-vsh2) and `destructive_reset_policy` both
   survive and stay distinguishable in the audit.

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
    operator flipping the Bash tool default. Its settings entry is
    COMMITTED (operator ruling 1, 2026-09-27: "Commit the hook to the
    project"): `.claude/settings.json` in this repository and the forge
    overlay `images/default/config-overlay/claude/settings.json` both
    carry the PreToolUse entry with a repo-relative command path.

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
    realised as `refs/tillandsias/discipline/<level>/<enforcement>/<derived>/<sha256[:12]>/<epoch>`
    pointing at the seed BLOB, kept single by `publish-discipline.sh` on
    the same tick as `run_auth_probe`, read by `ls-remote` (level,
    enforcement, derived level, digest — "the level of branch discipline
    being actively enforced", in the operator's words) or `fetch` +
    `cat-file` (bytes). The first draft's opt-in probe push
    (`refs/tillandsias/discipline-probe/*`) is DROPPED by operator ruling 5
    (2026-09-27); it was load-bearing nowhere — only this design's own
    artifacts mentioned it. Pre-receive reads the seed from the
    integration branch's tree (level 0 advised when absent), runs the
    derivation (decision 16) and applies each rule at its enforcement only
    where seed and derived agree: under an enforced, observed rule it
    refuses `refs/heads/<default_branch>` with the seeded message BEFORE
    `tillandsias-relay-refs` and refuses grammar violations; under warn it
    warns (today's `warn_if_outside_branch_grammar`, but with `work/` now
    admitted); a seed ahead of reality degrades to the warning naming the
    missing qualifier; a project with no seed is never refused. Freeze
    visibility in forges is 1429-4y9f's fix, a dependency here.

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

15. **Hooks are templates, installed on demand per project for its level
    (operator ruling 7, 2026-09-27).** Verbatim: "Fresh new projects opened
    in a tillandsias forge should be allowed to push to main by default. As
    projects grow and their own gates rise they should be able to install
    the hooks on demand, per project, these hooks should then trigger on
    the push through the git-mirror, at their relevant events (pre/post -
    commit/push/pull/etc) and return not only the ERRORS but the
    AFFORDANCES: 'this project at this state needs work in X format, use
    /<skill> for instructions'. This automatic wiring should be the desired
    state on any project checked out on a forge." The plan binary embeds
    one Lua template per client event (`pre-commit`, `post-commit`,
    `pre-push`, `post-merge`, `post-checkout`) and per mirror event
    (`mirror-pre-receive`, `mirror-post-receive`); `discipline
    install-hooks` writes the ones the effective level needs into a
    repo-LOCAL hooksPath (never global, 1442-wyf9) as bash-3.2 stubs that
    exec the sandboxed `lua` CLI and fail closed; level 0 gets advisory
    hooks only and NOTHING refuses its push to main; `discipline raise --to
    <n>` bumps the seed forward-only and installs that level's hooks; a
    project's `.tillandsias/hooks/<event>.lua` overrides the template.
    Commit and pull events are client-side; push events are the mirror's:
    `dispatch-project-hooks.sh` runs the project's mirror templates through
    the plan binary shipped in the git image, sandboxed (Observing, fs
    rooted at a scratch export of the pushed tree, read-only git verbs, no
    network, 60 s deadline that rejects on expiry) and relays a refusal
    WITH its `why:`/`remedy:` to the pushing client. Every template refusal
    reads `remedy: this project at level <n> (<rule> <enforcement>) needs
    <requirement>; use /<skill> for instructions`, the skill from the
    seed's `skills:` map; the generic `project-discipline` skill ships in
    every forge overlay so the sentence resolves for projects that are not
    Tillandsias. The forge runs `install-hooks` for every checked-out
    project (today `ensure_forge_project_guard_hooks` skips non-Tillandsias
    checkouts). Tillandsias's own `scripts/hooks/*` are its level-2
    project hooks and the high-enforcement example; they are not
    rewritten. Rows: 1446-xqi6, 1446-87cy, 1446-qkx4.

16. **The level is derived and checked against the seed (operator ruling
    4: "We should try to derive the discipline but check against
    reality").** `discipline derive` observes the remote's HEAD branch, the
    integration branches on origin, distinct committer hosts in the last 50
    commits, `work/<id>` refs on origin, pull-request merges on the default
    branch and the installed hooks, and prints `derived=<n> seed=<n|none>
    effective=<n>` with each qualifier's observed value and the command
    that observed it. Neither side is authoritative alone: a rule refuses
    only where the seed says enforced AND the qualifier is observed; a
    seed ahead of reality degrades to `warn:…:seed-ahead-of-reality`
    naming the missing qualifier (a project may opt in early but cannot
    enforce what it has not earned); a project that has outgrown its seed
    is told `discipline raise --to <derived>` and is never refused on the
    seed's behalf; observed level 0 is never refused. The mirror publishes
    `derived` in the ref so client and server agree on both numbers. The
    integration branch is per project and comes only from the seed
    (ruling 6); enforcement is raised organically, per rule, by `raise`.
    Row: 1446-664f.

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
   1443-w79y (landed on its work ref by macbookair) and 1443-sb9b (in
   progress there) in parallel, then 1443-z3vb and 1443-we89.
2. Wire the bridge hook into the committed `.claude/settings.json` and the
   forge overlay; measure one day of decisions before widening the shapes.
3. Derivation (1446-664f); mirror enforcement (1443-uit6) after 1429-4y9f;
   fixture scope (1443-fpck); consent (1443-9f5w); audit (1443-w9hf).
4. Hook templates and on-demand install (1446-xqi6), the skill
   (1446-qkx4), mirror dispatch (1446-87cy); MCP door (1443-r4cj); Lua land
   tool (1443-u66u).
5. Deciders' retirement rule (1443-xkwb) alongside 1384-bxhk; port scripts
   on touch per 1384-ddua; litmus steps per 902-5bf9; launcher per
   1384-j3cv.
6. Retire the bridge when its printed condition holds.

Rollback: every slice is additive (new verbs, new tokens, new files); the
policy default is allow; the bridge has a kill switch; the mirror's
discipline refusals are behind the seed's presence (a project can remove its
seed to fall back to the default, which still protects the HEAD branch).

## Open Questions

None. The seven questions of the first draft were answered by the operator
on 2026-09-27 (design note §8 records each ruling verbatim and where it
landed), and N = 14 was confirmed the same day. The level's determination
is BOTH derived and declared, checked against each other (decision 16); the
probe-push namespace is gone from the requirements and packets (decision
12) and kept below as a parked alternative.

## Parked alternative (not a requirement, not a packet)

**Discipline probe push.** Kept at the operator's request (2026-09-27:
"Drop the probe-push namespace, but keep the document in case we need it
later, it could work for something else").

- *What it was:* a client that wanted the mirror's OWN wording of the
  enforced discipline, without changing any ref, would push an empty
  commit to `refs/tillandsias/discipline-probe/<epoch>`; the mirror's
  pre-receive would ALWAYS reject that namespace and put the discipline
  lines (level and enforcement, default branch, integration branches, work
  grammar, rebase guidance) in the rejection message. A rejected push
  mutates nothing on the mirror or upstream, and the local pre-push gate
  already exempts `refs/tillandsias/*` (1176-9vqn), so the round trip was
  side-effect free.
- *Why it was dropped:* it existed to stand in for the operator's
  "`--dry-run` push" idea, and that idea cannot work as stated — `git push
  --dry-run` sends no ref commands, so a pre-receive hook never runs for
  it. Once the mirror publishes
  `refs/tillandsias/discipline/<level>/<enforcement>/<derived>/<digest>/<epoch>`
  on every reconcile tick, a plain `ls-remote` answers the same question
  with no push at all, and the probe added a second path to one answer.
  It was load-bearing nowhere.
- *What it could serve later:* any question a client wants the SERVER to
  answer at push time rather than from a published ref — for example a
  "would this ref be accepted" check that runs the project's own
  `mirror-pre-receive.lua` (decision 15) against a candidate tree without
  relaying it, or a per-push capability handshake where the rejection
  message carries the mirror's runtime version and the templates it can
  dispatch. If revived, it stays a rejected push into a reserved
  `refs/tillandsias/*` namespace, so nothing it does can be mistaken for a
  ref update.
