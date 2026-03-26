## 1. Filter startup discovery to running containers only

- [x] 1.1 In `main.rs` startup discovery block, skip containers with `ContainerState::Stopped` (only push `Running` and `Creating` entries into `state.running`)

## 2. Seed GenusAllocator from pre-populated state

- [x] 2.1 Add `seed_from_running()` method to `GenusAllocator` in `genus.rs` that marks a set of `(project_name, genus)` pairs as allocated
- [x] 2.2 In `event_loop::run()`, call `allocator.seed_from_running(&state.running)` immediately after `GenusAllocator::new()`

## 3. Verify

- [x] 3.1 Run `cargo check --workspace` — zero errors
