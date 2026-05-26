# osx-next adaptive-loop noop streak

Per `plan/issues/osx-next-work-queue-2026-05-25.md` adaptive-cadence rules.
This file accumulates while there is no unblocked productive work; reset to
streak=0 (delete file) on any productive iter.

Cadence: streak 1 → 1h | 2 → 2h | 3 → 4h | 4+ → 6h (cap).

## Streak

- **streak 1** — 2026-05-26T22:30Z (iter 35)
  - reason: macOS code complete for v0.0.1 (see plan/steps/20 "Current state"
    section as of iter 34). True remaining blockers are Linux-owned:
    `aarch64.img` SHA pin in `images/vm/manifest.toml` (still `"pending-ci"`)
    + `tillandsias-headless-{x86_64,aarch64}-unknown-linux-musl` release asset
    publish (not on `v0.2.260526.1`). No new commits on linux-next since
    `4c4fa19a`/`512db9f2`; no new CI runs; no new release assets.
  - next wake: 1h (3600s).
