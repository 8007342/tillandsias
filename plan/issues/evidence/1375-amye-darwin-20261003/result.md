# 1375-amye Darwin evidence — 2026-10-03

- Subject: `work/1375-amye` at `dac5f5c3e93ac258ed2a4287a98514072b076a7b`.
- Host: `aarch64-apple-darwin`; Rust `1.96.1 (31fca3adb 2026-06-26)`.
- Native build: PASS (`cargo-build-release-plan.raw.txt`).
- Native fixture: PASS (`native-fixture.raw.txt`), ending `ok:plan-run-verb:5`.
- Negative control: PASS as a control. In disposable branch
  `verification/1375-setpgid`, the sole mutation changed `libc::setsid()` to
  `libc::setpgid(0, 0)` in `crates/tillandsias-exec/src/lib.rs`. The fixture
  exited 1 at `FAIL: detached session equals caller session (45555)`.
  The exact mutation is retained in `setpgid-negative.diff`.
- Validation: `bash scripts/check-gate-step-regimes.sh` →
  `ok:gate-step-regimes:143`; `cargo fmt --check` → exit 0.

All raw output and individual exit-status files are retained alongside this
summary. No full `./build.sh --check` was run.
