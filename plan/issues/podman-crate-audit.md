# podman-crate-audit — tillandsias-podman vs podman-idiomatic-patterns spec

Date: 2026-05-14
Spec: openspec/specs/podman-idiomatic-patterns/spec.md

## Conformance Summary

4/7 requirements fully conforming, 3 with gaps.

## Conforming Requirements

- **Req 1 (Event streaming)**: `events.rs` subscribes to `podman events --format json`; exponential backoff fallback only triggers when stream dies, as intended.
- **Req 2 (Security flags)**: `ContainerSpec::new()` defaults `remove=true`, `init=true`, `userns_keep_id=true`, `cap_drop_all=true`, `no_new_privileges=true` — non-negotiable at construction time. Test `default_spec_includes_immutable_hardening_flags` covers all four mandatory flags.
- **Req 6 (Rootless-first)**: `--userns=keep-id` is always-on default; no root ops in crate. Startup `podman info` rootless check is in headless crate (acceptable — crate-level is correct).
- **Req 2 partial note**: `backoff_inspect` uses `podman ps` as fallback when event stream unavailable — this is the intended recovery path, not a prohibited polling loop.

## Gaps (non-trivial — file only, do not implement now)

- **GAP-1 (Req 3 — per-project storage isolation)**: `podman_graphroot()` / `podman_runroot()` return a single shared path (`~/.local/share/tillandsias/podman`), not per-project paths. Spec requires `~/.cache/tillandsias/<project>/graphroot/`. `configure_podman_environment()` does not accept a project name parameter. All projects currently share one Podman graph root, violating the no-cross-project-storage invariant.

- **GAP-2 (Req 4 — ephemeral secrets in crate)**: `PodmanClient` and `ContainerSpec` have no `secret()` builder method. Secret support lives only in headless scripts (`scripts/create-secrets.sh`), not in the typed Rust API. Any caller that bypasses the scripts can inadvertently pass credentials via `-e`. A `secret(name)` method on `ContainerSpec` + `podman secret create/rm` on `PodmanClient` is needed to make ephemeral secrets a first-class typed concern.

- **GAP-3 (Req 5 — error retry discrimination)**: `PodmanError` enum has three variants (`CommandFailed`, `NotFound`, `ParseError`) with no transient/permanent classification. No retry logic exists in the crate. Spec requires: transient errors (network unreachable, timeout) → exponential backoff retry; permanent errors (image not found, bad flags, exit 125, permission denied) → immediate propagation. Needs `PodmanError::is_transient()` predicate and a retry helper.

- **GAP-4 (Req 7 — per-project enclave network)**: `ENCLAVE_NETWORK` is a single constant `"tillandsias-enclave"`. Spec requires `tillandsias-<project>-enclave`. The `create_internal_network` / `remove_network` methods accept an arbitrary name, so callers CAN use per-project names — but the exported constant encourages wrong usage. The constant should be replaced with a `fn enclave_network_name(project: &str) -> String` helper.

## Quick-fix applied inline

None — all gaps require design decisions beyond trace annotation scope.
