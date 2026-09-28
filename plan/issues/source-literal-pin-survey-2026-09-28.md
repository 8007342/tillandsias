# Source-literal pin survey — 827-d3dc (2026-09-28)

A survey, not a sweep (the row's own deliverable). It inventories the tests that
assert a LITERAL is present in, or absent from, a SOURCE file, classifies them,
and proposes behavioural replacements for the ten that cost the most. Acting on
the proposals is a separate, operator-visible decision (bar_raise_governance).

Measured on `origin/linux-next` 3c8f8ced2 by tlatoanis-macbook-air. Citations
name files and SYMBOLS, never line numbers (check-issue-citation-convention).

## Why this matters now

These pins break a CORRECT change and leave a WRONG one passing. The coordinator
reports land85 going red three times on 2026-09-28 from pins on a representation
that a correct change moved. The row was filed after three in one session. Every
repair so far went the same direction: re-express the pin against a value a
function BUILDS (`proxy_exec_preamble`, `readiness::ready_unit`,
`provision_user_data_for_test`). Each repair was strictly stronger than the grep
it replaced, because a literal can be present in source and still never reach
runtime.

## Inventory

1,640 pin sites in three populations. The census (appendix) is a heuristic over
syntax, so read the classes as candidates rather than verdicts. Only the ten
entries below were classified by reading.

| class (heuristic) | litmus | shell fixtures | rust tests | total |
|---|---:|---:|---:|---:|
| (a) presence, code EXPRESSION pinned | 550 | 25 | 60 | 635 |
| (a) presence, IDENTIFIER pinned | 271 | 8 | 16 | 295 |
| (a) presence, other literal | 485 | 33 | 13 | 531 |
| (a) presence, COMMENT/prose pinned | 90 | 7 | 1 | 98 |
| (a) presence, CLI flag pinned | 27 | 0 | 0 | 27 |
| (b) ABSENCE scan | 44 | 2 | 2 | 48 |
| (c) target file gone | 6 | 0 | 0 | 6 |
| **total** | **1473** | **75** | **92** | **1640** |

What each population is:
- **litmus**: `grep` of a source file in an `openspec/litmus-tests/*.yaml` `command:` line.
- **shell fixtures**: `grep` of a file under crates/, scripts/ or images/, or build.sh, in `scripts/test-*.sh`.
- **rust tests**: `include_str!(<source>)` followed by `.contains(` in a test.

Readings:

- **Expression pins are the fragile majority (635).** A signature, a closure
  shape or an argument list all change under refactors that preserve behaviour.
  The most expression pins per file: crates/tillandsias-windows-tray/src/main.rs
  (20), litmus-inference-model-preload-policy (14),
  litmus-runtime-diagnostics-typed-events-shape (14), crates/tillandsias-macos-tray/src/main.rs (13).
- **Comment pins (98) pin documentation.** A reworded explanation reds a gate,
  and the code it explains can change freely. These are the cheapest to retire.
- **Absence scans (48) are the legitimate class (b)**, but only the WHOLE-FILE
  ones. Two examples: the sleep-poll ban in crates/tillandsias-headless/src/tray/mod.rs,
  and the CA chmod ban in crates/tillandsias-macos-tray/src/diagnose.rs. Absence
  of ONE SPELLING is the trap: it passes silently the moment the spelling changes
  (entry 2).
- **(c) target gone (6)**: three litmus files point at `scripts/build.sh`, which
  does not exist: litmus-build-cache-transparent, litmus-build-clean-from-scratch-works
  and litmus-ci-unchanged-behavior. All three are `phase: retired` with a tombstone
  in methodology/event/007-build-script-architecture-litmus-tombstone.yaml, so they
  never run. Recommendation: delete their steps; retired is not a reason to keep
  a pin that cannot pass. (The other synthetic "missing" targets are fixtures'
  scratch files and are not counted.)

## The ten that cost the most, with behavioural replacements

Ranked by commits labelled as repairs that rewrote the pin, in the last 45 days.
Each entry was checked by reading the current tree and the repair commit.

1. **crates/tillandsias-headless/src/main.rs — the `source_window` pins on `run_init`** (class a).
   - **Pin:** the window is found by the FULL signature `fn run_init(debug: bool, force: bool)` and asserts it contains `INIT_IMAGES`. The same fact is pinned again as `&INIT_IMAGES` and `let images = INIT_IMAGES;`.
   - **Fragility:** adding a parameter panics the test.
   - **Replacement:** `cleanup_init_logs_covers_every_init_image_and_nothing_else` already tests the cleanup behaviourally through `cleanup_init_logs_in(dir, &INIT_IMAGES)`, so delete its source tail. Keep `INIT_IMAGES.contains(&"web")`. At minimum, anchor any remaining window on `fn run_init(`.
   - **Evidence:** a71853f14 moved two pins "because the literal moved, not the property".
2. **crates/tillandsias-headless/src/tray/mod.rs — `!labels.any(contains("GitHub Login"))`** (class a, silent).
   - **Replacement:** walk `flatten_layout(&build_menu(&state), …)` and assert no node id equals `MENU_ID_LOGIN`. The id is the contract; the spelling is not. Keep the spelling check only in `confirmed_signed_out_row_uses_canonical_github_spelling`, whose subject IS the spelling.
   - **Evidence:** 04ade3b56 found three absence asserts testing `"GitHubLogin"`, a spelling that never renders, so they could never fail.
3. **crates/tillandsias-vm-layer/src/vz.rs — the fetch-unit test asserting `After=home-forge-src.mount`** (class c, and it hides a PRODUCT defect; see "Finding" below).
   - **Replacement:** call `provision_user_data_for_test()`, extract the fetch unit, and assert its `After=` names the mount unit derived from `tillandsias_core::guest_bin_path::GUEST_BIN_MOUNT`, while `RequiresMountsFor=` stays absent. The staged-path pin should compare against `GUEST_STAGED_BINARY` rather than a copied literal.
   - **Evidence:** 454329a42 wrote the pin for the old share. 14f1aaa5b moved staging to `guest-bin`, updated the staged-path pin, and missed this one.
4. **crates/tillandsias-headless/src/accel_probe.rs — `the_macos_arm_cannot_advertise_the_container_lane`** (class a).
   - **Pin:** a scan anchored on the comment `PROBE-7: macOS Metal is host-native ONLY` and ended at the first `});`.
   - **Fragility:** a reworded comment or a nested `});` breaks it or quietly narrows it.
   - **Replacement:** move the Metal `DeviceRecord` out of `enumerate_gpus`'s `cfg(target_os = "macos")` block into a function compiled on every host, the way `provision_user_data` was split out in vz.rs. Then assert `lanes == ["host-native"]`, `unusable_reason.is_some()` and `memory_model == Some("unified")` on every gate host.
   - **Evidence:** 01962efc0, 1bc890553.
5. **crates/tillandsias-macos-tray/src/diagnose.rs — `github_login_host_prompts_after_control_wire_ready`** (class b today).
   - **Pin:** the order of five exact spellings inside `github_login_main`, including a closure `|t| {`.
   - **Why it stays source-shaped:** `github_login_main` drives the VM and has no seam.
   - **Now:** loosen it to call NAMES only (`wait_phase_ready(`, `open_control_wire_stream(`, `prompt_line(`, `exec_over_stream_expect_dynamic`).
   - **Later:** extract the login sequence the way `proxy_exec_preamble` was extracted.
   - **Evidence:** 2270a66d0 ("two literal pins repaired upward").
6. **crates/tillandsias-windows-tray/src/wsl_lifecycle.rs — the provisioning window cut between two COMMENTS** (class a).
   - **Pin:** the window runs from `// Enable AND start the units now.` to `// Phase 3d:` and asserts `systemctl enable tillandsias-headless-ready.service` and not `enable --now`. Three tests share those comment markers.
   - **Replacement:** move the string passed to `wsl_root_sh` into a const or builder and assert on the value. The precedent is 00dd6974a, which moved about ten such pins onto `readiness::READY_SCRIPT` / `ready_unit(…)`.
   - **Evidence:** 8060ea35d, 00dd6974a.
7. **litmus-plan-only-push-lane-shape — the `grep -q 'attempt_plan_only_lane'` step** (class c).
   - **Replacement:** a later step already RUNS the real pre-push hook in a scratch repo and asserts its `plan-only lane: validated` output, so the function-name grep adds only a way to fail on a rename. Delete it and keep `bash -n`.
   - **Note:** this file's high churn is really a setup block copied into nine steps (f18dc0d74 rewrote all nine for one path bug). A shared setup script would stop it.
8. **litmus-cycle-batch-triage-shape — the default-routing step** (class a; not a source pin).
   - **Problem:** it runs the selector against the live ledger and, when the host is not ordinal-routed, prints `ok: default-routing n/a`, so it cannot fail.
   - **Replacement:** force the routing through the selector's existing environment seams (`TILLANDSIAS_CAP_HOSTS`, `TILLANDSIAS_WORKSTATION`, `TILLANDSIAS_ROUTE_ROT`), so `route=rank:` is always exercised and the n/a branch goes away.
   - **Evidence:** d1a9516cc rewrote 22 lines.
9. **litmus-guest-container-metrics-wire-shape — `WIRE_VERSION: u(16|32) = 4`** (class a).
   - **Problem:** its real claim is "adding the metrics variants renumbered nothing, so old peers still decode". The version is a premise that unrelated changes keep moving (rebased 2→3→4).
   - **Replacement:** check in a golden `encode(...)` frame for `MetricsSnapshotRequest` and assert `decode(golden)` round-trips, next to `metrics_snapshot_request_roundtrip`.
   - **Evidence:** f41a64f15, b1f4ada5e.
10. **litmus-forge-expert-base-guard-shape — the awk ORDER pin over lib-common.sh's host-mount block** (class a).
    - **Pin:** a `sed` window keyed on 4-space indentation, then awk requires `rewrite_origin_for_enclave_push` < `checkout_forge_seed_branch` < `return 0` by line. Comments count.
    - **Replacement:** extract `_clone_project_from_mirror_impl` the way the next step already extracts `checkout_forge_seed_branch`. Stub `rewrite_origin_for_enclave_push`, `configure_git_identity` and `trace_lifecycle` to log their order, run it in a scratch repo with `TILLANDSIAS_PROJECT_HOST_MOUNT=1`, and assert the logged order and HEAD. It needs one seam, because `clone_dir` is hard-coded.
    - **Caveat:** re-run here, the awk passes on linux-next tip and on 957d48faf (u8ww). The red the coordinator saw on land85 was not reproduced from this checkout, so treat its cost as reported rather than measured.

## Finding: a product defect behind pin 3

`provision_user_data` in crates/tillandsias-vm-layer/src/vz.rs writes
`tillandsias-headless-fetch.service` ordered `After=home-forge-src.mount`. Since
14f1aaa5b (1019-ivia), the staged binary arrives on the `guest-bin` virtiofs share,
mounted at `GUEST_BIN_MOUNT` (`/var/lib/tillandsias/guest-bin`) by the fstab line
the same function writes. The unit is NOT ordered after that mount.
`fetch-headless.sh` detects "not mounted yet" and warns, then falls back to the
network, which is the "working boot running the wrong headless" outcome its own
comment warns about. The pin kept the stale ordering green. This is filed as its
own row rather than folded into this survey.

## Recommendation (not a sweep)

1. Repair the ten above in the order given. Items 2, 3 and 9 each have a silent
   failure or a product consequence; the rest are churn.
2. Retire the three `scripts/build.sh` litmus steps and the 98 comment pins
   opportunistically, when their file is next touched.
3. Extend the existing new-pin guard (634-39ik, litmus-expression-pinning-enforcement)
   to Rust `include_str!` + `contains` in tests. That population (92) produced
   four of the ten, and no guard covers it.
4. Treat absence-of-one-spelling as a smell in review. A whole-file absence scan is
   legitimate; absence of one spelling is not.

## Appendix: reproducing the census

The inventory table came from a read-only scanner, run at the repo root as
`python3 census.py . > pins.tsv`. It is kept here rather than in scripts/, so
that it adds no Python dependency to the tree. Its heuristics:

- **populations and patterns:** as listed under the table.
- **polarity:** absence when the grep is under `!`, `-L`, or `-v` without `-c`,
  and for `!x.contains(`.
- **shape:** checked in this order:
  - comment: `ORDER nnn`, `@trace`, an order id, or 4+ plain words;
  - flag: a single `--flag`;
  - identifier: a single identifier or path::name;
  - expression: contains `( ) { } ; = $ [ ] -> :: && ||` or `fn` / `if` / `let` / `pub`;
  - other: everything else.
- **target_exists:** `os.path.exists` on the grepped file.

Repair ranking: `git log --since=45.days -i -E --grep='relay-fix|re-?pin|pin (moved|drift|broke)|stale pin|literal|source.window|representation|moved (the|a)|spelling' -p -U0`
over openspec/litmus-tests, scripts/test-*.sh and crates/**/*.rs. For each file it
counts commits that REMOVED a `grep`, `contains(` or `include_str` line.
