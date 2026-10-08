# Efficiency trims T1–T7 — design (operator-approved 2026-09-27)

Umbrella packet: `1437-62g8` (`efficiency-trims-2026-09-27`). Children carry
`release_target: efficiency-trims-2026-09-27` so `scripts/select-work-batch.sh`
groups them as one epic. Every child carries `size:` and `implementer_tier:`
in its `notes:` (the T1 vocabulary, used here before T1 lands).

Origin: designed on macuahuitl from the coordinator's own
`.cache/metrics/` (`scripts/cycle-metrics.sh --cycle-start 2026-09-20T00:00:00Z`)
and the four flake events of 2026-09-27. Code is cited by SYMBOL; nothing
here is a line number.

## Measurements the designs rest on (7-day window ending 2026-09-27)

| metric | value | source line |
|---|---|---|
| `build-check` | 181 runs, avg 907 s (15.1 min), fail 29 % | `recur:` |
| `check:litmus-pre-build` | 11 runs, avg 2,241 s (37 min), fail 27 % | `recur:` |
| token-instrument step | 128 runs, avg 175 s, fail 0 %, saved_ms_upper 22,215 s | `skippable:` |
| workspace `cargo test` step | 128 runs, avg 164 s, fail 0 %, saved_ms_upper 20,889 s | `skippable:` |
| `archiver-check-miss` | 145 runs, avg 140 s, fail 0 %, saved_ms_upper 20,118 s | `skippable:` |
| whole-gate memo | `build_check_mix=mixed:forced=1098,memoised=304` | `timing:` |
| tokens log | 19 rows, all `host=macuahuitl`; `main_ctx=0` on every row since 2026-09-14 | `tokens:` |
| `litmus:preflight-front-door` | 4 runs today, each 243 s, each `status=fail failed_step=1`, identical `digest` and `spec_digest` | timing log |

Two premises in the brief were checked and one is FALSE:

- `./build.sh --check` runs NO litmus at all (`litmus-covering-specs.sh`
  header, 748-tkjx; `_run_litmus_phase` is called only from the `--ci-full`
  post-build and runtime phases). The per-relay covering run is therefore the
  ONLY pre-build litmus a change sees before the daily cut.
- `litmus:litmus-expression-pinning-enforcement-shape` does NOT run a real
  `./build.sh --check`. Its step 3 passes the text `./build.sh --check 2>&1 |
  grep -qF 'Gate stamp recorded'` as a STRING to
  `check-litmus-expression-pinning-added.sh --check-line`, whose `_is_pin`
  branch classifies the line and exits without evaluating it. A covering run
  that includes the `ci-release` spec is not a full gate, and the land tool
  adopts a stamp only from `gate-stamp.sh verify` → `ok:gate-fresh` with
  `scope` = `full`, which that litmus never writes.

## T1 — Tier routing (packets 1437-khnx, 1437-vdz5, 1437-m5yx, 1437-yjf6, 1437-cr8u)

What exists: model tiering for SUB-AGENTS only (`skills/meta-orchestration/SKILL.md`
→ "Sub-agent and token budget": haiku/low lookups, sonnet/medium prose,
opus/medium judgment), `scripts/claude-delegate.sh` (read-only Haiku modes
`audit|patch-draft|json`), and the executor-class routing precedent in
`scripts/select-work-batch.sh` (`HOST_TIER` / `TIER_TAGS` / `refused:no-tier-work`).
No packet field names a tier; `size`, `tier`, `implementer_tier` occur zero
times in the ledger. `./repeat`'s `claude)` arm drops `MODEL_FLAG` (the
`codex` and `opencode` arms pass it), so `--model` is silently ignored for
Claude today.

Design:

1. **Two SCALAR packet fields**, `size: S|M|L` and
   `implementer_tier: haiku|sonnet|opus`. Scalars because `set-field` refuses
   list-valued fields (1184-tj2q) and a novel top-level field is writable but
   unreadable until `query_json_projection` in `crates/tillandsias-plan/src/main.rs`
   projects it (the `must_ship` lesson, 1218-25z3). Until 1437-khnx lands,
   filers write both as lines inside `notes:`; the projection packet adds a
   fallback that reads `notes:` lines of exactly that shape so the 20 rows
   filed today route without re-filing.
2. **Rubric** (canonical in `methodology/distributed-work.yaml` →
   `cycle_batch_triage.model_tier_routing`): S = mechanical, fully specified
   → haiku; M = a few files, clear design → sonnet; L = cross-cutting,
   judgment, or gate-integrity-sensitive → opus. Anything that changes what
   the land gate or the pre-push hook refuses is at least sonnet, and opus
   when it could let a red tree land. Security and credential surfaces are
   opus. The FILER assigns; a claimer that disagrees files a `set-field`
   correction with `--reason`, never a silent re-tier.
3. **Selection honours the tier** (`1437-vdz5`): `select-work-batch.sh
   --tier <haiku|sonnet|opus>` (env `TILLANDSIAS_MODEL_TIER`; default from
   `CLAUDE_MODEL`-shaped hints is NOT attempted — the caller states its tier).
   Same shape as the low-end gate: a `haiku` caller's pool is EXACTLY the
   haiku-tagged rows and refuses `refused:no-tier-work:model-tier=haiku` on
   an empty pool; a `sonnet` caller takes sonnet rows plus untagged rows; an
   `opus` caller takes everything except haiku rows unless `--tier-any`. The
   `batch:` line gains `tier=<t>`. `answer_next` gains the same filter so
   `plan_next` agrees with the selector.
4. **How a session runs a cheaper model**, in order of preference:
   (a) in-session delegation: the host session claims the packet and runs
   `scripts/claude-delegate.sh implement <order>` (new mode, `1437-yjf6`),
   which launches `claude --print --model haiku --effort low` with edit
   permission bounded to the packet's `owned_files`, no commit; the host
   verifies, commits and hands off on `work/<order>` exactly as today
   (the haiku-delegate skill's "the primary agent remains accountable" rule
   is unchanged); (b) a dedicated tier session: `./repeat --model haiku
   --prompt "…/advance-work-from-plan --tier haiku"` once `1437-m5yx` makes
   the `claude)` arm pass `MODEL_FLAG`; (c) forges: after 689-jxb2 lands the
   unified `--model` flag (`in_forge_delegation.launch.model_selection`).
5. **Adoption ratchet** (`1437-cr8u`): `scripts/check-packet-tier-declared.sh`
   reports, diff-scoped like `check-added-fragments-parse.sh`, the newly
   declared packets that carry neither field. ADVISORY until adoption is
   measured (the `check-carry-forward.sh` promotion bar).

Not designed: automatic tiering from `estimated_hours` (1,031 rows carry it
and nothing reads it; it measures effort, not judgment).

## T2 — One-command relay preflight (packet 1437-664a)

`scripts/relay-preflight.sh <ref>... [--base origin/linux-next] [--plan]
[--all-covering]`. Phases, each a stderr line `item: <name> <verdict> <ms>`:

1. Refuse a dirty tree (`refused:relay-preflight:dirty-worktree`). Fetch.
   Create `relay/<utc>` from `--base`, merge each ref in the ORDER GIVEN
   (`refused:relay-preflight:merge-conflict:<ref>` exits 2). Print the
   merged SHA on stderr.
2. Run `scripts/cycle-preflight.sh` (`blocked:` → `refused:…:cycle-preflight`).
3. Deciders, whole-tree where the tool is whole-tree and against `--base`
   where it is diff-scoped (the existing env seams
   `TILLANDSIAS_SIGPIPE_BASE`, `TILLANDSIAS_FRAGMENT_PARSE_BASE`,
   `TILLANDSIAS_ADDED_TEST_BASE`, `TILLANDSIAS_DEFAULT_TARGET_BASE` are set,
   never re-implemented): `check-bash-dialect.sh`,
   `check-sigpipe-verdict-pipelines-added.sh`,
   `check-plan-binary-probe-usage.sh`, `check-litmus-pin-claims.sh`,
   `check-script-exec-bits.sh`, `check-added-fragments-parse.sh`,
   `check-scorable-obligation-added.sh`, `check-gate-step-regimes.sh`,
   `check-added-test-is-referenced.sh`, `check-jq-callsite-ratchet.sh`,
   `preflight-fixtures-default-target.sh` (the brief's
   `check-preflight-fixtures-default-target.sh` does not exist under that
   name), `check-issue-citation-convention.sh` (it cost a 20-minute gate on
   2026-09-21 because the hand-typed set omitted it), plus
   `tillandsias-plan check --strict-fragments` and `tillandsias-policy
   plan-orders` when the diff adds fragments. Judged by rc only.
4. `cargo fmt --check` when the diff touches `*.rs`.
5. Touched fixtures: every `scripts/test-*.sh` in the diff, plus every
   `scripts/test-*.sh` whose bytes mention a touched `scripts/*.sh` path
   (the same substring rule `litmus-covering-specs.sh` uses for its
   `command` tier). Sorted, deduplicated, printed BEFORE running.
6. Crate tests: `cargo test -p <crate>` for each crate with a touched file
   (crate = the nearest `Cargo.toml` above the path); when
   `crates/tillandsias-headless/src/tray/` is touched, also the
   `--features tray,listen-vsock -- --test-threads=1` pass the gate runs.
7. Covering litmus: `litmus-covering-specs.sh --relay-scope <base>` (T4)
   for the run set, `run-litmus-test.sh <spec> --phase pre-build --size
   <size> --compact` per spec; the deferred set is printed by name.
8. One stdout line: `ok:relay-preflight:<merged-sha>:refs=<n>
   deciders=<n> fmt=<ok|skip> fixtures=<n> crates=<n> litmus=<run>/<deferred>`
   or `refused:relay-preflight:<phase>:<item>` at the first red (`--keep-going`
   runs everything and reports the first red in the verdict). Timing goes
   through `timing_emit relay-preflight relay <t0> <rc>` so `recur:` sees it.
9. Determinism: `--plan` prints phases 3–7's selected items without running;
   two `--plan` runs on the same merged SHA must be byte-identical (fixture
   arm). The branch `relay/<utc>` is left for the land tool; the script
   never pushes.

Consumers: `skills/coordinate-multihost-work/SKILL.md` "Landing Queue";
`skills/join-the-fleet/SKILL.md` §3 (the worker-side preflight is the same
command with its own `work/<order>` ref).

## T3 — Shorter peer messages (packet 1437-arjg)

Rule (canonical: `methodology/distributed-work.yaml` →
`sibling_heads_up_protocol.size_budget`): a cross-session message is at
most 600 bytes and 8 lines. Line 1 is the verdict, `<KIND>:<subject>:<one
clause>` with `KIND` in `HEADS-UP|ACK|LANDED|BLOCKED|ASK|FYI`; every further
line starts with `- ` and carries at least one ref (a SHA of ≥7 hex, an
order token, a `work/<order>` ref, or a path). Anything longer is a ledger
event or a `plan/issues/` note, and the message carries its citation.
Lint: `scripts/check-peer-message-shape.sh` reads stdin, prints
`ok:peer-message:<bytes>b/<lines>l` or `violation:peer-message:<reason>`,
exit 1. No gate step, no fixture beyond its own three arms; the sender pipes
the draft through it before `SendMessage`.

## T4 — Scoped covering litmus per relay (packets 1437-yfuh, 1437-v3gb)

Today the coordinator runs EVERY covering spec (37–52 per relay, ~30 min).
The discoveries that must survive: stale litmus pins (found by
`check-litmus-pin-claims.sh`, a decider — kept unconditional), a fixture
whose `&&` swallowed a gate's exit and a second copy of a ground-truth pin
(found by DECLARED-coverage specs over the touched fixture and by the
`groundtruth-mutable-status-pins` change class — both kept).

`litmus-covering-specs.sh --relay-scope <base>` prints the covering set
partitioned into `run` and `deferred`, sorted `(match tier, spec)`, with
the reason per deferred line:

- `run`: every BOUND spec with a `declared` match on a touched path; every
  bound `command`-match spec whose size is `instant` or `quick`.
- `deferred:size` — `long`, `large`, `e2e` command-matches (the daily cut's
  `check:litmus-pre-build` runs them; the cut is autonomous).
- `deferred:phase` — anything not `pre-build` (needs a forge; the cut's
  `--ci-full` runs those).
- `deferred:memo` (`1437-v3gb`) — a spec whose litmus-file `digest`,
  `spec_digest` and the digest of its touched inputs equal a `status=pass`
  timing record from THIS host within 24 h. The timing log already carries
  the first two (1395-88tp); the third is new and is what makes the memo a
  memo rather than a bound. A `status=fail` record never memoises.
- A cap: when `run` exceeds 15, the script keeps the 15 highest by
  `(declared first, then spec name)` and lists the rest as
  `deferred:cap` — the coordinator opts in with `--all-covering`.

The `run` set for a scripts-only relay is measured on the 2026-09-27
relays at 8–14 specs against 37–52, i.e. roughly a third of the wall time.
The standing `preflight-front-door` red is re-run 4× a day at 243 s each
purely because nothing remembers it failed on identical bytes; the memo
deliberately does NOT skip fails, so that saving comes from T6, not here.

## T5 — Record main-loop tokens on every host (packets 1437-3pj7, 1437-3ynw)

`main_ctx` is 0 because nothing computes it: `--emit-tokens` in
`scripts/cycle-metrics.sh` writes what the caller passes and the caller
(an agent following the skill) never had a number. The harness DOES expose
one: the session transcript at `~/.claude/projects/<cwd-slug>/<session>.jsonl`
carries `message.usage` (`input_tokens`, `cache_creation_input_tokens`,
`cache_read_input_tokens`, `output_tokens`) on every assistant record with
`timestamp`, `sessionId`, `cwd`; sub-agent transcripts live under
`<session>/subagents/` with the same fields; the session id is in
`CLAUDE_CODE_SESSION_ID`. The statusline JSON (`context_window.*`,
`cost.total_cost_usd`) is session-cumulative and only reaches a
`statusLine` command, so it is the fallback, not the source.

`scripts/session-tokens.sh [--since <utc>] [--transcript <path>]` prints one
line: `main_ctx=<n> main_ctx_cumulative=<n> subagent_tokens=<n> agents=<n>
by_model=<model:count,…> source=<path|absent>` where `main_ctx` is the sum
over main-transcript assistant records since `--since` of the four usage
fields (a BILLED-token figure, named as such; never a context-size proxy),
`main_ctx_cumulative` the same over the whole transcript, and the sub-agent
fields are summed from `subagents/*.jsonl` (so `by_model` stops being a
hand attestation). `cycle-metrics.sh --emit-tokens --from-transcript
cycle=<id> label=<w>` calls it and fills the record; a harness with no
transcript (opencode, codex, a forge whose HOME lacks the dir) records
`source=absent` with zeros, never a guess. The transcript format is
documented as internal and version-dependent: the script asserts the four
field names it reads and answers `source=absent:schema-drift:<field>` when
one is missing, so a format change reads as a missing instrument rather
than a zero.

Fleet adoption (`1437-3ynw`): `join-the-fleet` §4's handoff `tokens:` line
must come from `--from-transcript`; `check-tokens-log-has-main-ctx.sh`
(advisory) reports a host whose last 5 token rows all carry `main_ctx=0`
while a transcript exists — the "activation is proved by what ran" check.

## T6 — Four flakes and the standing red (packets 1437-qdkj, 1437-bigs, 1437-5czv, 1437-wcn9, 1437-m3jb)

Each packet's exit criterion is an OUTPUT that fails on today's code under
an injection the fixture controls:

- `1437-qdkj` — `test-credential-cold-state-probe.sh` arm 3 compares the
  verdict WORD across five runs of `probe-credential-cold-state.sh`, and the
  probe answers `could-not-run:no-secret-service` whenever `busctl --user
  list` returns without `org.freedesktop.secrets` (a slow bus under load).
  A `could-not-run` is a regime, not a verdict: the arm must exclude it from
  the disagreement set and report `skip:…:could-not-run-under-load:<n>/5
  load=<x>` when it occurred, going red only when two DEFINITE verdicts
  differ. Injection: a PATH shim `busctl` that answers normally except on
  its second `list` call.
- `1437-bigs` — `test-tool-materialize-litmus-surfaces-arm.sh` ARM 0 accepts
  `regime quiet …`, the toolbox skip and `no-regime-probe`, but not the
  subject's own `skip:tool-materialize-margin:loaded-host:…` line, so a
  loaded host (a parallel gate) turns ARM 0 red. Injection:
  `TILLANDSIAS_TOOL_MATERIALIZE_LOADAVG=<cpus>` (seam already in
  `_margin_regime`).
- `1437-5czv` — `mcp_connection_serves_browser_family_over_the_socket` uses
  `UnixStream::pair()` (no path, no port); the shared state is the process
  env `TILLANDSIAS_HOST_PROJECT_ROOT` / `TILLANDSIAS_CLOUD_PROJECT_CACHE`,
  guarded by FIVE independent mutexes (`ENV_LOCK` in `local_projects.rs`,
  `remote_projects.rs`, `vault_bootstrap.rs`, `tray/mod.rs`, plus `ENV_LOCK2`
  in `tray/mod.rs`). One crate-wide `test_support::env_lock()` and a
  structural fixture that counts `static ENV_LOCK` definitions (must be 1;
  today 5) make the criterion deterministic; the stress arm (`--test-threads=8`,
  10 rounds) is the second, probabilistic arm.
- `1437-wcn9` — `test-codex-mcp-registration.sh` prefers a REAL `codex` from
  PATH over `scripts/fixtures/codex-mcp-stub.sh` (`elif command -v codex`)
  and runs the helper twice, so a host with the CLI installed pays two real
  invocations under a 30,000 ms step budget (yoga: killed at 30,007 ms). The
  fixture must default to the stub and take the real CLI only under
  `CODEX_BIN`; injection: a PATH shim `codex` sleeping 16 s per call.
- `1437-m3jb` — `litmus:preflight-front-door` fails at 243 s on every
  covering run today (ARM 6 asserts `wall <= TILLANDSIAS_PREFLIGHT_BUDGET_S`,
  default 150 s, against a REAL `./build.sh --preflight` over a roster that
  only grows — the 1233-jqp4 class) and its fixture plants
  `scripts/check-zz-1305-planted.sh` and `gate-steps.d/999-zz-1305-planted.step`
  INTO THE CHECKOUT, so a concurrent gate in the same tree fails on the
  planted step. Two changes: the budget becomes
  `<guards> × per-guard-deadline / parallelism` derived from the roster the
  door enumerates (a growing corpus cannot be pinned to a constant), and the
  fixture runs in a scratch clone. Pre-fix result is the timing log itself.

## T7 — Memoise or skip the never-failing gate steps (packets 1437-gbwi, 1437-jm2d, 1437-cxt9)

The whole-gate memo (`gate-stamp.sh memo-check`, 765-tkq2) is all-or-nothing
on a tree digest that excludes only ledger fragments; 1,098 of 1,402 checks
in 7 days were forced. The next rung is a PER-STEP memo keyed on the step's
own inputs, so a relay that touches `scripts/` re-runs the script guards and
skips the workspace tests.

- `1437-gbwi` (S): the token step's 175 s is not the instrument — it is
  `test-token-instrument.sh`'s `report()` calling the full `cycle-metrics.sh`
  reporter 11 times without `--no-repo-scan`, because the `tokens:` line is
  rendered AFTER that flag's early exit. Move the `tokens:` render above the
  early exit (or add `--tokens-only`); the fixture passes the flag. Expected
  175 s → under 15 s. No memo needed.
- `1437-jm2d` (L): `scripts/step-memo.sh check|record <step-id>` generalising
  `archiver-check-memo.sh`'s `_digest`: key = sha256 over `git ls-files -s`
  blob ids and modes of an INPUT SET, plus the working-tree diff of that set
  (a dirty file changes the key), plus a toolchain digest (`rustc -V`,
  `cargo -V`), plus `scripts/test-known-red.txt`. For the workspace
  `cargo test` step the input set is derived, not hand-listed:
  `scripts/workspace-test-inputs.sh` emits `crates/`, `Cargo.toml`,
  `Cargo.lock`, `.cargo/`, every path an `include_str!`/`include_bytes!`
  in `crates/` reaches through `../` (today `assets/icons/**`,
  `images/default/ca-path.txt`), and every repo-relative literal a crate
  source opens at runtime (`"plan/…"`, `"openspec/…"`, `"methodology/…"`,
  `"scripts/…"`, `"skills/…"` — the enumerator greps the literal, the file
  or directory it names is the input, never the whole root). A memo hit
  prints `skip:workspace-tests:memo-hit:<key12>` and emits
  `workspace-tests-memo-hit` to the timing log so `skippable:` keeps
  measuring; the daily forced run reuses the existing
  `$GIT_DIR/tillandsias-last-full-gate` marker (`TILLANDSIAS_FULL_GATE_MAX_AGE_S`,
  24 h): when it is older than the window every step memo is bypassed and
  the run records itself. `TILLANDSIAS_FORCE_CHECK=1` bypasses too. A red
  run never records. The mutation arms: touching each enumerated input
  flips the key; touching a ledger fragment does not; a red run leaves no
  record; an expired marker forces the run.
- `1437-cxt9` (M): `archiver-check-memo.sh`'s key includes
  `plan/index.d/*.yaml`, so every relay that files a fragment (nearly all)
  misses — 145 misses at 140 s and never a fail. The archiver's property
  ("preserves the ready set") is a property of the archiver CODE over the
  ledger SHAPE; re-key on the archiver scripts, the plan binary `build-id`,
  `plan/index.yaml` (changes only at compaction) and `plan/schema.yaml`, and
  let the daily forced run of `1437-jm2d` cover the fragment-dependent case.

## Savings arithmetic (from the 7-day window above)

- T7 gate time: token step 128 × (175 − 15) s ≈ 5.7 h/wk; workspace tests
  128 × 164 s = 5.8 h/wk upper bound, × an estimated 40 % hit rate (relays
  touching scripts/ or plan/ only) ≈ 2.3 h/wk; archiver 145 × 140 s = 5.6 h/wk
  upper bound, × ~70 % (fragment-only changes) ≈ 3.9 h/wk. Total ≈ 12 h/wk,
  i.e. a `--check` from 15.1 min to roughly 11 min.
- T4 coordinator wall: ~30 min → ~10 min per relay; at ~8 relays/day that is
  ~2.7 h/day ≈ 19 h/wk of coordinator session time (main-tier tokens are
  spent while it waits; T5 will measure how many).
- T2 tokens: ~15 hand-typed commands with outputs (~1.5 k tokens each in
  the coordinator's context) → 1 command with a one-line verdict (~3 k):
  ≈ 19 k tokens per relay, ≈ 150 k/day, ≈ 1 M/wk at the main tier.
- T6: the 29 % `--check` fail rate over 181 runs is 52 reds; if a quarter
  are flakes, 13 re-runs × 15 min ≈ 3.3 h/wk; plus `preflight-front-door`
  4 × 243 s/day ≈ 1.9 h/wk and one fewer standing red masking new ones.
- T1: token COUNT is unchanged; the saving is tier-weighted spend, which
  needs the operator's price ratio (not restated here). Of the 20 packets
  filed today 6 are S/haiku, 9 M/sonnet, 5 L/opus.
- T3: unmeasured today (messages are not logged); 600 bytes ≈ 150 tokens
  against observed multi-paragraph heads-ups of ~600–900 tokens, received at
  the main tier. T5 is what turns this into a number.

## Rulings 2026-09-27 (operator, relayed by the coordinator)

Applied through the plan binary (`set-field --append`/`--replace` with the
ruling as `--reason`, `append-event`), never by editing a landed fragment.

1. **Untagged packets are Opus** ("No size tags get Opus"). The tier is a
   FLOOR: a caller at T takes rows with floor at or below T, at-tier first.
   Sonnet takes sonnet then haiku, never untagged. Amended 1437-khnx
   (projection never defaults; absent stays absent), 1437-vdz5 (six arms,
   `tier_fallback=<n>`), `model_tier_routing.selection`, and the skill text.
2. **All-day Haiku orchestrator.** Two packets: `1443-qwpj`
   `scripts/verify-closure.sh <order>` runs the packet's own closure command
   (the scorable grammar guarantees one exists) and compares the PRINTED
   output to the criterion — `ok:closure`/`unmet:closure:expected=…
   measured=…`/`unscoreable:closure`; a delegate's "met" is never an input
   (the 1437-gbwi misreport: 76 s then 70 s against "under 20 s"). `1443-hbgt`
   `/haiku-orchestrate`: launched as `./repeat --model haiku --prompt "Use
   the /haiku-orchestrate skill"` (needs 1437-m5yx); drains the selector with
   `--tier-any`, claims, delegates one sub-agent per packet at the packet's
   tier (untagged → opus), branches on verify-closure's one line (ok →
   completion with the verify line as evidence; unmet → one re-delegation
   with the measured line, then blocked; unscoreable → note). Never-list:
   implement code, judge from a report, push to a platform branch or main,
   edit methodology/specs/hooks/gate-steps, re-tier, run its own gate,
   over-budget messages, accept an unrunnable closure. Canonical:
   `model_tier_routing.orchestrator_session`.
3. **Integration layers.** Confirmed deferral; classification to be
   revisited per BRANCH layer. Table in `methodology/ci.yaml` →
   `integration_layers`: work-ref push = deciders + touched fixtures (no
   cargo, no litmus); relay land = change-class tier of `--check` (deciders,
   fixtures, memoised workspace tests, feature-gated pass) + `--relay-scope`'s
   run set (yoga's 1437-yfuh, consumed not re-derived); daily cut =
   everything, every size and phase, memo OFF; stable = per-platform smokes.
   Packets `1443-b85g` (classifier + `run-litmus-test.sh --layer`, L/opus)
   and `1443-2ef7` (census of size/phase misclassification, S/haiku).
4. **Memoisation.** Epoch = the release cut, not 24 h: the VERSION file's
   content is in every key (every cut bumps and back-merges it), no clock,
   marker or age is consulted (a `grep -c` arm pins that); keys are pure
   content hashes (the plan binary enters by `build-id` output, not
   size+mtime); only steps in `scripts/memo-classified-expensive.txt` are
   memoised (instant litmus never); the cut runs with the memo off. Amended
   1437-jm2d (8 arms), 1437-v3gb (5 arms, `version_digest`), 1437-cxt9
   (3 arms). The 24 h forced-run marker is withdrawn from all three.
5. **On hold pending the operator's "why".** 1437-arjg (message budget)
   → `blocked` event and status; the statusline fallback in 1437-3pj7 → note
   event, the transcript source proceeds. The size_budget text stays written,
   unenforced.
6. **Land tool.** Redesigned in Lua by a separate design; 1437-664a notes it
   may be superseded and is written as callable phases. Not redesigned here.
