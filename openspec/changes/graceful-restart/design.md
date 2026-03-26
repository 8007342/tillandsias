## Context

The `TrayState::running` field is populated exclusively by podman events during normal operation. On a fresh app start those events never arrive for already-running containers, so the field stays empty and the menu shows no active environments.

The container naming convention `tillandsias-<project>-<genus>` was deliberately designed to encode all identity information needed to reconstruct state. `ContainerInfo::parse_container_name()` already implements the reverse mapping. The only missing piece was calling `podman ps` at startup and driving that parse path.

## Goals / Non-Goals

**Goals:**
- Restore the correct menu state for running containers within the first startup menu rebuild
- Seed the `GenusAllocator` so subsequent allocations do not duplicate already-taken genera
- Ignore containers in states other than `running` or `created`/`configured` (stopped/exited containers are not "running" and should not appear)

**Non-Goals:**
- Restoring port_range — unavailable from `podman ps` output without an extra inspect; defaulting to `(0, 0)` is acceptable since port allocation is only needed at launch time
- Recovering terminal containers (`tillandsias-<project>-terminal`) — `parse_container_name` returns `None` for these since `"terminal"` is not a genus slug; the terminal container lifecycle is tracked separately in the menu via name matching only
- Persistent storage for container state — the container name IS the persistence mechanism

## Decisions

### Decision 1: Filter to running/creating states only

**Choice**: In `main.rs`, map podman `State` strings and only push entries with `ContainerState::Running` or `ContainerState::Creating` into `state.running`. Skip `Stopped`, `Absent`, and any unknown states.

**Rationale**: `list_containers` uses `podman ps -a` (all containers) to get accurate state data. Without filtering, stopped containers from a previous session would appear as "Blooming" in the menu, which is incorrect and confusing.

**Alternative rejected**: Using `podman ps` (without `-a`) would exclude stopped containers at the query level, but it would also exclude `created`/`configured` containers that are mid-launch. Explicit state filtering in Rust code is clearer.

### Decision 2: Seed GenusAllocator in event_loop::run()

**Choice**: Before entering the main `tokio::select!` loop, iterate over `state.running` and call `allocator.allocate_specific()` — or equivalently, manually register each genus as in-use.

**Rationale**: The `GenusAllocator` is created inside `event_loop::run()` and is invisible to the startup discovery code in `main.rs`. The cleanest seeding point is the start of `run()` after `let mut allocator = GenusAllocator::new()`.

**Implementation**: Add a `seed_from_running()` method to `GenusAllocator` (or inline the seeding), iterating `state.running` and marking each `(project_name, genus)` pair as allocated. This prevents double-allocation when "Attach Here" is invoked for a project that already has a container.

### Decision 3: Rebuild menu before entering event loop

**Choice**: After populating `state.running` from discovery, call `rebuild_menu()` so the restored state is visible immediately rather than waiting for the first scanner/podman event.

**Rationale**: The scanner's `initial_scan()` already triggers a `rebuild_menu()` call. Container discovery runs before the scanner scan, so the menu is rebuilt once with both projects and running containers together. No extra rebuild is needed — the existing post-scan rebuild covers it.

## Risks / Trade-offs

- **[TOCTOU]** — A container could stop between `podman ps` and menu build. The podman event stream will correct this within milliseconds; the brief wrong state is acceptable.
- **[GenusAllocator divergence]** — Without seeding, `Attach Here` on a project that already has a container running could allocate a duplicate genus. After this change, the allocator correctly tracks discovered containers.
