# 1519-6rcp Darwin evidence — 2026-10-08 (re-measured on the linux-next merge)

- Subject: work/1519-6rcp merged with origin/linux-next (see environment.txt); the plan binary was built from THIS tree. The 2026-10-03 receipt used a binary from a different checkout (~/opencode).
- Host: tlatoanis-macbook-air, macOS 27.0.1 arm64, rustc 1.96.1.
- Native fixture: TILLANDSIAS_PLAN_BIN=target/release/tillandsias-plan bash scripts/test-script-run-verb.sh gives "script-run-verb: 7 passed, 0 failed" (native-fixture.raw.txt).
- Negative control: the ONLY mutation is the no-verdict arm's exit code in crates/tillandsias-plan/src/script_run.rs, 1 -> 0 (no-verdict-exit0-negative.diff, two changed lines, confirmed applied). Rebuilt; the fixture exited 1 with "FAIL: ARM 3: rc=0 out='refused:no-verdict:silent'" (6 passed, 1 failed). Reverted (git diff clean), rebuilt, and the fixture went green 7/7 again before the regime line was recorded.
