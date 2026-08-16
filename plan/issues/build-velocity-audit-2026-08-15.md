# Build-Velocity Audit — 2026-08-15

Repo: `/home/tlatoani/claudia/tillandsias` (branch `linux-next`, host macuahuitl).
Scope: the per-cycle compute tax of the hourly meta-orchestration loop. Every number below was re-verified against the current tree and `/tmp/tillandsias-timing.jsonl` (146 records, 697-s3by/682-emvg grammar, 693-tf79 rejection live) during synthesis; investigator line citations that had drifted are corrected to current line numbers. Operator constraint honored throughout: gates may be **narrowed in scope, never silently skipped** — every proposal below fails closed to a full run or fails loud, and the keep-unconditional list is explicit.

## 1. Per-cycle cost model (steady state, telemetry-anchored)

| Component | Per-run cost | Runs/cycle | Per-cycle cost | Compounds? | Evidence |
|---|---|---|---|---|---|
| cycle-preflight (release build of tillandsias-plan, warm no-op) | ~2.8s | 1 | ~3s | per-cycle | `scripts/cycle-preflight.sh:59-72` |
| `./build.sh --check` — timed block | p50 8.1s green (n=52), p90 12.2s, max 20.7s; all-runs p50 7.1s (n=71) | 2–5 | 16–50s | per-cycle | `/tmp/tillandsias-timing.jsonl` `step=build-check`; invoked per packet + per rebase retry + at Finalization (`skills/advance-work-from-plan/SKILL.md:232-234,300`; `skills/meta-orchestration/SKILL.md:1001`) |
| `--check` untimed preamble (git-hooks grep, podman registries, dev-proxy ensure, sidecar staging probe) | ~1–3s typical; **15s worst** (proxy health wait, `max_retries=15` at `build.sh:448`); **30–120s+ after a VERSION bump** (musl sidecar rebuild + headless recompile cascade) | per `--check` | 3–15s typical | per-cycle | timer starts at `build.sh:1081-1082`, preamble at `:357/:483/:495/:715` runs before it — invisible to `timing:` |
| Instant litmus suite (236 pre-build instant tests) | median ~14.8s of substantive runs (n=33 >5s); ~1.4s fixed empty-suite runner floor | 1–6 | 15–90s | per-cycle | `timing.jsonl` `litmus-suite`; six 13.9–18.4s runs 17:05–17:11 on 2026-08-15; `scripts/local-ci.sh:1184` (fast mode), MO smoke mode |
| Startup guards + `git fetch --prune` + worktree snapshot | seconds | 1 | ~5–10s | per-cycle | `skills/meta-orchestration/SKILL.md` preflight section |
| `--ci-full` e2e gate (rate-limited 1/4h, `WINDOW=14400` in `scripts/forge-e2e-rate-limit.sh:35`) | **quick-tier pre-build litmus 251.6–268.9s** (n=3; 2 red runs paid full price — `set +e` run-all design, `local-ci.sh:60`) + clippy `--all-features` + tests + fat-LTO install ~64s + guest binaries via nix (cold = 10–30min after any commit) | ¼ amortized | ~90–150s+ amortized; multi-minute spikes | per-ci-full-cycle | `timing.jsonl` `local-ci-phase-pre-build`; `local-ci.sh:425` maps pre-build→`--size quick` (cumulative: 236 instant + 55 quick = 291 tests) |
| Per-commit tray recompile tax | ~3–6s extra per subsequent `--check`, ×~5 compile variants | — | folded into `--check` variance | per-commit | F6 below; post-commit checks 9–12s vs 5.5–7s clean |

**Fixed tax per typical hourly cycle: ~60–150s before any actual work**, spiking to many minutes on ci-full cycles, post-VERSION-bump cycles, and post-cache-reset cycles. 13+ minutes were burned on three back-to-back red/green ci-full pre-build litmus runs on the morning of 2026-08-15 alone.

## 2. Findings

### F1 — The quick-tier litmus lane inside `--ci-full` is the single largest per-cycle sink: ~4.2–4.5 min, paid in full even when red
`local-ci.sh:425` maps phase pre-build to `--size quick`; `run-litmus-test.sh:429-450` makes sizes cumulative, so the gate runs 236 instant + 55 quick pre-build tests (verified counts; 44 of the 55 quick tests invoke cargo). Measured 251,607–268,914ms across 3 runs; two exited 1 and still paid the full cost because `local-ci.sh:60 set +e` is a run-every-check design. Selection is by phase/size/host-kind metadata only (`run-litmus-test.sh:1069` and surrounding) — **no test declares its input paths**, so a plan-fragment-only diff pays the same 254s as a cross-crate refactor.

### F2 — `./build.sh --check` is the loop's fixed per-invocation tax, and its telemetry floor hides the preamble
Timed block (`build.sh:1075-1335`): fmt (`:1084`), `cargo check --workspace` (`:1091`), `clippy --all-targets` (`:1095`), `clippy --all-targets -p tillandsias-headless --features listen-vsock` (`:1099`), `cargo run -q -p tillandsias-plan -- check` (`:1103`), `cargo run -q -p tillandsias-policy -- plan-orders` (`:1110`), 13 guard scripts (`:1130-1296`) + report-only windows check (`:1311`), then `_write_gate_stamp` (`:1329`). The 682-emvg timer starts at `:1081` — **after** the preamble (hooks `:357`, registries `:483`, dev-proxy ensure `:495` with a 15×1s health-wait worst case at `:448`, sidecar staging `:715`). The `timing:` rolling line can therefore never name the post-VERSION-bump sidecar rebuild as the slowest step. Run 24–40×/day in clusters of 2–5 per cycle.

### F3 — `cargo check --workspace` inside `--check` is fully subsumed by the clippy pass that follows it
`build.sh:1091` runs `cargo check --workspace`; `:1095` runs `cargo clippy --all-targets -- -D warnings` over the same (virtual-manifest, all-members) workspace — the full compiler frontend over a strict superset of targets, failing on every diagnostic check would report, in a **separate fingerprint universe** so nothing is shared. `_require_host_build_tools` (`build.sh:512`) hard-requires `clippy-driver`, so no host can run check but not clippy. Verified: no litmus test, skill, or script pins the "Type-checking workspace" banner text. This is the rare narrowing with **zero silent-green surface**.

### F4 — The cycle maintains 4–5 disjoint compilation caches of the same workspace; one core-crate edit is re-frontend-compiled up to 5×
Variants per cycle: `cargo check --workspace`; `clippy --all-targets`; `clippy --all-targets -p headless --features listen-vsock`; debug `cargo run` of plan/policy (`build.sh:1103/:1110`) despite cycle-preflight having just built tillandsias-plan in **release** profile; and on ci cycles `local-ci.sh` adds `clippy --workspace` (`:953`, default targets — mostly warm after a `--all-targets` run, but not flag-identical) and the genuinely disjoint `clippy --workspace --all-targets --all-features` (`:973`, different feature resolution = different fingerprints = real second compilation; the heaviest single check). `trace-coverage.sh` executes up to 3× per dispatch (`_check_trace_coverage` plain + `--gate` at `build.sh:669/:678`, guarded once-per-process; `--gate` again in `_write_gate_stamp` at `:845`). Daily-maintenance `cargo clean` (conditional, "when bloated/stale" — `skills/meta-orchestration/SKILL.md:238`) resets all variants at once; the next `--check` is a minutes-long full recheck.

### F5 — The pre-push edge is already optimal, but the gate stamp is scope-blind: the silent-green pivot for all scoping work
`scripts/gate-stamp.sh` content-hashes every tracked+untracked file (~60ms over ~4,241 files, stamp in the git dir); the pre-push hook (`scripts/hooks/pre-push-local-gate.sh`) verifies it, with the 668-2xeh plan-only lane fail-closing loudly on every unclassifiable input. **The stamp records THAT a gate passed against these bytes, not WHICH gate** (verified: no scope concept in gate-stamp.sh), and `_write_gate_stamp` writes it identically from `--check`, `--ci`, and `--ci-full`. Any future scoped `--check` writing today's stamp format would let pre-push bless a push whose Rust the scoped run never compiled. Every scoping proposal below is therefore gated on a scoped-stamp prerequisite.

### F6 — Four fingerprint-busting channels force needless recompiles across all variants
1. **macos-tray** (`crates/tillandsias-macos-tray/build.rs:55-56`) tracks `.git/HEAD` **and `.git/index`** — the index mtime moves on every add/commit/status refresh — and `:31-32` stamps `TILLANDSIAS_BUILD_TIME` from `date -u` when `SOURCE_DATE_EPOCH` is unset, so every build-script rerun changes the env and forces a recompile. The crate compiles (as a cfg-gated stub) on every host, so this taxes Linux cycles too.
2. **windows-tray** (`build.rs:82-92`) tracks `refs/heads/<branch>` + `packed-refs` — every commit (~3/hour) busts it. A `BUILD_COMMIT_SHA_OVERRIDE` hook exists (`:94`) but the `.git` rerun directives are unconditional, so the override alone cannot stabilize the fingerprint.
3. **Sidecar staging** (`scripts/build-sidecar.sh:49-63`): `is_stale` runs `find -newer` over 3 crates + `Cargo.toml` + `Cargo.lock` + **VERSION** (deliberate per order 710-w9kc's version-matched-artifact intent — but the binary embeds only `WIRE_VERSION`, `build_version: None`, so VERSION-triggered rebuilds are byte-identical), and the unconditional `cp` (`:157`) bumps the staged file's mtime, tripping tillandsias-headless's `rerun-if-changed` asset tracking and recompiling the workspace's largest crate across all variants. Fires after every `--install`'s build-counter bump (`build.sh:581-588`), before the `--check` timer.
4. **VERSION blast radius**: `rustc-env` + `rerun-if-changed` in browser-mcp/host-shell/windows-tray build.rs, `include_str!` in `headless/src/remote_projects.rs:94`; `scripts/bump-version.sh:93-107` additionally rewrites 4 crate Cargo.tomls with `sed -i` **even when SEMVER is unchanged** (same-day bumps), touching mtimes that feed the `find -newer` staleness probes.

### F7 — The crane/nix lane rebuilds ALL dependencies on every commit, locally and in CI (the live content of open packet 606-um5s)
`flake.nix:43-59`: `craneSrc = cleanSourceWith` filtering only build outputs; all four `buildDepsOnly` calls (`:93/:109/:125/:160`) inherit `commonCraneArgs.src = craneSrc`, so the deps derivations' input hashes change on ANY file change and cached dep artifacts can never re-hit across commits. `scripts/build-guest-binaries.sh:187-200` prefers `nix build` whenever nix is on PATH (it is), and is invoked by `_prepare_ci_full_install_inputs` (`build.sh:875-895/:927`) on every `--ci-full --install` — cold-compiling ~1,000 dep crates for two musl targets. `release.yml` caches only the nix store keyed on `flake.lock` (`:41-43`; regression warning `:181-183`); no binary cache exists.

### F8 — No cross-worktree artifact sharing, no sccache, 74GB unGC'd target/
`sccache` not installed; no `RUSTC_WRAPPER` or shared `[build] target-dir` in `.cargo/config.toml` (verified). `target/` = 74GB; the one live agent worktree has its own separate 281MB partial target (no sharing — each spawned worktree pays a cold dep build). Disk headroom is currently 261GB, so this is hygiene, not emergency.

### F9 — Every cycle-end `--install` pays fat LTO + codegen-units=1
Root `Cargo.toml:105-108`: `lto = true, strip = true, codegen-units = 1`. The in-forge cycle contract mandates a cycle-end install; a warm run measured 1m04s (investigator-cited from `plan/loop_status.d/20260812t235600z-*.md`), dominated by the single-threaded fat-LTO link.

### F10 — Telemetry blind spots make the next optimization round guesswork
Only three step names exist in the timing log: `build-check` (whole block), `local-ci-phase-<phase>` (litmus phase only — `local-ci.sh:432-452` wraps just `run_litmus_phase`), `litmus-suite`. Untimed: the entire build.sh preamble, each of the ~15 guard scripts (investigator-measured once: fragment-status-loss 2,381ms, groundtruth-mutable-status-pins 1,083ms, trace-coverage `--gate` 1,697ms, gate-stamp compute 322ms, most others ≤150ms), local-ci's rust lanes individually, and per-litmus-test durations — so the 254s quick lane cannot be ranked test-by-test.

### F11 — Two fail-loud scoping precedents already define the required shape
634-39ik (`scripts/check-litmus-expression-pinning-added.sh:69-73`): diff vs `origin/linux-next` + untracked, loud verdict, **fail-open on missing base ref is correct there because the guard only ADDS enforcement**. 668-2xeh (`pre-push-local-gate.sh:100-276`): fail-closed on every unclassifiable input, one loud line per accepted file, "can only ACCEPT a strictly smaller class." Any selector that **removes** coverage must invert 634-39ik's polarity: missing base ref, unparseable diff, unknown path, stale full-run anchor → FULL run, loudly.

### F12 — The keep-unconditional set (excluded from all scoping by design)
gate-stamp verify + release-preflight (pre-push trunk anchors); ghost-trace ratchet (phase 1 — its input domain is "any file containing @trace", not a path family); `check-version-bump-isolation` + version monotonicity (any class can sweep VERSION; the dd8fd63f fleet-block incident); guard-activation audit (the meta-guard against guards silently unwiring — scoping the detector of scope-rot is circular; the 599-4wzr failure class); python/base64 bans (operator non-negotiables that once silently evaporated, `local-ci.sh:721-739`); plan-schema-divergence, mo-full-attestations, podman-sync-budgets, script-exec-bits, and the three already-diff-scoped `added-*` guards (6–10ms each). The litmus runner's explicit-filter zero-match failure (`run-litmus-test.sh:1443-1463`) must survive any selector: an all-skipped scoped selection must report its skip count and base ref loudly, never pass vacuously. Total cost of this set is ~2.5s per `--check` — the velocity argument for touching it is absent while the silent-green argument against is decisive. Note in passing: `check-groundtruth-mutable-status-pins.sh:35-38` already soft-skips when tillandsias-plan isn't built (loud note to stderr) — pre-existing behavior, not introduced here, but worth hardening when the selector work touches that guard.

## 3. Ranked action plan

Ranking = est. seconds saved per hourly cycle, weighted against risk and implementation size. **Compounding** = saved every cycle forever; **event-scoped** = saved on specific recurring events (ci-full, VERSION bump, release, cache reset).

| # | Action | Est. saved/cycle | Compounds? | Risk | Vehicle |
|---|---|---|---|---|---|
| 1 | Per-step gate telemetry (preamble record, per-guard, per-check, per-litmus-test) | 0 direct — evidence substrate for every other row; operator's measure-before-optimize rule | — | none (682-emvg best-effort contract) | packet + quick win (preamble record) |
| 2 | Diff-scoped litmus via `inputs:` metadata + `--diff-scope`, fail-closed | ~40–60s amortized (≈200s on ci-full cycles; ~12s on instant-only cycles) | event-scoped (ci-full) + per-cycle (instant) | silent-green if annotations too narrow — contained by explicit-flag-only, 24h full ratchet, dead-glob guard, full-on-unknown | packet (needs #3 first) |
| 3 | Scoped gate stamp + scope-aware pre-push comparison | 0 direct — the prerequisite that makes #2/#5/#6 safe at the trunk boundary | — | must fail closed on parse ambiguity | packet |
| 4 | Sidecar byte-stable restage (`cmp`+`touch`-else-`cp`) | ~15s amortized (kills the post-VERSION-bump headless×5-variant cascade) | event-scoped (every install cycle) | near-zero — can only reduce false-positive restages, ELF assert unchanged | quick win + packet (stamp redesign, thin-LTO sidecar dev lane) |
| 5 | Stamp-based `--check` memoization (identical bytes → loud early exit) | ~15–25s (converts 2nd–5th `--check` of a cycle to ~0.3s) | per-cycle | environmental drift the hash can't see — fold toolchain versions into stamp, force knob, never-silent verdict | packet |
| 6 | Change-class selector; pilot on the two heavy plan/litmus guards | ~10s pilot, ~15s full matrix | per-cycle | misclassification — unknown→FULL, build-tooling→FULL, 24h ratchet, per-skip loud lines; needs operator approval (bar_raise_governance symmetry, `methodology/convergence.yaml:410`) | packet (needs #3) |
| 7 | Drop `cargo check --workspace` from `--check` | ~8s (2–4s × 2–5 runs) | per-cycle | ~zero; verified no banner-text pins | quick win |
| 8 | Tray fingerprint stabilization (overrides in check/clippy/test lanes only) | ~8–12s | per-commit-cycle | false provenance if leaked into artifact lanes — hard-refuse overrides in `--install`/`--release`; e2e freshness gate fails loud on override binaries (correct direction) | quick win (.git/index untrack) + packet (overrides) |
| 9 | Crane depsOnly source fix + binary cache (extends 606-um5s) | minutes per ci-full/release event | event-scoped | over-narrow filter fails LOUD at build; real hazard is unverified success — assert deps-.drv stability in release workflow | packet |
| 10 | Skip podman registries + dev-proxy for ALL check-only dispatches | ~5s typical, 45s pathological | per-cycle | ~zero — `--check` never touches podman (`build.sh:80-92` header); forge carve-out already trusted | quick win |
| 11 | Thin-LTO cycle-end dev install (fat LTO stays on tagged releases/nix) | ~25s on install cycles | event-scoped | PSK is a hash of the running binary — verify guest+host binaries in one cycle come from the same lane before enabling | packet |
| 12 | local-ci clippy `--all-targets` alignment (up) | ~4s on ci cycles | event-scoped | none to coverage (strictly wider); trunk already clean at `--all-targets -D warnings` | quick win |
| 13 | bump-version.sh content-conditional sed | ~2s indirect | event-scoped | none — real SEMVER changes still rewrite | quick win |
| 14 | sccache (worktree lanes only) + bounded target GC | ~5s amortized + cold-start minutes | event-scoped | mis-scoping slows the hot loop — never enable for main checkout | packet |

Quick wins total ≈ **40s/cycle compounding**; packets add ≈ **60–90s/cycle** steady state plus multi-minute reductions on ci-full, release, and cold-cache events. At 24 cycles/day, the quick wins alone recover ~16 minutes of compute per day.

## 4. Fail-loud invariants carried into every draft
1. A selector that removes coverage fails **closed** to a FULL run on: missing/unfetchable base ref, unparseable diff, unclassifiable path, stale (>24h) full-run anchor, guard-script-self-modified.
2. Every skip prints one attributable line naming the gate, the class evidence, the base SHA, and the last full-run timestamp.
3. A scoped gate may never write an unscoped stamp; pre-push refuses a stamp whose scope does not cover the outgoing diff's classes.
4. Zero-selection is a loud report, never a vacuous green (642 semantics preserved).
5. Release lane (`merge-to-main-and-release`), nightly/daily anchor, and tagged artifacts always run FULL and always build with real provenance (no SHA/build-time overrides).
6. The keep-unconditional set (F12) lives as data with a per-entry incident citation, so removing an entry is a reviewable diff against a stated reason.
7. Scope reduction requires Tlatoani approval as the symmetric twin of `bar_raise_governance` — the loop must not self-enact it.

## 5. Contradictions resolved during synthesis
- **Telemetry stats**: investigator 1 (p50 7.8s, n=52) filtered to exit=0; investigator 3 (p50 7.1s, n=71) counted all runs. Both correct; re-measured today: green n=52 p50 8.06s p90 12.2s.
- **Litmus counts**: 240 instant / 66 quick is all-phases by size; 236 / 55 is the pre-build phase the gate actually runs. Cargo-invoking quick tests: **44 of 55 pre-build** (investigator 1's "55 of 71" was an overcount).
- **Worktree target**: investigator 2 reported none; the worktree now has its own 281MB partial target. The substantive claim (zero artifact sharing, cold builds per worktree) stands.
- **Daily `cargo clean`**: conditional ("when bloated/stale", MO SKILL.md:238), not unconditional daily as investigator 1 implied. The cold-recheck event is real but less frequent.
- **Sidecar VERSION staleness**: not "pure waste" as filed — order 710-w9kc's comment declares the version-matched-recompile intent. The waste is the **mtime cascade into headless** for a byte-identical binary; the fix (byte-compare restage) removes the cascade while preserving 710-w9kc semantics on artifact lanes.
- **Clippy flavor mismatch cost**: investigator 1's "shares no fingerprints" overstates the `--workspace` vs `--all-targets` pair (lib/bin units are shared); the genuinely disjoint flavor is `--all-features` (different feature resolution). Alignment is still worth one flag, at a reduced estimate.
- **`--diff-scope` on ci-full**: investigator 3 both excluded ci-full from scoping and claimed 3–4min savings there. Resolved: the **in-loop, rate-limited** ci-full quick lane is the scoping target (that is where the 254s lives); the release lane, daily anchor, and any unprovable diff always run FULL.
- **build.sh line numbers**: all investigator citations had drifted; every span above is re-anchored to the current tree (e.g., `--check` block at :1075-1335, carve-out at :359-370, guards at :1130-1311, `_write_gate_stamp` at :825-859).


## Appendix: endorsed quick wins (machine-readable, packet 765-uti9)

```json
[
  {
    "title": "Drop the redundant cargo check --workspace from build.sh --check",
    "change": "In /home/tlatoani/claudia/tillandsias/build.sh, delete the three lines at :1090-1093 (the \"Type-checking workspace...\" step, the `cargo check --workspace` invocation, and its _info line); reword the clippy step banner at :1094 to \"Running clippy (strict — carries workspace type-checking)...\". Verified: `cargo clippy --all-targets -- -D warnings` at :1095 runs the identical compiler frontend over a strict superset of targets on the same virtual-manifest workspace, clippy-driver is a hard host requirement (:512), and no litmus test, skill, or script pins the \"Type-checking\" banner text.",
    "est_seconds_saved_per_cycle": 8,
    "risk": "Near-zero: coverage strictly unchanged (clippy subsumes check diagnostics). A type error now surfaces under the clippy banner instead of a dedicated step — cosmetic only, and the banner reword documents it."
  },
  {
    "title": "Skip podman registry setup + dev-proxy ensure on ALL check-only dispatches",
    "change": "In /home/tlatoani/claudia/tillandsias/build.sh, drop the `TILLANDSIAS_HOST_KIND == forge` condition from _forge_check_only_without_host_podman_setup (:360) — or add a parallel _check_only_dispatch predicate with the same all-other-flags-false shape (:361-368) — so the existing loud skips at :480-482 and :492-494 fire for every check-only invocation on any host. The --check header comment (:80-92) already documents that --check never touches Podman; the carve-out is trusted today, just keyed to host kind instead of dispatch kind.",
    "est_seconds_saved_per_cycle": 5,
    "risk": "Effectively none: --check builds no containers. Worst case a --check with a changed lockfile loses proxy caching for one cargo fetch — slower, never wrong. Combined dispatches (--check --install etc.) still run setup because the predicate requires every other flag false. Removes the 15×1s health-wait pathological stall (:448)."
  },
  {
    "title": "Byte-stable sidecar restage: stop the post-VERSION-bump headless recompile cascade",
    "change": "In /home/tlatoani/claudia/tillandsias/scripts/build-sidecar.sh at :156-158, replace the unconditional `cp \"$SRC\" \"$SIDECAR_DEST\"` with: if cmp -s \"$SRC\" \"$SIDECAR_DEST\"; then touch \"$SIDECAR_DEST\"; echo \"[build-sidecar] staged binary unchanged (byte-identical) — freshness marked, no restage\"; else cp \"$SRC\" \"$SIDECAR_DEST\"; fi (keep chmod). The touch marks verified freshness so is_stale stops re-triggering, and the staged file's mtime only moves when bytes change, so tillandsias-headless's rerun-if-changed asset tracking no longer forces a ~5-variant recompile of the largest crate after every build-counter bump.",
    "est_seconds_saved_per_cycle": 15,
    "risk": "Low: the change can only suppress restages of byte-identical output — a real byte change always copies, and the existing ELF-format assert (order 723-b9cn) runs before this point unchanged. The touch is truthful (bytes proven identical to a fresh build). Preserves order 710-w9kc's version-matched intent: the rebuild still runs; only the no-op copy is elided."
  },
  {
    "title": "Stop macos-tray recompiling on every git index touch",
    "change": "In /home/tlatoani/claudia/tillandsias/crates/tillandsias-macos-tray/build.rs, delete the `cargo:rerun-if-changed=../../.git/index` directive at :56 and replace it with the resolved refs/heads/<branch> + packed-refs tracking that windows-tray/build.rs:75-92 already implements (with its documented rationale: HEAD alone misses same-branch commits, index churns on every status refresh). The crate builds as a cfg-gated stub on every host, so this fires in every Linux cycle's check/clippy/test variants.",
    "est_seconds_saved_per_cycle": 8,
    "risk": "Low: the SHA still refreshes on every commit/branch switch (refs tracking), so embedded provenance is unchanged for any committed state; only uncommitted index churn stops forcing rebuilds. The `date -u` BUILD_TIME fallback still busts on legitimate reruns — that (and the override-env design) is deliberately left to the tray-fingerprint packet since it touches artifact provenance."
  },
  {
    "title": "Make bump-version.sh Cargo.toml rewrites content-conditional",
    "change": "In /home/tlatoani/claudia/tillandsias/scripts/bump-version.sh, wrap the per-file sed/awk at :93-107 with: grep -q \"^version = \\\"${SEMVER}\\\"\" \"$cargo_toml\" && continue. Same-day build-counter bumps (SEMVER = MAJOR.MINOR.YYMMDD is unchanged within a day) then stop rewriting 4 Cargo.toml mtimes that feed the find -newer staleness probes in build-sidecar.sh and build-guest-binaries.sh.",
    "est_seconds_saved_per_cycle": 2,
    "risk": "None: a real SEMVER change fails the grep and rewrites exactly as today. The guard is content-conditional, so no coverage or versioning behavior narrows."
  },
  {
    "title": "Align local-ci's default clippy lane up to --all-targets",
    "change": "In /home/tlatoani/claudia/tillandsias/scripts/local-ci.sh:953, change `cargo clippy --workspace -- -D warnings` to `cargo clippy --workspace --all-targets -- -D warnings` (flag-identical to build.sh's gate at :1095 modulo --workspace, which is implied by the virtual manifest). Aligning UP: strictly more coverage, and the lane becomes a warm near-no-op after a same-tree --check. Update the failure hint text at :395 to match.",
    "est_seconds_saved_per_cycle": 4,
    "risk": "None to coverage (strictly wider; trunk is already held clean at --all-targets -D warnings by the gate). Standalone local-ci runs on trees where --check never ran get slightly slower. The heavy --all-features flavor at :973 is untouched."
  },
  {
    "title": "Emit a build-preamble timing record so the invisible tax becomes visible",
    "change": "In /home/tlatoani/claudia/tillandsias/build.sh, capture `_PRE_T0=$(timing_now_ms)` immediately after timing-log.sh is sourced (:66-67) and emit `timing_emit build-preamble preamble \"$_PRE_T0\" 0` just before the --check block's own timer starts (:1081). Covers hooks install, registry setup, dev-proxy ensure, and sidecar staging — the exact span where the post-VERSION-bump sidecar rebuild currently hides from `timing: slowest=`.",
    "est_seconds_saved_per_cycle": 0,
    "risk": "None: 682-emvg contract — timing_emit is best-effort and returns 0 unconditionally, so it cannot alter any exit code. Zero direct savings; this is the evidence substrate the operator's measure-before-optimize rule requires before the next round."
  }
]
```
