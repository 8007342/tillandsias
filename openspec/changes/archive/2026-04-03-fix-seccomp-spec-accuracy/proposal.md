## Why

The podman-orchestration spec contains a misleading "Seccomp profile compatibility" scenario that documents *awareness* of a problem rather than a solution. It says "the application is aware that the default profile blocks approximately 130 syscalls" and "logs should indicate seccomp as a possible cause." This is a hack — a try-catch mentality instead of a proper fix. The pre_exec FD sanitization (FUSE FD cleanup) already eliminates the need for crun's `close_range()`, making the seccomp scenario factually inaccurate about the current architecture.

## What Changes

- Remove the misleading "Seccomp profile compatibility" scenario from the Security-hardened container defaults requirement
- Replace it with an accurate scenario documenting how pre_exec FD sanitization prevents the close_range/seccomp conflict
- Update the FUSE FD sanitization requirement to explicitly state it eliminates the close_range dependency
- Remove any "awareness" language — the spec should describe what the system *does*, not what it *knows about*

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `podman-orchestration`: Remove misleading seccomp awareness scenario from Security-hardened container defaults. Update FUSE FD sanitization requirement to document that it eliminates the close_range/seccomp conflict as a side effect.

## Impact

- `openspec/specs/podman-orchestration/spec.md` — spec text changes only
- No code changes required — the pre_exec FD sanitization already works correctly
- Knowledge cheatsheet `knowledge/cheatsheets/infra/oci-runtime-spec.md` may need a cross-reference update
