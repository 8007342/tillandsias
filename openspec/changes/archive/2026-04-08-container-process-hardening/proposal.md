# Container Process Hardening

## Problem

Security audit found that containers lack process limits and per-container process restrictions. All containers share default seccomp but have no `--pids-limit` (fork bomb risk) and no filesystem immutability enforcement for service containers.

## Solution

1. Add `--pids-limit` per container type, calibrated to each container's intended workload
2. Add `--read-only` root filesystem for service containers (git, proxy, inference, web) with explicit tmpfs for runtime dirs
3. Add `@trace spec:secret-management` accountability logging at container launch points for credential isolation boundaries
4. Update the secret-management spec with process isolation requirements

## Scope

- `crates/tillandsias-core/src/container_profile.rs` — add `pids_limit`, `read_only`, `tmpfs_mounts` fields
- `src-tauri/src/launch.rs` — emit `--pids-limit`, `--read-only`, `--tmpfs` flags
- `src-tauri/src/handlers.rs` — enhanced accountability logging with isolation traces
- `openspec/specs/secret-management/spec.md` — process isolation requirements
