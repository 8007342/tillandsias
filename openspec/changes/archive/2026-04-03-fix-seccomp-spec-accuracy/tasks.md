## 1. Update main spec

- [x] 1.1 Remove "Seccomp profile compatibility" scenario from Security-hardened container defaults requirement in `openspec/specs/podman-orchestration/spec.md`
- [x] 1.2 Add "Seccomp close_range elimination" scenario to FUSE FD sanitization requirement in `openspec/specs/podman-orchestration/spec.md`

## 2. Verify code accuracy

- [x] 2.1 Confirm pre_exec FD sanitization in `crates/tillandsias-podman/src/lib.rs` closes FDs >= 3 (matching spec)
- [x] 2.2 Confirm no seccomp "awareness" logging exists in the codebase that should also be removed

## 3. Build verification

- [x] 3.1 Run `cargo check --workspace` to confirm no compilation impact
