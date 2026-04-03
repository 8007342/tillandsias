## Context

The podman-orchestration spec has a "Seccomp profile compatibility" scenario under "Security-hardened container defaults" that says the application should be "aware" of seccomp blocking `close_range()` and log it as a "possible cause." This is a textbook hack workaround — documenting awareness of a failure mode instead of fixing it.

The reality: the pre_exec FD sanitization (added by fix-appimage-fuse-fd-leak) already closes all FDs >= 3 before exec'ing podman. This means crun receives a clean FD table and never needs to call `close_range()`. The seccomp/close_range conflict is architecturally eliminated, not worked around.

## Goals / Non-Goals

**Goals:**
- Remove the misleading "Seccomp profile compatibility" scenario entirely
- Update the FUSE FD sanitization requirement to document that it eliminates the close_range/seccomp conflict as a side effect
- Ensure the spec describes what the system *does*, not what it *knows about*

**Non-Goals:**
- No code changes — the implementation is already correct
- Not adding custom seccomp profiles — unnecessary since FDs are pre-closed
- Not changing any other spec requirements

## Decisions

**Decision: Remove the seccomp scenario entirely rather than rewriting it.**
Rationale: The scenario describes a problem that no longer exists. Rewriting it to say "this used to be a problem" adds noise. The FUSE FD sanitization requirement already covers the fix. The OCI runtime cheatsheet (`knowledge/cheatsheets/infra/oci-runtime-spec.md`) documents the crun close_range/fallback behavior for reference — that's where implementation details belong, not in the spec.

**Decision: Add a scenario to FUSE FD sanitization documenting the close_range elimination.**
Rationale: The fact that pre-closing FDs eliminates the close_range dependency is a valuable architectural property. It belongs as a scenario on the requirement that provides it.

## Risks / Trade-offs

- [Risk] Someone may wonder why there's no seccomp handling → The FUSE FD sanitization requirement explains the defense-in-depth approach. The OCI runtime cheatsheet documents the underlying crun behavior for anyone who needs deeper context.
