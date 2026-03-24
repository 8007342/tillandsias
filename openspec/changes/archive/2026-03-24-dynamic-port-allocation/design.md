## Context

The port allocator in `launch.rs` takes a base range and a list of existing ranges from `state.running`, then shifts upward to avoid conflicts. But `state.running` only reflects containers the app knows about — orphaned containers (from killed terminals) aren't tracked. The allocator needs to query podman directly.

## Goals / Non-Goals

**Goals:**
- Shrink ranges from 100 to 20 ports
- Check real podman port usage before allocating
- Clean up stale tillandsias containers that block ports
- Use the allocator for terminal containers too (currently hardcoded)

**Non-Goals:**
- Persisting port assignments across app restarts (ephemeral is fine)
- Checking non-tillandsias container port usage (they use different ranges)

## Decisions

### Decision 1: Query podman for occupied ports

**Choice**: Before allocating, run `podman ps --filter name=tillandsias- --format '{{.Ports}}'` to get actual port mappings. Parse the output and feed it into the allocator.

**Rationale**: This catches orphaned containers that aren't in `state.running`. The podman query is fast (<50ms) and happens at container creation time (not on every menu rebuild).

### Decision 2: Stale container cleanup

**Choice**: Before allocating ports, check for tillandsias containers not in `state.running`. If found, attempt `podman rm -f` on them. This is safe because tillandsias containers are always `--rm` (ephemeral).

### Decision 3: 20-port ranges

**Choice**: Base range `3000-3019`. Each additional environment gets the next 20-port window (3020-3039, 3040-3059, etc.). This allows ~50 concurrent environments before hitting port 4000.

**Rationale**: OpenCode needs port 3000 (web UI). A few extra ports handle LSP, debug adapters, etc. 20 is generous for a single environment.
