# Linux local-build e2e smoke 2026-07-24 — FINDINGS: gates 1-3 PASS on the merged v0.4 wave; gate 4 blocked on a structural provider-seed gap (order 477)

- Date: 2026-07-24 (UTC 06:29Z-08:20Z)
- Host: linux_mutable (operator machine), branch `linux-next`
- Commit tested: `25d7f26f` (final; run started at `ff0bb5f6` and absorbed the
  fix wave below), installed binary `Tillandsias v0.3.260724.3`
- Flow: /build-install-and-smoke-test-e2e — build+install -> full
  `podman system reset --force` -> cold `--init` -> forge lane
- Evidence: `target/build-install-smoke-e2e/20260724T062902Z/` (local)
- discovered_by: /build-install-and-smoke-test-e2e (linux)

## VERDICT: FINDINGS (deliberate non-PASS; one structural packet filed)

## Gate 1 — build + CI + install: PASS (after a five-iteration fix wave)

First run against the freshly merged osx+windows lanes failed 5/17 checks —
exactly the "did the other hosts break anything" signal this smoke exists
for. All root-caused (4-way parallel triage, adversarially verified) and
fixed in pushed commits `2c555097`, `cd002d5d`, `68c0df44`, `25d7f26f`:

1. rust-formatting: merged osx-lane hunks unformatted (operator had already
   fixed upstream in 23294697; absorbed by merge).
2. clippy all-features x2: `question_mark` in wsl.rs:79, `collapsible_if` x2
   in the tray zombie-reap probe (cfg-gated lane code, first all-features
   compile on this host).
3. tray-contract: (a) remote_projects' module-local TEST_LOCK split from the
   canonical `env_lock()` — PATH/TILLANDSIAS_PODMAN_BIN races corrupted two
   tests (order-434 class); unified. (b)
   `publish_local_service_starts_container_and_returns_url` failed because
   the DEPLOYED stack was mid order-463 DNAT drop (podman-healthy vault,
   127.0.0.1:8201 refused) — LIVE LINUX REPRO recorded on the 463 packet;
   test now `#[ignore]`-gated as e2e-class. (c) `is_held` probed with an
   EXCLUSIVE flock, so two concurrent scans read each other as holders
   (flaky `shared_stack_launch_marker_lifecycle_and_own_exclusion`); probe
   now SHARED.
4. REAL PRODUCT BUG: `--inference-tier` was missing from `is_cli_mode` and
   nested inside `--init` — probing the tier singleton-killed a running
   headless service. Fixed as a top-level one-shot lane, census-pinned.
5. container-base-policy + 7 stale litmus: multi-stage-aware base checker
   ratifying dcafd59c's vault:1.18 build stage; result-format echo
   sentinels (was scoring cargo SUCCESS as FAIL); inference grep windows
   30->60 (313 chown block); hermetic tier-probe/eligibility fixtures;
   ci-release shape now pins check-only ci.yml; provider-device-auth
   rustfmt-immune 4-variant pin; binary-e2e failure_pattern no longer trips
   on the dcafd59c WARNING text; cheatsheet host<->image bidirectional sync.
6. e2e-preflight hardening: an ERRORED `podman ps` now counts as
   live-runtime-PRESENT (leak-not-destroy) — the half-dead vault had fooled
   the probe into `eligible` for a destructive smoke.

Final state: 17/17 checks green; the three remaining post-build litmus reds
(diagnostics <24h, running-image freshness, FORGE_EXIT=125) were all
verified artifacts of the rotten pre-reset deployed stack (the freshness
gate correctly detecting stale images) — cured by gate 2 by design.

## Gate 2 — destructive reset: PASS

`podman system reset --force` exit 0; store verified empty (containers,
volumes, images); `teardown-straggler: clean (zombies=0 orphans=0)`.

## Gate 3 — cold re-provision: PASS

`tillandsias --init --debug` from the pristine store: exit 0, ZERO
panic/ERROR lines; all images rebuilt; vault up healthy with the full
12-policy set. Rebuilt-image live evidence for the v0.4 matrix. Residual
observed: the fresh vault still advertises `base_url:
https://127.0.0.1:8201` — the order-463 structural fix (enclave-URL
everywhere) remains ready/unclaimed.

## Gate 4 — forge lane: FAIL (structural, order 477 filed)

Forge launched clean; enclave `git://` mirror clone of the project SUCCEEDED
on the rebuilt image (positive 452/454-lineage evidence); opencode died:
`Error: No provider available`. Root cause: order-431 opencode vault auth
reads only `secret/gemini/api-key`, which has NO login lane
(GitHub/Claude/Codex/Antigravity only), was destroyed with the vault by the
reset, and is unrecoverable from host state. Every pristine-substrate smoke
fails this gate until a seed path exists. Packet:
`plan/issues/forge-opencode-provider-seed-missing-after-reset-2026-07-24.md`
(order 477) — interim operator reseed + durable provider-seed framework
generalizing order 468. Known cosmetic residual reproduced: forge OpenSpec
init WARNING (existing 2026-07-12 packet class, not re-filed).

## Next actions

- OPERATOR: re-seed `secret/gemini/api-key` (477 interim step), then re-run
  gate 4 to convert this record's forge leg to PASS.
- LINUX: claim order 463 (top Direction ping) — this run reproduced the
  class live on Linux mid-CI.
- The Windows/macOS order-455 smokes vs the newest daily remain the open
  v0.4 evidence gates (see loop_status Direction 2026-07-24T06:50Z).
