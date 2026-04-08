# Tasks: Fix Ghost Trace Annotations

## 1. Promote archived specs to openspec/specs/

- [x] 1.1 Copy `clickable-trace-index/spec.md` from archive `2026-03-30-clickable-trace-index`
- [x] 1.2 Copy `cross-platform/spec.md` from archive `2026-04-03-windows-full-support`
- [x] 1.3 Copy `logging-accountability/spec.md` from archive `2026-03-30-logging-accountability-framework`
- [x] 1.4 Copy `secret-rotation/spec.md` from archive `2026-03-30-secret-rotation-tokens`
- [x] 1.5 Copy `tray-icon-lifecycle/spec.md` from archive `2026-03-30-tray-icon-lifecycle`

## 2. Promote active change spec

- [x] 2.1 Copy `install-progress/spec.md` from active change `install-progress-i18n`

## 3. Copy concurrent spec

- [x] 3.1 Copy `secret-management/spec.md` (created by concurrent agent on linux-next)

## 4. Fix trace annotation errors in source code

- [x] 4.1 Fix `@trace spec:name` placeholder in `log_format.rs:259` to `@trace spec:logging-accountability`

## 5. Fix trace annotation errors in cheatsheets

- [x] 5.1 Fix `spec:podman-lifecycle` to `spec:podman-orchestration` in `docs/cheatsheets/wsl-bash.md` (2 occurrences)
- [x] 5.2 Fix `spec:podman-lifecycle` to `spec:podman-orchestration` in `docs/cheatsheets/windows-setup.md` (1 occurrence)
- [x] 5.3 Fix `spec:secrets-management` typo to `spec:secret-management` in `docs/cheatsheets/secret-management.md`

## 6. Verify

- [x] 6.1 Run `cargo test --workspace` — all 193 tests pass
- [x] 6.2 Verify zero ghost traces remain in source code (`.rs`, `.sh`, `.nix`, `.toml`)
- [x] 6.3 Remaining `spec:name`, `spec:foo`, `spec:forge-launch` are template/example text in CLAUDE.md and methodology docs — not real traces
