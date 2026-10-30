# Gate time profile and the `--changed` fast loop (2026-10-29)

**Filed**: 2026-10-29, macuahuitl-fedora (24-core Fedora, builder toolbox)
**Orders**: 1916-tsel (tests selected per change), 1916-gbct (gate budget from phase attribution)
**Regime**: Linux, `tillandsias-builder` toolbox, sccache on, land-queue gates in the
main checkout. The numbers below hold for this host and this regime; a
darwin or msys gate has not been profiled here.

## 1. Where `./build.sh --check` spends its time

### Source of the numbers

The per-step rows come from the timing side channel that 1915-gtph (#702)
added: `_phase_emit_timing` in build.sh flushes one `step:<slug>` row per
phase, all carrying the gate's `run_id` (minted by `_gate_run_id_begin`).
Each row has two durations:

- `duration_ms`: the step's own work, measured inside `_run`.
- `wall_ms`: banner-to-banner time.

The ranking uses **wall** because wall is what the operator waits for.

- **Ranked runs**: the three most recent green land-queue gates on linux-next
  in `.cache/metrics/tillandsias-timing.jsonl` of the main checkout:
  `gate-1793294663373-1353540` (1,453 s), `gate-1793296368786-2283409`
  (1,457 s), `gate-1793299330131-3331345` (1,502 s). Each has 411 step rows.
  The table shows the median over the three runs.
- **This packet's own runs**: two `./build.sh --check` runs in the
  `work/1916-tsel` worktree (own target dir, `TILLANDSIAS_SHARED_TARGET=off`).
  Both went red on host-state fixtures while a release `--ci-full` was
  running on the same host:
  - Run 1 stopped at 1,057 s. The 1204-3s2s guard counted one record
    written into the shared `/tmp/tillandsias-timing.jsonl` during
    `test-uninstall-tray-stop-is-macos-only.sh`. That fixture does not write
    timing records, so the record most likely came from the concurrent
    release gate. The guard reads a line count, so it cannot tell whose
    record it was.
  - Run 2 stopped at 505 s, in the 747-knbp image-tag fixture: its scratch
    file `noskew/out` vanished under it.

  Run 1's 254 rows agree with the ledger medians. Every top-15 step present
  in both is within run-to-run spread, except the cargo steps, which were
  slower on the cold, contended target.

### Top 15 steps by median wall time (s)

| # | step (`step:` slug) | wall | own | range | fixture |
|---|---|---|---|---|---|
| 1 | `checking-the-uninstaller-s-tray-stop-cannot-fire-off-darwin-1231` | 120.0 | 1.6 | 120.0–120.0 | `scripts/test-uninstall-tray-stop-is-macos-only.sh` (step 400-1231-cbie) |
| 2 | `checking-the-litmus-runner-selects-identically-with-and-without-` | 91.3 | 91.3 | 90.8–93.9 | `scripts/test-litmus-runner-reads-without-jq.sh` (step 530-1375-6pnd) |
| 3 | `running-workspace-tests-cargo-test-workspace-all-targets` | 86.3 | 86.3 | 85.9–89.0 | inline: `cargo test --workspace --no-fail-fast` |
| 4 | `running-feature-gated-tests-tray-listen-vsock-1074-w7qv` | 77.5 | 77.5 | 76.9–78.9 | inline: `cargo test -p tillandsias-headless --features tray,listen-vsock` |
| 5 | `checking-a-tool-materialization-red-names-its-arm-and-a-bad-regi` | 68.8 | 68.7 | 67.7–68.8 | `scripts/test-tool-materialize-litmus-surfaces-arm.sh` (step 414-1269-gfdi) |
| 6 | `checking-a-pending-capability-row-does-not-wedge-the-host-that-p` | 67.7 | 7.9 | 67.7–68.0 | `scripts/test-pending-capability-row-does-not-wedge.sh` (step 275-1128-4ffr) |
| 7 | `checking-the-token-instrument-records-a-cycle-and-ranks-repeated` | 67.2 | 67.2 | 67.2–69.2 | `scripts/test-token-instrument.sh` (step 270-1119-6wn6) |
| 8 | `checking-the-plan-archiver-preserves-the-ready-set-831-ezea` | 65.4 | 65.4 | 65.2–69.3 | `scripts/archive-plan-packets.sh --check` |
| 9 | `checking-the-per-launch-forge-swap-service-units-helper-refusals` | 60.2 | 0.2 | 60.1–60.2 | `scripts/test-forge-swap-service.sh` (step 440-1376-8zdz) |
| 10 | `checking-the-fleet-activity-read-1223-wzc4` | 59.4 | 59.3 | 58.6–63.0 | `scripts/test-fleet-activity.sh` |
| 11 | `checking-a-missing-ruby-reads-as-could-not-run-not-as-a-ledger-v` | 45.1 | 45.1 | 45.0–48.0 | `scripts/test-archiver-ruby-could-not-run.sh` |
| 12 | `checking-a-memo-hit-is-observable-and-a-miss-stays-profiled-1074` | 42.7 | 42.7 | 42.7–44.4 | `scripts/test-memo-hit-observability.sh` (step 085-1074-96z9) |
| 13 | `checking-the-door-sweeps-a-stale-index-lock-a-killed-git-left-an` | 40.8 | 40.8 | 39.8–45.5 | `scripts/lua/test-door-index-lock-sweep.lua` (step 860-1650-fb7z) |
| 14 | `checking-plan-ledger-integrity-tillandsias-plan-check` | 40.5 | 0.8 | 39.9–43.4 | inline: `tillandsias-plan check` and the work after it |
| 15 | `checking-the-loop-status-audit-can-still-read-what-cycle-metrics` | 23.1 | 23.1 | 23.0–24.0 | `scripts/test-loop-status-audit-reads-current-emitter.sh` (step 410-1243-yiyq) |

The top 15 account for 957 s, or 66% of the 1,459 s sum of median walls.

### Where the time goes, by kind

| bucket | steps | median wall (s) |
|---|---|---|
| cargo: workspace tests, two headless feature passes, Lua source agreement, clippy, fmt | 9 | ~200 |
| waits after the step's own work ends (rows 1, 6, 9, 14: wall − own) | 4 | ~248 |
| shell/Lua fixtures and guards, own work | ~398 | ~1,010 |

By step size:

| step size | steps | total (s) |
|---|---|---|
| under 1 s | 318 | 64 |
| 1–5 s | 44 | 102 |
| 5–10 s | 21 | 147 |
| 10–30 s | 14 | 213 |
| 30–60 s | 5 | 228 |
| 60 s and over | 9 | 704 |

The 23 steps of 10 s or more make up 78% of the gate.

### Finding: about 248 s per gate is waiting, not checking

Rows 1, 6 and 9 do between 0.2 and 7.9 s of work. Their wall time is a
constant 120.0 or 60.0 s on all three runs. The cause is in
`_gs_exec_step`:

- It runs the step as `_run bash … > >(tee "$_step_out")` and then waits on
  the `tee`.
- Each of these fixtures starts a background `sleep 120` or `sleep 60`:
  - the decoy in `test-uninstall-tray-stop-is-macos-only.sh`;
  - the `flock … sleep 60` lease holder in `test-forge-swap-service.sh`;
  - the hold arm in `test-pending-capability-row-does-not-wedge.sh`.
- The fixture kills the parent, but the orphaned `sleep` still holds the
  step's output pipe. `tee` cannot see EOF until the sleep exits.

Row 14 has the same shape (wall 40.5 s, own 0.8 s): the work runs between
the plan-check banner and the next one.

Fixing the four is cheap and is the largest single saving that changes no
coverage. For example, kill the process group, or start the holder with
`>/dev/null 2>&1`.

## 2. Input map: what each check reads

`scripts/gate-changed.sh --map` derives the map on every run, in about 1 s,
and stores nothing, so it cannot go stale.

**Population.** 409 fixture invocations, including this packet's own; there were 408 before it:

- every `_run bash "$SCRIPT_DIR/scripts/…"` and
  `_run_lua_decider "scripts/lua/…"` inside build.sh's `--check` block;
- plus every `scripts/gate-steps.d/*.step`.

406 of the pre-existing 408 join to a timing row by their `_step` slug.

**Inputs: declared, not traced.** `strace` is not installed in the
`tillandsias-builder` toolbox, so the map comes from what each fixture's
text names:

- literal repo paths and `$ROOT/…` paths, resolved against `git ls-files`;
- sibling basenames;
- globs and directories, which become prefixes.

Two refinements, both measured:

- **Only executed or sourced scripts are followed.** A script is followed
  when it is invoked with `bash`, `source`, `.`, `exec` or `script run`;
  any other path is a leaf input. Following mere mentions made 347 of 434
  units depend on the whole tree, because a comment naming build.sh pulled
  in every script build.sh names.
- **A tree scan selects on every change.** These count as tree scans:
  `git ls-files` or `git grep` with no pathspec, a recursive
  `grep`/`find`/`rg` aimed at `"$ROOT"`, and a `"$ROOT"/*` glob. A
  `git grep -- <dir>` counts as reading only `<dir>`. Lines in comments and
  in `printf`/`echo` are ignored.

  After both refinements, 47 units read the whole tree. Most are the
  diff-scoped `check-*-added` guards, which really do read every changed
  path.

**Cargo.** Changed files under a workspace member select that crate. The
selection then closes over reverse dependencies: every `path = "../x"`
dependency in the members' Cargo.toml, whether normal, dev or build. Repo
paths named in a crate's sources (`include_str!`, fixture paths) are also
inputs of that crate. When `tillandsias-headless` is selected, the gate's
two headless feature passes run as well.

**Residual risk.** A read the text does not name, such as a path built at
run time or a file a child binary opens, is invisible to this map.
`--check` before landing stays the authority. The tracer that would close
this gap is in section 5.

## 3. `./build.sh --changed [base]`

Usage:

- `./build.sh --changed`
- `./build.sh --changed <ref>`

The base defaults to the merge-base with origin/linux-next. When a base is
given, it is also exported as `TILLANDSIAS_GATE_DIFF_BASE`, so the
diff-scoped guards judge the same diff.

**What it runs.** It runs after the toolbox, sccache and diff-base
preamble. It deliberately skips the gate touch (`_touch_gating_checkout`):
that touch is what makes every `--check` rebuild cold, and skipping it keeps
cargo warm.

It then runs only:

- `cargo test` for the selected packages, through the same
  `check-test-baseline.sh` known-red ratchet as the gate;
- the selected fixtures, in gate order.

**Exit codes.** 0 means green, 1 means a selected check failed. Exit 10
from the script means the change could not be scoped, and build.sh then
`exec`s the full `--check`.

**Fail-safe: everything runs when any of these is true.**

- A guard file changed:
  - build.sh and the script itself;
  - `ensure_toolbox.sh`, `with-tillandsias-builder.sh`, `timing-log.sh`,
    `plan-binary-probe.sh`, `cycle-metrics.sh`, the sccache wrapper;
  - the shared `lib*` scripts and `scripts/lua/lib/`;
  - the workspace `Cargo.toml`, `Cargo.lock`, toolchain files and `.cargo/`;
  - the known-red list;
  - `tillandsias-plan` and every crate it depends on, because the plan
    binary runs every Lua fixture.
- A changed path is named by no fixture and no crate (unmapped).
- The extractor finds zero fixtures.

**Scope.** It is a developer loop. The land gate (`--check`) and the
release tier (`--ci-full`) are unchanged.

**Proof.** `scripts/test-gate-changed-selects-by-input.sh` is bound into
`--check`, after the Lua source-agreement step. It mutates a stub tree one
path at a time:

- An input selects its own fixture and not an unrelated one.
- A base crate selects its reverse dependent and not a sibling.
- An unmapped path or build.sh selects everything.
- A `.step` file selects only the fixture it wires.
- On the real tree, the population is at least 300.
- build.sh dispatches `--changed`.
- `--run` executes exactly what `--list` selects, and a red selected
  fixture fails the run.

The `--run` arm exists because the first replay caught a real bug, later
pinned by mutation. The runner read the population with `IFS=$'\t' read`.
Tab is IFS whitespace, so an empty args column collapsed and shifted every
later field. Argless fixtures never matched their selection, and only 3 to 5
of 67 to 168 selected fixtures ran per PR, all green.

The runner now:

- reads through `\037`;
- refuses with `fail:gate-changed:ran-N-of-M-selected` when the count it
  ran differs from the count it selected.

On the pre-fix tree (origin/linux-next at ef6859553) it fails with
`FAIL:gate-changed-selects-by-input:subject-missing`, exit 1.

## 4. Replay: the last 20 landed PRs

Method:

- For each of the last 20 first-parent `land(...)` merges on
  origin/linux-next, the PR's diff (`git diff <merge>^1 <merge>`) was fed
  to `gate-changed.sh --run --files <diff>` on a warm target.
- One `cargo test --workspace --no-run` ran first, taking 4.5 s.
- **measured** is the wall time of that real run.
- **estimate** is the sum of the selected fixtures' median own time from
  section 1. It excludes cargo time.
- The full gate is 1,459 s, the median wall sum above.

| merge | work ref | fixtures | crates | cargo s | fixtures s | total s | result |
|---|---|---|---|---|---|---|---|
| 1492f684b | `work/1914-m3ap` | 85 | 6 | 86 | 286 | 373 | red: test-gate-step-metrics-isolation.sh (harness env) |
| 024a7fff5 | `work/1919-keyc` | 67 | 2 | 115 | 132 | 248 | green |
| 08a64c9d3 | `work/1914-k7vq` | 82 | 6 | 98 | 236 | 336 | red: test-gate-step-metrics-isolation.sh (harness env) |
| b73b8afc0 | `work/1907-cfdf` | 168 | 11 | 174 | 544 | 720 | red: test-metrics-log-path-agreement.sh, test-gate-step-metrics-isolation.sh (harness env) |
| d6021cb6c | `work/1921-mdia` | 110 | 4 | 253 | 530 | 785 | green |
| 0a9a07e1e | `work/1922-rdyg` | 110 | 3 | 115 | 256 | 372 | green |
| e9a31a5a5 | `work/1921-xkhw` | 65 | 4 | 128 | 129 | 259 | green |
| eabf2f3e5 | `work/1915-gtph` | all | all | — | — | 1459 (full) | full --check (guard: build.sh) |
| cb3adeb75 | `work/1912-flky` | 64 | 5 | 159 | 114 | 274 | green |
| 82d9448e8 | `work/1879-fi7q` | 56 | 6 | 90 | 46 | 137 | green |
| 6b3ea90f4 | `work/1916-nxcs` | 57 | 1 | 33 | 58 | 93 | green |
| 7cd86765f | `work/1919-exec` | 121 | 3 | 265 | 256 | 522 | green |
| 6bcc9c018 | `work/1919-hlth` | 132 | 10 | 241 | 375 | 618 | red: test-gate-step-metrics-isolation.sh (harness env) |
| d89328dc6 | `work/1914-twan` | 80 | 6 | 199 | 238 | 438 | red: test-gate-step-metrics-isolation.sh (harness env) |
| 7a44e3213 | `work/1360-34uw` | 110 | 3 | 148 | 246 | 396 | green |
| 5b9785299 | `work/1360-34uw` | 57 | 1 | 33 | 70 | 105 | green |
| 8a095b5bd | `work/1910-nb6m` | 149 | 6 | 125 | 353 | 480 | red: test-metrics-log-path-agreement.sh, test-gate-step-metrics-isolation.sh (harness env) |
| 89ce5f972 | `work/1910-a1m8` | 68 | 1 | 175 | 135 | 311 | green |
| d67dc79fd | `work/1909-t9y2` | 68 | 1 | 79 | 127 | 207 | green |
| 59143ef43 | `work/1909-aryk` | 162 | 8 | 139 | 385 | 525 | red: test-metrics-log-path-agreement.sh, test-gate-step-metrics-isolation.sh (harness env) |

### Replay summary

- **19 of 20 PRs were scoped.** Selected wall time: median 372 s, mean 379 s,
  range 93–785 s.
- **Against the full gate:** the median is 3.9x faster (25% of 1,459 s), and
  even the worst scoped PR is 54% of the gate.
- **One PR selected everything:** #702 (1915-gtph) changed build.sh, so it
  ran the full `--check`, as designed.

**What this regime is.** The replay ran in the builder toolbox, alongside a
release `--ci-full` and the land queue on the same host. Cargo tests were
not routed through sccache. Same-selection pairs therefore vary up to 2x:
for example, `work/1921-mdia` and `work/1922-rdyg` select the same 110
fixtures and took 785 s and 372 s.

**About the "red" rows.** All are `test-gate-step-metrics-isolation.sh`
and/or `test-metrics-log-path-agreement.sh`, failing their negative-control
arms because the replay harness exported `TILLANDSIAS_*_LOG`. Those arms
need an UN-named log. Both are green in a clean environment: 4/4 and 19/19.
Through `./build.sh --changed` they get the gate's environment.

### This is not "seconds" yet

The floor is set by three costs, and section 5 targets each:

- **cargo `tillandsias-headless`.** Its sources name `plan/` and
  `methodology/` paths, so nearly every diff selects it. Its feature pass
  alone is 67–82 s.
- **About 47 whole-tree readers**, mostly the `check-*-added` guards,
  totalling roughly 50 s.
- **A few heavy fixtures with broad declared inputs**: the litmus runner
  pair at 91 s and 14 s, and `test-fleet-activity.sh` at 64 s.

A warm edit to one fixture's own script selects only that fixture plus the
always-run set.


## 4b. Concurrent gates no longer blame each other (coordinator ask)

The 1204-3s2s leak check in `_run_gate_steps` refused a step whenever the
shared fallback log `/tmp/tillandsias-timing.jsonl` grew during it.

- With two gates on one host, the other gate's records grew it too. That
  blamed the running step: my profiling runs here went red twice that way,
  and the coordinator reports two land-queue evictions.
- The step loop now hands `scripts/gate-step-metrics-attribution.sh` the
  baseline line count and this gate's `TILLANDSIAS_TIMING_RUN_ID`. That run
  id is exported by `_gate_run_id_begin` and stamped by cycle-metrics.sh.
- Only new records carrying that id refuse the step. Steps run one at a
  time, so such a record is the step's own.
- Another gate's records are ignored.
- A record with **no** run id still refuses the step, unless another gate is
  live at that moment. "Live" means a foreign run id landed in the same
  window, or a sibling `build.sh --check`/`--ci-full`/`--gate-steps`
  process exists outside this gate's own process ancestry. Only that
  concurrent case drops to a warning (coordinator ruling 2026-10-29).

**Fixture.** `scripts/test-gate-step-metrics-attribution.sh` runs two
concurrent writers into a scratch log, with the sibling probe pinned so
real host gates cannot sway it:

- the clean step is not named;
- the leaking step is named with exactly its two records;
- an id-less record beside a live gate warns;
- an id-less record with no concurrent gate refuses;
- build.sh is wired to the helper's verdict.

It fails on the pre-fix tree. `test-gate-step-metrics-isolation.sh` arms 1
and 4 now look for the attribution call instead of the old line-count
compare.

**Residual risk.** A fixture that scrubs its environment and leaks while
another gate happens to be running gets a warning, not a refusal.

## 5. Proposal (not implemented): toward seconds

### a. Content-addressed green-result cache

**Key.** `sha256(unit id, runner, args, the sorted (path, blob-sha) list of
the unit's inputs from the map, toolchain id, plan-binary content hash)`.

- Use `git ls-files -s` for blob shas, so hashing costs nothing for
  tracked files.
- A directory or `*` input hashes the tree object, or the diff-relevant
  subset.

**Value.** `{verdict line, rc, own_ms, host, regime, run_id}`. Store only
green results.

**Where.** A per-host directory beside the sccache dir. It is not a ledger,
so nothing is shared across hosts until the regime field is compared.

**Use.**

- `--changed` and `--check` skip a unit whose key hits.
- `--ci-full` ignores the cache.
- Every `*` unit misses whenever any blob changed, so the cache does not
  help them. That is why item (b) matters.

**Guards.**

- A hit prints `cached:<unit>:<key-prefix>` so a reader sees what did not
  run.
- A cache older than N days is ignored.
- A fixture marked host-state (`STEP_HOST_STATE`) never caches.

What to cache first:

| unit | why |
|---|---|
| the 23 steps of 10 s or more | 78% of the time |
| cargo test binaries | by crate input hash; nextest can replay per binary |

### b. Split

- **The four wait-bound steps (rows 1, 6, 9, 14).** Kill the orphaned
  holder or detach its output. This saves about 248 s with zero coverage
  change. Do it first.
- **`test-litmus-runner-reads-without-jq.sh` (91 s).** It runs the whole
  litmus runner twice to compare selections. Split it into:
  - a selection-only comparison (runner `--list` with and without `jq`);
  - the full execution, which moves to `--ci-full`.
- **Diff-scoped `check-*-added` guards.** They are cheap, but they read the
  whole tree and so run on every change. Give each its pathspec: they
  already filter by suffix, and the map then scopes them.
- **`tillandsias-headless` inputs.** It is selected by almost every diff,
  because its sources name `plan/…` and `methodology/…` paths. Moving those
  constants into data files read at test time would let the map see through
  them.

### c. Move to `--ci-full` only (release tier)

These exercise end-to-end runtime behaviour, not the edited unit, and the
release tier already runs the litmus suite:

- `test-litmus-runner-reads-without-jq.sh`, full execution half (91 s);
- `test-tool-materialize-litmus-surfaces-arm.sh` (69 s);
- `test-token-instrument.sh` (67 s);
- `test-fleet-activity.sh` (59 s);
- `test-archiver-ruby-could-not-run.sh` (45 s).

Together that is about 331 s. 1916-gbct's own exit criterion requires a
listing proving none is dropped. Each moved step keeps a `--changed`
selection, so an edit to its inputs still runs it on the warm loop.

### d. Next steps, in order

1. Fix the four waits (248 s, no coverage change).
2. Install `strace` in the builder toolbox (a toolbox package, not a host
   layer). Record traced inputs once per fixture change, and union them
   with the declared map to close the residual-risk gap.
3. Add the result cache keyed on the map (a).
4. Do the litmus split and the moves to `--ci-full` (b, c).
5. Use the per-crate cargo-nextest binary list instead of `-p` sets, which
   would meet 1916-tsel's "at most 3 test binaries" criterion directly.
