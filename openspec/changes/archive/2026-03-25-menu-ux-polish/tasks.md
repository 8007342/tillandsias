## 1. Attach Here Lifecycle States

- [ ] 1.1 Idle state: show `🌱 Attach Here` (seedling prefix) when `assigned_genus` is None
- [ ] 1.2 Running state: show `🌺 Blooming` (genus flower + "Blooming") when `assigned_genus` is Some, with `enabled(false)`
- [ ] 1.3 Container exit: reverts to idle automatically via `assigned_genus = None` (no code change needed)

## 2. Maintenance Icon

- [ ] 2.1 Replace wrench `🔧` (U+1F527) with pick `⛏️` (U+26CF) in idle Maintenance label
- [ ] 2.2 Replace wrench `🔧` in build chip label for Maintenance in-progress state

## 3. Remove Per-Project Container Listing

- [ ] 3.1 Remove separator before per-project containers (line 451)
- [ ] 3.2 Remove entire per-project container loop (lines 443-464)

## 4. Project Label Emoji

- [ ] 4.1 When attach container running: prefix project name with genus flower (e.g., `🌺 my-project`)
- [ ] 4.2 When only maintenance running: prefix with pick (e.g., `⛏️ my-project`)
- [ ] 4.3 When both running: prefix with both (e.g., `🌺⛏️ my-project`)
- [ ] 4.4 When nothing running: prefix with seedling (e.g., `🌱 my-project`)
- [ ] 4.5 Remove parenthesized counter from project label

## 5. Verification

- [ ] 5.1 `cargo check --workspace` passes
- [ ] 5.2 `cargo test --workspace` passes
