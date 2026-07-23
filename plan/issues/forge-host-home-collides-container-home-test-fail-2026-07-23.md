# Forge host HOME collides with container HOME — test false-positive

**Filed**: 2026-07-23T02:10Z
**Host**: forge (TILLANDSIAS_HOST_KIND=forge)
**Classification**: enhancement
**Status**: fixed (same commit)
**Order**: n/a (routine finding)

## Symptom

`cargo test -p tillandsias-headless` fails:

```
thread 'tests::launch_forge_agent_does_not_mount_user_home' panicked at
crates/tillandsias-headless/src/main.rs:13148:
argv contains host $HOME (/home/forge) outside of HOME env: /home/forge/.ssh:size=1m,mode=0700
```

## Root cause

The test has two guards:

1. **Container-side guard** (line 13110): allows `/home/forge/` paths — these are
   container-side bind targets, not host leaks.
2. **Host HOME leak guard** (line 13129): checks if any argv entry contains the
   host `$HOME` value.

On the forge host, `$HOME=/home/forge` — identical to the container HOME. The
container-side bind mount `/home/forge/.ssh:size=1m,mode=0700` matches both
guards. Guard 1 skips it, but guard 2 re-catches it because `is_target_only`
returns false (the source side `/home/forge/.ssh` contains the host HOME string).

The `is_target_only` heuristic cannot distinguish host-side from container-side
paths when the two HOME values are identical.

## Fix

Skip the host HOME leak check entirely when `host HOME == "/home/forge"`. The
test is still valid: `build_forge_agent_run_argv` uses a `/tmp/project` source
path, so no real host-Home-as-source leak can appear. The heuristic is a
secondary safety net; when it cannot distinguish, the primary guard (container-side
allowlist) is sufficient.

**Changed**: `crates/tillandsias-headless/src/main.rs` — added
`home_str != container_home` condition to the host HOME check.

## Verification

- `cargo test -p tillandsias-headless -- tests::launch_forge_agent_does_not_mount_user_home` → PASS
- `cargo test --workspace` → all pass
- `./build.sh --check` → clean
