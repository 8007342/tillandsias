# Lua bash replacement and command policies engine (design)

Umbrella packet: `1443-6r3q`. OpenSpec change:
`openspec/changes/lua-command-runtime-and-policies/`. Draft durable specs:
`command-runtime`, `command-policies`, `branch-discipline`.

- Date: 2026-09-27. Author: macuahuitl (Fable architect session, delegated by
  the coordinator). Base: origin/linux-next `73338548b`.
- Operator direction (2026-09-27, verbatim in the delegation): "a LUA runtime
  for BASH execution with named parameters and NO PIPES … the full LUA
  runtime to replace unbounded bash, we'll add BASH POLICIES"; and
  "land-on-platform-branch might need to be a .lua … SEED some BRANCH
  DISCIPLINE, where this land-on-platform-branch might just check from our
  land discipline if main (the default branch) is blocked on remote … the
  git mirror should then respond with the level of branch discipline being
  actively enforced for the checked out project … our landing branch
  decision can make use of the RUNTIME FACILITIES like the git-mirror, or
  even the local experts."
- Builds on `plan/issues/scripting-runtime-lua-no-pipes-design-2026-09-26.md`
  (the execution model, determinism rules, ratchet, pilots) and
  `plan/issues/lua-runtime-host-dependency-replacement-design-2026-09-26.md`
  (jq/yq/timeout inventory). This note does not repeat them; it adds the
  agent doors, the policies engine, the bridge and the branch discipline.
- Code is cited by SYMBOL; nothing here is a line number.

## 0. The answer in six lines

1. The executor and the Lua doors exist (`tillandsias_exec::Command`,
   `proc_run`, `sh.run`, the sandboxed `run_lua_cli`); this change adds the
   AGENT doors: `tillandsias-plan run … -- <argv>` with named flags, `--json`
   and `--argv-json -`; an MCP `run_command`; a capture bound.
2. A COMMAND POLICIES engine (`command_policy.rs`) sits inside every door:
   compiled-in floor (no shell strings, no credential mutation, destructive
   classes need consent) plus a per-project seed that can only tighten;
   keyed by command family, host kind, regime; why+remedy on every refusal;
   per-run consent tokens; audited with redaction.
3. The bridge is a Claude Code PreToolUse hook whose brain is Rust
   (`policy classify-bash`), matching the seven measured shapes, with its
   retirement condition printed by `--status`.
4. Branch discipline is a per-project seed `.tillandsias/branch-discipline.yaml`
   read by `tillandsias-plan discipline`, a forge-plan MCP tool, the mirror's
   pre-receive, and the land tool.
5. The mirror publishes `refs/tillandsias/discipline/<level>/<enforcement>/<digest>/<epoch>`
   — the level actively enforced, readable by ls-remote — because a
   `git push --dry-run` cannot be answered by a pre-receive hook
   (it sends no ref commands); an opt-in probe push to a namespace the hook
   always rejects gives the server's own wording.
6. The land tool probes the discipline first (bash, 1443-z3vb), then becomes
   Lua (1443-u66u) with every verdict token byte-identical and the freeze,
   stamp-provenance and proof-against-remote guarantees kept.

## 1. Failure shapes this designs against (measured, with the mechanism that closes each)

| # | Shape | Measured | Closed by |
|---|---|---|---|
| 1 | Unquoted heredoc executes prose | 1430-rnpd correction `2aa367c0` and 1256-t3w8: backticked spans lost or EXECUTED (`openspec init`, `openspec update`) | the bridge hook denies `<<EOF` bodies carrying backticks or `$(`; agents write files through `fs.write` / `run --stdin-file` |
| 2 | SIGPIPE under pipefail flips a verdict | 1130-qk7d (twice), 792-ksr8, 795-imz3; 5/5 inversion in 1252-fg9e | no OS pipe exists in the runtime; the bridge denies `… \| grep -q` under pipefail |
| 3 | Succeed-wrongly and `\| tail -1` verdicts | design 2026-09-26 §2 (214 sites), 1252-fg9e | `status` is a value; `truncated` is a field; the bridge denies verdict-through-tail |
| 4 | Quoting lost across a boundary | wsl.exe poweroff as root (smoke v56.9.27.2 windows); MSYS `\.`→`/.` (1425-8wir) | `--argv-json -` puts no argument on a command line; cross-locus stays in `wsl.rs` (795-jjw3) |
| 5 | Dialect drift | 1132-r4mt (`awk \b`), 1374-4u6i, 761-g36m | one vendored interpreter; stubs bash-3.2-clean; deciders retire by population |
| 6 | A fixture writes the real git dir | 1442-22d2 | fixture regime + scope in the engine (`fixture-writes-outside-scope`) |
| 7 | Destructive commands on a peer's say-so | 1004-vsh2 rule; `clear-vault-host-credentials.sh` refusal | consent class + per-run operator token; never grantable in a forge |

## 2. Scope A — execution model (what is new versus what exists)

Exists: `Command::new(argv)`, `current_dir`, `env`/`env_clear`,
`stdin_bytes`, `timeout`, `group`; `Output` with `RunId`; `Completion`;
`Pipeline`; `proc_run` with `PROC_RUN_FIELDS`, `PROC_RUN_BASE_ENV_PASSTHROUGH`,
`PROC_RUN_BASE_ENV_FIXED`, `is_shell_string_call`; `lua_std::register`;
`run_lua_cli`. Filed elsewhere: `proc.spawn`/streams (1384-aixy), `script
run` + `verdict` (1384-bqhy), `run` verb (1375-amye).

New here:

- **`run_verb.rs`** — the agent door. Named parameters are flags; `--`
  separates the argv; `--argv-json -` reads a JSON array on stdin. Result
  JSON: `run_id, status (exited|signaled|timed_out|spawn_failed|policy_denied),
  code|signal, ok, stdout, stderr, truncated, dropped, wall_ms, argv, policy`.
  The verb exits 0 when it ran (status is a value) unless
  `--exit-with-child`. One `run_verb.rs` shared with 1375-amye.
- **`Command::capture_bytes(n)`** — default 8 MiB per fd; drains past the
  cap; `truncated`/`dropped` fields; every door maps to `ok=false`.
- **Base environment only** — the child sees the passthrough set,
  `TILLANDSIAS_*`, the fixed set and the call's additions; a caller's
  `GH_TOKEN` never reaches a child.
- **MCP `run_command`** on project-info — argv + named parameters as JSON,
  handed to the verb on stdin as argv-json, result returned verbatim; a
  policy denial is a result object, not a JSON-RPC error.
- **Harness mapping** — today: the Bash tool through the bridge hook;
  target: agents call `tillandsias-plan run --json` or the MCP tool, and
  the Bash tool is not the default door (operator flips it when the
  retirement condition holds).
- **Locus identity** — the plan binary is native on each locus and found by
  `resolve_plan_binary`; Windows uses `CreateProcess` quoting done once in
  Rust and a job object (`win_job::JobObject`); bash-3.2 hosts need only
  the binary; every stub is under sixty lines and fails closed
  (`blocked:<hook>:no-plan-binary`).

## 3. Scope B — the policies engine

- **Where policies live**: the floor is compiled into `command_policy.rs`;
  the seed is `.tillandsias/command-policies.yaml` in the project
  (versioned, reviewed like code). The mirror enforces the BRANCH rules
  from its own seed (§5); command rules are client-side by nature.
- **Seed shape** (`version`, `default: allow|deny`, `rules[]` with `id`,
  `match {program, args_prefix, args_any, path_scope}`, `decision
  allow|deny|consent`, `class`, `hosts {bare-metal, forge, ci}`, `regimes`,
  `why`, `remedy`). Loader refuses a rule that loosens the floor
  (`refused:policy-seed:cannot-loosen:<id>`) and answers from the floor.
- **Evaluation**: `evaluate(Request) -> Decision`; most specific match
  wins; unmatched → `Allow{rule:"default"}` in this phase. Called from
  `proc_run`, the `sh.run` closure, `register_fs_write_verbs` (scope rules),
  `run_verb`, the MCP arm and `classify-bash`.
- **Host kind and regime**: derived, reported when in disagreement; regime
  set by the owning caller (`fixture` by `run-litmus-test.sh`, `gate` by
  build.sh's loop, `hook` by stubs, `relay` by the land/relay tools).
- **Affordances**: token on stdout, `why:`/`remedy:` on stderr (1247-amcu,
  the shape 1247-lwek is adding to the land tool).
- **Consent**: `policy consent grant <class> [--ttl]`; host-bound 0600
  token; consumed on first use; refused in a forge; the smoke skills' env
  authorisation mapped to `substrate-reset` with `consent_source=env`.
- **Audit**: `.cache/metrics/command-policy-audit.jsonl`, redaction before
  formatting, `policy audit --since`.
- **Network and credential rules**: `no-credential-mutation` (`gh auth
  login|refresh|logout|token`, `git credential approve|reject`, `vault
  login`) and output redaction; the sibling sessions amending the
  credential/reset specs own the prose; this engine cites them.

## 4. Scope C — migration and the temporary bridge

Order: agent doors and the bridge (this change) → hook stubs
(`pre-push-main-branch-affordance` first) → land tool → deciders on touch
(1384-ddua) → litmus steps (902-5bf9) → build.sh launcher (1384-j3cv).

The bridge (`scripts/hooks/claude-pretooluse-command-policy.sh` +
`policy classify-bash`): what it matches and what it does —

1. `<<EOF`/`<<-EOF`/`<< EOF` whose body has a backtick or `$(` → deny;
   remedy `<<'EOF'` or `run --stdin-file`.
2. `set -o pipefail` + a pipeline ending in `grep -q|-m1`, `head`, `sed q`
   → deny; a verdict script piped to `tail -1` → deny; remedy `run --json`
   or `grep -q PAT <<<"$var"`.
3. `gh auth login|refresh|logout|token` → deny; remedy the operator-only
   `--github-login --with-token`.
4. `podman system reset`, `--reset-state`, `rm -rf` outside cwd/TMPDIR/
   scratchpad, `git push --force*` to `main|*-next`, `git branch -D` → ask
   (consent class named in the reason).
5. `wsl.exe … bash -lc "…"` or `bash -c` with a pipe/backtick in the string
   → deny; remedy argv-json through the runtime.
6. A token-shaped literal in the command → deny and redact.
7. Anything else → allow silently; a quoted heredoc with backticks and a
   pipe without a verdict consumer are the negative controls.

Removal criterion (printed by `--status`, pinned by the fixture): 1443-8pur
and 1443-r4cj closed on every locus; the audit shows zero deny and zero ask
from `caller=pretooluse` for fourteen consecutive fleet days; the operator
flips the Bash tool default. `TILLANDSIAS_PRETOOLUSE_HOOK=off` is the
logged kill switch.

Deciders: `check-bash-dialect.sh`, `check-sigpipe-verdict-pipelines-added.sh`
and `check-jq-callsite-ratchet.sh` gain a `population=<n> bootstrap=<b>`
line on stderr (their stdout verdict is an interface) against
`scripts/portability/bootstrap-shell-allowlist.txt`;
`check-decider-retirement.sh` prints `retire:<decider>` when equal. The jq
ratchet retires when its floor reaches zero.

## 5. Scope D — branch discipline and the Lua land tool

- **Two axes, from 1363-xp2v's operator ruling (2026-09-22)**: WHICH LEVEL
  the project has reached (`level: 0` bare — free pushes to the default
  branch; `1` integration branch and pull requests required; `2` work refs
  into the integration branch required — forward-only, never given back)
  and HOW HARD each rule is applied (`enforcement: advised | warn |
  enforced`, ratcheting per rule, never for the ladder as a whole). The
  floor is absolute: a project with no seed is level 0 advised and nothing
  — not the verb, not the mirror, not the land tool — refuses its first
  push. The seed DECLARES the level today; whether it is derived from
  observable facts is that row's open research and is not pre-empted here.
  Tillandsias's own seed: level 2, default-branch protection enforced, ref
  grammar at warn (work_ref_lane: migration, not enforcement).
- **Seed** `.tillandsias/branch-discipline.yaml`: `level: 2`;
  `enforcement: {default_branch: enforced, ref_grammar: warn}`;
  `default_branch: main`;
  `integration: {linux: linux-next, forge: linux-next, windows: windows-next,
  macos: osx-next}`; `work_ref: "work/[0-9]{3,4}-[a-z0-9]{4}"`;
  `salvage_ref: "salvage/<host>/<yyyymmdd>-<slug>"`; `plan_only_lane.paths`;
  `freeze_namespace: refs/tillandsias/freeze/<branch>/<host>/<epoch>`;
  `messages.default_branch_denied: "push to {default} denied: this project
  uses branch {integration} for integration and {work_ref} for work; switch
  to the corresponding branch and rebase to remote"`. Built-in default when
  absent: level 0 advised, `source=default`, nothing refused. The
  methodology stays canonical and gains one pointer key
  (`branch_discipline_seed`).
- **Verb and expert**: `tillandsias-plan discipline show|target|check-ref`;
  forge-plan `discipline_show`; `methodology_ask` already routes
  `branch+macos` to `multi_host_development.platform_branches`.
- **Mirror**: pre-receive reads the seed from the integration branch's tree
  and applies each rule at its enforcement — under `enforced` it refuses
  the default branch BEFORE `tillandsias-relay-refs` with the seeded
  message and refuses grammar violations; under `warn` it warns (today
  `warn_if_outside_branch_grammar` warns on everything outside
  `TILLANDSIAS_BRANCH_CREATION_REGEX`, which lacks `work/` while the
  methodology admits it — the seed fixes that disagreement); a project
  with no seed is never refused. It always rejects
  `refs/tillandsias/discipline-probe/*` with the discipline lines, and
  `publish-discipline.sh` keeps one
  `refs/tillandsias/discipline/<level>/<enforcement>/<digest>/<epoch>` on
  `run_auth_probe`'s tick — the ref name IS "the level of branch discipline
  being actively enforced". Freeze export in forges is 1429-4y9f
  (dependency).
- **The dry-run finding**: `git push --dry-run` sends no ref commands, so no
  pre-receive runs — measured in `probe-upstream-auth.sh`'s own use of it
  (it proves reachability and auth, not acceptance). The published ref is
  the answer; the probe push is the opt-in for server wording.
- **Land tool decision**: probe first (`check-ref` on the target; the
  platform's integration branch when none is named — today the tool lands
  the CURRENT branch, which pushes a work ref as trunk; digest compare with
  the mirror ref → `seed-drift`); then the unchanged sequence: dirty-tree
  refusal, fetch, integrate, trunk merge, stamp adoption or `build.sh
  --check`, push with a deadline, proof by `merge-base --is-ancestor`.
  Additive tokens only: `refused:land:discipline:*`,
  `land:target:<b>:from=<seed|mirror-ref|default>`, `refused:land:frozen:<b>`.
  The Lua port keeps the thirteen `refused:land:*` tokens, `ok:land`,
  `ok:land-adopts-valid-stamp` byte-identical (the thirteen `test-land-*.sh`
  fixtures are the interface), reads `gate-stamp.sh verify` as a value and
  never adopts `stale:fixture-borrowed-stamp` (1442-22d2), reads the freeze
  through the exported refs before the gate.

## 6. Determinism and platform notes carried from the 2026-09-26 design

Locale, order, clock, environment, paths, bytes, randomness and process
defaults are §5 of that design and hold unchanged. Two additions: the
argv-json form is required on Git Bash and for cross-locus dispatch; every
door's result shape is identical on Linux, macOS and native Windows, and
1443-8pur's closure needs a filed event from macbookair and yolanda.

## 7. Packets (fragment `plan/index.d/20260927t175831z-1443-6r3q-…-macuahuitl.yaml`)

| Order | Slice | Role | Size | Tier | Depends on |
|---|---|---|---|---|---|
| 1443-6r3q | umbrella (milestone) | any | S | sonnet | — |
| 1443-esm5 | capture bound on `tillandsias_exec::Command`; `proc.run` maps `ok=false` | any | S | sonnet | — |
| 1443-isrk | policy evaluator core: floor + tighten-only seed, three rules, inside `proc.run`/`sh.run`, `policy eval`, why/remedy | linux | L | opus | — |
| 1443-8pur | agent door `run … -- <argv>`, `--json`, `--argv-json -`, base env, policy before spawn | linux | M | opus | 1443-isrk, 1443-esm5 |
| 1443-w79y | branch-discipline seed + `discipline` verb + MCP `discipline_show` + methodology pointer | any | M | sonnet | — |
| 1443-z3vb | land tool discipline probe (bash), before fetch/gate | linux | M | opus | 1443-w79y |
| 1443-sb9b | first port: `pre-push-main-branch-affordance` to Lua, fail-closed stub | any | M | sonnet | 1443-w79y |
| 1443-we89 | temporary PreToolUse bridge with retirement condition | linux | M | opus | 1443-isrk |
| 1443-uit6 | mirror enforces the seed at pre-receive; publishes `refs/tillandsias/discipline/*`; probe namespace | linux | L | opus | 1443-w79y, 1429-4y9f |
| 1443-u66u | Lua land tool, tokens byte-identical, freeze + borrowed-stamp refusals, stub | linux | L | opus | 1443-z3vb, 1443-sb9b |
| 1443-fpck | fixture filesystem scope in the engine; runner exports the regime | linux | M | opus | 1443-isrk |
| 1443-w9hf | audit log with redaction; `policy audit` | any | S | sonnet | 1443-isrk |
| 1443-9f5w | per-run consent tokens; smoke-skill env mapping with `consent_source` | linux | M | opus | 1443-isrk |
| 1443-xkwb | bootstrap-shell allowlist; population lines; `check-decider-retirement.sh` | any | S | sonnet | — |
| 1443-r4cj | MCP `run_command` on project-info | any | M | sonnet | 1443-8pur |

Drain order: 1443-esm5 → 1443-isrk → 1443-8pur, with 1443-w79y and
1443-sb9b in parallel, then 1443-z3vb and 1443-we89 (the usable vertical
slice); then 1443-uit6, 1443-fpck, 1443-9f5w, 1443-w9hf; then 1443-r4cj and
1443-u66u; 1443-xkwb alongside 1384-bxhk.

Not re-filed, referenced: 1252-fg9e, 1384-aixy, 1384-bqhy, 1384-bxhk,
1384-ddua, 1384-j3cv, 1375-amye, 902-5bf9, 1429-4y9f, 1442-22d2, 1247-amcu,
1247-lwek, 1252-r72q, 795-jjw3, 1025-a896, 1004-vsh2, 1363-xp2v (a note
event cross-references it: fragment
`20260927t175832z-1363-xp2v-note-evaluator-slice-macuahuitl.yaml`).

## 8. Open questions for the operator

1. Where does the PreToolUse settings entry live: committed in the
   project's `.claude/settings.json` (every clone gets the bridge) or per
   host? The architect session did not edit settings files.
2. Does the command policy default flip from allow to deny-by-default at a
   date, or at a measured number (for example, fourteen fleet days with zero
   bridge denials)?
3. Should `TILLANDSIAS_DESTRUCTIVE_RESET_OK=1` keep pre-authorising the two
   smoke skills on smoke hosts (mapped with `consent_source=env`), or should
   every substrate reset take a minted per-run token?
4. Is the branch-discipline seed the canonical authority with the
   methodology pointing at it, or the reverse (the seed generated from the
   methodology)? This design keeps the methodology canonical and the seed a
   projection.
5. The seed DECLARES the project's level (Tillandsias: 2) and each rule's
   enforcement (default branch enforced, grammar warn). 1363-xp2v's open
   question — is the level derived from observable facts (host count,
   commit count, presence of a gate) or declared and validated against
   them — is still open; which does the operator want the first evaluator
   to assume, and who may raise a rule from warn to enforced?
6. Is the opt-in probe push (`refs/tillandsias/discipline-probe/*`) wanted,
   or is the published ref alone enough?
7. Should the land tool's default target be the seed's integration branch
   for the platform (this design) or a refusal that asks for an explicit
   branch?

## 9. What was not verified

- No code was built or run beyond the read-only verbs
  (`tillandsias-plan capabilities`, `next-order`) and the five deciders in
  the commit; the executor and Lua behaviour cited are from the sources and
  the committed tests, not from a run in this session.
- Claude Code's hook JSON contract (`permissionDecision: ask`) is cited from
  the harness documentation as of this session; 1443-we89's fixture must
  pin the exact shape the installed harness accepts.
- The 1442-22d2 fix (`refuse_borrowed_stamp`) is on linux-next; this design
  assumes it lands before 1443-u66u reads its verdict.
