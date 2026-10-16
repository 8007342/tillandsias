# 1375-amye Darwin evidence — 2026-10-08 (re-measured after merging linux-next)

- Subject: `work/1375-amye` at `75a0df1ace88f41a32ed41de87afa3a1928f04a4`
  (merge of `origin/linux-next` `e60506d2f`).
- Host: tlatoanis-macbook-air, macOS 27.0.1, arm64; Rust `1.96.1`.
- Native build: PASS (`cargo-build-release-plan.raw.txt`).
- Native fixture: PASS (`native-fixture.raw.txt`), ending `ok:plan-run-verb:5`.
  The session check reads `getsid` from the plan binary itself
  (`tillandsias-plan run --session-id`), not from host ps/setsid tools.
- Negative control: PASS as a control. The only mutation was
  `libc::setsid()` → `libc::setpgid(0, 0)` in `crates/tillandsias-exec/src/lib.rs`.
  It was confirmed applied (grep count 1 → 1, diff in `setpgid-negative.diff`), then
  rebuilt. The fixture exited 1 at `FAIL: detached session equals caller session (7291)`.
  The mutation was reverted, the binary rebuilt, and the fixture re-ran green before
  the regime line was recorded.
- Validation: `bash scripts/check-gate-step-regimes.sh` → `ok:gate-step-regimes:153`;
  `cargo fmt --check` → exit 0.
