# Forge-local experts: first-person experience verification (milestone 391)

- Date: 2026-07-30 (06:31Z launch, cycle 06:38Z-07:10Z UTC)
- Class: exploration/ (verification study — the milestone's own exit criteria,
  tested from the seat they are written for)
- Agent: forge-linux-fable5-firstperson-20260730T0638Z, inside a Tillandsias
  forge container (TILLANDSIAS_HOST_KIND=forge), Claude entrypoint
- Method: USE the experts before reading any implementation. Every claim below
  was produced by running commands in this container, not by reading code and
  extrapolating. Implementation was read only after the experience was recorded,
  to diagnose.
- Related: milestone 391 (forge-local-experts-milestone), orders 394e, 395,
  396, 456; packets 531-533 filed by this cycle.

## Headline

The machinery is real and good. The experience is broken at the first step:
**in a fresh forge session today, both experts refuse every question.**

`plan_answer` and `methodology_ask` through the registered forge-plan MCP
server both returned:

    {"answer":"unsupported: the plan expert returned no envelope for this
      question — experts state: ready", "citations":[], "confidence":"unsupported"}

for the milestone's own exemplar question ("what is blocked by 391") and for a
canonical routed methodology question taken verbatim from the tool's own
description ("may a forge cycle drain two packets?"). ~60ms each, envelope
contract honored, refusal instead of guess — the 394b contract held on the
degraded path. But no agent in a fresh forge can get an answer.

## Root cause (diagnosed after the experience was recorded)

Forges clone and launch on `main`. The expert subcommands (`answer`,
`verify-answer`, `methodology`, `methodology-ask`, `grade`) exist only on
`linux-next` — `git grep` on `origin/main` finds no `answer.rs` /
`methodology.rs` under `crates/tillandsias-plan/`. `ensure_forge_experts` did
exactly what order 456 says: it built from the current checkout at launch
(lifecycle log: "Compiling tillandsias-plan … Finished in 5.26s", binary
mtime 06:31, `/dev/shm/tillandsias-experts/state` = `ready`). It faithfully
built a pre-394b binary, because the checkout WAS pre-394b. The MCP wrapper
then correctly downgraded every non-envelope reply to `unsupported`.

Same pattern, second instance: the container's baked instruction files and
`lib-common.sh` predate yesterday's landings. The image (built 2026-07-29
04:09Z) has a 3243-line lib-common.sh with ZERO occurrences of the order-396
hook installer (repo copy: 3327 lines, installer present, landed 2026-07-30
01:00Z). Order 395's forge-discovery row ("use forge-plan MCP tools before
grepping") exists in the repo but not in the container the agent actually sees.

**The general failure mode: "verified where it was written" is not "verified
where it runs." Everything below that graded `done` on host-side evidence was
falsified or unproven in the forge.**

## Criterion-by-criterion judgment (391 exit criteria)

(a) "fresh forge session, OpenCode agent asks a plan question, correct INSTANT
    answer from local PLAN EXPERT (ground-truth harness graded)" — **NOT MET.**
    Fresh-session answer is `confidence=unsupported` (above). After a manual
    in-forge rebuild from a linux-next checkout, the same question answers
    `confidence=exact` in 33ms with a resolving citation
    (plan/index.yaml:16639-16676 → order 403), and `tillandsias-plan grade`
    passes 17/17 in 124ms, run in-forge. So the criterion is met by the
    *source*, and not met by the *product any fresh forge gets*. Residual filed
    as packet 531.

(b) "METHODOLOGY EXPERT answers discipline questions matching methodology.yaml
    ground truth" — **NOT MET fresh / MET post-rebuild**, identically to (a).
    Post-rebuild, `methodology-ask "may a forge cycle drain two packets?"`
    returned the forge_cycle_budget rule with an exact citation
    (methodology/distributed-work.yaml:895-904) in 10ms — and it answered a
    question this cycle genuinely needed. All 11 methodology harness cases pass.

(c) "experts are ephemeral, rebuilt from CURRENT checkout at launch;
    commit/push refreshes them" — **HALF MET.** Ephemerality + launch rebuild:
    proven (tmpfs state dir, container-local binary, real launch build
    observed). "commit/push refreshes them": **FALSIFIED**, two independent
    ways — see order 396 section. Note also: a branch switch inside a session
    (this cycle: main → linux-next) leaves the binary stale with no signal;
    only commits touching crates/tillandsias-plan/ would refresh it even with
    the hook working.

(d) "tier matrix proven on >=2 host classes" — **NOT MET.** 392b
    (gpu-passthrough-tier-matrix), 397 (experts-tier-backends), 401 (macOS
    tier verification), 402 (Windows tier verification) are all `ready`,
    unclaimed. One host class (Linux fat-GPU, RTX A5000 via cuda_v13) is
    proven.

**Verdict: milestone 391 stays `ready`. Do not close it.** Closing requires:
531 resolved (fresh forge answers exact + grades 17/17 with zero manual
steps), 396 re-closed with in-forge first-fire evidence, and one more host
class through the tier matrix.

## Order 396 (experts-refresh-on-commit): `done` FALSIFIED, reopened

1. **The hook has never executed anywhere.** In this forge,
   `core.hooksPath=/home/forge/.cache/tillandsias/git-hooks` contains ONLY
   `prepare-commit-msg`. The active image's lib-common.sh predates the
   installer by ~21 hours. On the host, `.git/hooks` is empty and
   core.hooksPath unset. The `completed` event's evidence (2ms latency,
   wiring) was measured by running the script directly, not by a hook firing.
   Empirical re-test this cycle: a real commit in this forge produced no
   `/tmp/tillandsias-hooks.log` and no hook execution (recorded in the 396
   ledger event with the commit hash).
2. **Latent install bug that would false-positive even when installed:** the
   hook copies `cp "target/release/tillandsias-plan" "$BIN_PATH" 2>/dev/null`
   — a relative path that ignores CARGO_TARGET_DIR. In the forge,
   CARGO_TARGET_DIR=/home/forge/.cache/tillandsias-project/cargo/target (this
   cycle hit exactly that: `install: cannot stat 'target/release/...'`). The
   cp fails silently and the hook still logs "binary rebuilt from commit X" —
   a false success. The launch-path builder handles this; the hook does not.

Reopened with a sharpened exit criterion: first-fire evidence from inside a
forge whose image contains the installer, with a CARGO_TARGET_DIR-aware
install, graded by the answer surface actually changing.

## Order 394e residual (soft-degrade, criterion ii) — what this seat can prove

- This launch had inference UP (three models resident), so "cold launch with
  inference DOWN still reaches the agent prompt" cannot be closed from inside
  this session. It needs a host-side launch with inference genuinely down
  (394e's 2026-07-29 event already sharpened: a non-serving endpoint, not
  merely a stopped container).
- What was proven from here, against the ACTIVE image (the code that actually
  ran, not the repo copy): the probe is a report, never a gate.
  `. /usr/local/lib/tillandsias/lib-inference-state.sh; tillandsias_inference_state`
  against a dead endpoint (http://127.0.0.1:9) → exit 0,
  `inference_state=not-ready inference_reason=endpoint-unreachable`, 1s budget.
  The entrypoint's probe call site only writes a lifecycle trace line on
  failure. Order 486's warn-and-continue contract is intact in the shipped
  image; the unexercised remainder is precisely the live end-to-end launch.

## Experience findings (each filed; the instinct notes are the point)

1. **F1 (packet 531, CRITICAL):** fresh-forge experts refuse everything —
   branch/source gap between `main` (what forges clone) and `linux-next`
   (where the experts live). Also: the degraded envelope's reason string
   cannot distinguish "stale binary without the answer subcommand" from
   "engine crash" — both render as "returned no envelope … experts state:
   ready", which reads as a contradiction and cost this cycle a diagnosis
   round-trip. `/dev/shm/tillandsias-experts` records a source hash but not
   the built binary's feature surface.
2. **F2 (396 reopened):** above.
3. **F3 (packet 532):** `lib-inference-state.sh` violates its own PINNED
   one-line machine grammar with >1 model cached: observed
   `inference_models=1` with THREE models listed, and `inference_warm` carrying
   embedded newlines. Present in the repo copy too (reproduced against live
   inference:11434 from images/default/lib-inference-state.sh). Any consumer
   branching on the one-line grammar mis-parses; the count is wrong.
4. **F4 (packet 533):** `tillandsias-help` segfaults (exit 139, empty
   output). It is a symlink to help.sh; the locale-detect block sources
   help.sh, but `source` does not change `$0`, so the sourced copy sources
   itself forever. `bash /usr/local/share/tillandsias/help.sh` works ($0
   matches). Every forge user/agent typing the advertised help command gets
   silence.
5. **Discovery / the grep instinct:** my startup context (Claude entrypoint:
   CLAUDE.md + mission) contained no pointer to the experts; AGENTS.md has
   zero mentions; the container's forge-discovery.md predates 395's row. I
   reached for `tillandsias-plan --help` and raw JSON-RPC because I already
   knew the names from the mission brief — an agent without that brief would
   have grepped plan/index.yaml and never known the experts existed. For
   OpenCode agents the MCP tools/list descriptions are genuinely good (the
   envelope contract, refusal semantics, and exemplar questions are all in the
   tool descriptions — once you see them). The missing link is everything
   before tools/list: nothing in the checkout (AGENTS.md, CLAUDE.md) mentions
   the experts, so only harnesses with the MCP registration ever meet them.
   Non-OpenCode harnesses (this session) have no wired path at all —
   consistent with "OpenCode-first, other harnesses later", now with a
   first-person datum of what "later" costs.
6. **Positive findings, deliberately recorded:** the six graph commands are
   instant (~30ms) and correct even on the stale binary; the envelope
   self-verify round-trip works (`verify-answer` exit 0; a seeded corrupt
   line-range is REFUSED exit 1 — falsifiability proven live); the refusal
   contract held on every degraded path observed; the launch build is fast
   (5.26s) and honestly fail-soft; `plan_answer`'s freshness block cites the
   exact source commit (43609fcc) it answered from.

## What "instant" measured

| Surface | Question | Latency | Result |
|---|---|---|---|
| CLI (stale, fresh-forge state) | any answer/methodology | ~30ms | usage text → MCP downgrades to unsupported |
| MCP plan_answer (stale) | "what is blocked by 391" | 58ms | confidence=unsupported |
| MCP methodology_ask (stale) | forge cycle budget | 60ms | confidence=unsupported |
| CLI answer (rebuilt from linux-next) | "what is blocked by 391" | 33ms | confidence=exact, citation resolves |
| CLI methodology-ask (rebuilt) | forge cycle budget | 10ms | confidence=exact, methodology/distributed-work.yaml:895-904 |
| CLI grade (rebuilt) | full committed set | 124ms | 17/17 PASS |

Layer honesty (established fact, confirmed): every PASS above is the
deterministic compiled-Rust Layer 0. No token was generated by the inference
container for any expert answer this cycle; inference (three models, RTX
A5000) sat idle throughout. The milestone's outcome prose promises "tiny
LOCAL expert models"; what exists and what passes the harness is L0 cited
retrieval. That is the better contract for plan/methodology ground truth —
but closing 391 should either say so or land an L1 that uses the models
(397/400 are the placeholders).
