## 1. Port Allocator Changes

- [x] 1.1 In `launch.rs`, change default range size from 100 to 20 ports
- [x] 1.2 Add `query_occupied_ports()` — run `podman ps --filter name=tillandsias- --format '{{.Ports}}'`, parse port mappings into `Vec<(u16, u16)>`
- [x] 1.3 Update `allocate_port_range()` to accept both in-memory and podman-queried ranges
- [x] 1.4 Update tests for 20-port ranges

## 2. Stale Container Cleanup

- [x] 2.1 Add `cleanup_stale_containers()` — list tillandsias containers via podman, compare against `state.running`, `podman rm -f` orphans
- [x] 2.2 Call cleanup before port allocation in `handle_attach_here()`

## 3. Handler Integration

- [x] 3.1 In `handlers.rs` `handle_attach_here()`, merge podman-queried ports with state ports before allocating
- [x] 3.2 In `handlers.rs` `handle_terminal()`, replace hardcoded `3100-3199` with allocator call
- [x] 3.3 In `runner.rs`, change default base range from `(3000, 3099)` to `(3000, 3019)`
- [x] 3.4 In config default, update port range from "3000-3099" to "3000-3019"

## 4. Verification

- [x] 4.1 `cargo check --workspace` passes
- [x] 4.2 `cargo test --workspace` passes (updated port range tests)
