# exploration: ZeroClaw (formerly NanoClawV2) Progress

- class: exploration
- filed: 2026-06-23
- owner: linux
- status: completed
- closed: 2026-06-23T20:55Z
- closed_by: linux-big-pickle-20260623T2042Z

## Context
We moved NanoClawV2 packets to ZeroClaw, but progress has stalled in that direction.

## Problem
There is a lack of visible progress on the ZeroClaw migration/implementation. 

## Goals
1. Audit the existing `plan/index.yaml` for ZeroClaw / NanoClawV2 tasks.
2. Identify blockers that are preventing progress.
3. Break down the remaining ZeroClaw work into smaller, executable packets for the meta-orchestration loop to pick up.

## Audit Findings

### NanoClawV2 Current State
The NanoClawV2 implementation is **fully built but the ZeroClaw migration was never done**.

| Component | Status |
|-----------|--------|
| `crates/tillandsias-nanoclawv2-mcp/` | LIVE — fully functional crate with 12 tests |
| `images/nanoclawv2/` (Containerfile, entrypoint, config overlay) | LIVE — image builds and deploys |
| `launch_nanoclawv2()` in tray/mod.rs | LIVE — tray launcher wired and working |
| `LeafAction::NanoClawV2` in tray/mod.rs | LIVE — menu item present |
| `nanoclawv2` image registration in main.rs | LIVE — image_specs + build_inputs |
| `litmus:nanoclawv2-mcp-shape` | LIVE — litmus test bound |
| `openspec/changes/nanoclawv2-orchestration/` | LIVE — proposal, design, tasks, spec |

### ZeroClaw Current State
ZeroClaw implementation files **do not exist on disk**:

| File | Exists? |
|------|---------|
| `crates/tillandsias-headless/src/zeroclaw.rs` | **NO** |
| `images/zeroclaw/Containerfile` | **NO** |
| `images/zeroclaw/` | **NO** |
| `scripts/build-zeroclaw.sh` | **NO** |

### Plan Status Inconsistency
- `order: 56` (`nanoclawv2-orchestration`) has `status: superseded_migrating_to_zeroclaw`
- `nanoclawv2/implementation` task is marked `completed` with `next_action: "HALT NanoClaw work. Migrate all existing NanoClawV2 implementation files to ZeroClaw."`
- But the migration files were **never created** — the task closure was premature.
- Order 90 (`zeroclaw-progress`) exists as a meta-task to break down the work.

### Key Blockers
1. **No ZeroClaw binary crate**: NanoClawV2 MCP is written in Rust but lives under the old name. Needs a `crates/tillandsias-zeroclaw/` crate.
2. **No ZeroClaw Containerfile**: `images/zeroclaw/Containerfile` must use `fedora:44` base and compile the ZeroClaw Rust binary (the migration spec).
3. **NanoClaw files still live**: Cannot delete them until ZeroClaw replacement is ready.
4. **Tray and image wiring references `nanoclawv2`**: Every `nanoclawv2` string in main.rs, tray/mod.rs, runtime_assets.rs must be updated.
5. **Litmus tests reference `nanoclawv2`**: `litmus:nanoclawv2-mcp-shape` and related tests must be renamed/updated.
6. **Plan status inconsistency**: Order 56 is `superseded_migrating_to_zeroclaw` but has no successor.

## Broken-Down Work Packets

### Packet A: Create ZeroClaw crate (rust crate scaffold)
- **File**: `crates/tillandsias-zeroclaw/Cargo.toml` + `src/main.rs`
- **Action**: Create new crate from NanoClawV2 MCP template. Port all existing MCP broker code (allowlist, Unix socket server, project-scope enforcement). Use `fedora:44` compatible Rust toolchain.
- **Estimated**: 2h
- **Dependencies**: None

### Packet B: Create ZeroClaw Containerfile and image
- **File**: `images/zeroclaw/Containerfile`, `images/zeroclaw/entrypoint.sh`
- **Action**: Write Containerfile based on `fedora:44` that compiles the ZeroClaw Rust binary. Port the config overlay, MCP bridge, and discipline docs from `images/nanoclawv2/`.
- **Estimated**: 1h
- **Dependencies**: Packet A (binary must exist to test the Containerfile)

### Packet C: Update tray launcher — rename NanoClawV2 → ZeroClaw
- **File**: `crates/tillandsias-headless/src/tray/mod.rs`
- **Action**: Rename `LeafAction::NanoClawV2` → `LeafAction::ZeroClaw`, `launch_nanoclawv2()` → `launch_zeroclaw()`. Update socket paths and container names from `nanoclaw` to `zeroclaw`.
- **Estimated**: 1h
- **Dependencies**: Packet B

### Packet D: Update image registration — rename NanoClawV2 → ZeroClaw
- **Files**: `crates/tillandsias-headless/src/main.rs`, `src/runtime_assets.rs`
- **Action**: Replace all `nanoclawv2` string references with `zeroclaw` in image_specs, image_build_inputs, build order, optional-image list, and test assertions.
- **Estimated**: 1h
- **Dependencies**: Packet C

### Packet E: Update litmus tests — rename NanoClawV2 → ZeroClaw
- **Files**: `openspec/litmus-tests/litmus-nanoclawv2-mcp-shape.yaml`, `openspec/litmus-bindings.yaml`, `openspec/litmus-tests/litmus-simplified-tray-ux-leaf-action-shape.yaml`
- **Action**: Rename `litmus:nanoclawv2-mcp-shape` → `litmus:zeroclaw-mcp-shape`. Update all NanoClawV2 references in litmus tests. Update spec binding.
- **Estimated**: 1h
- **Dependencies**: Packet D

### Packet F: Remove NanoClawV2 legacy files
- **Files**: `crates/tillandsias-nanoclawv2-mcp/`, `images/nanoclawv2/`
- **Action**: Delete or archive the NanoClawV2 crate and image directories. Update `Cargo.toml` workspace members.
- **Estimated**: 0.5h
- **Dependencies**: Packet E (only after all references are updated)

### Packet G: Update plan ledger — close order 56, create order 91 ZeroClaw
- **Files**: `plan/index.yaml`
- **Action**: Mark `nanoclawv2-orchestration` (order 56) as completed. Create new order 91 `zeroclaw-orchestration` with the new packets as tasks.
- **Estimated**: 0.5h
- **Dependencies**: Packets A-F (or iterative; mark as work-in-progress)

## Recommended Execution Order
```
Packet A → Packet B → Packet C → Packet D → Packet E → Packet F → Packet G
(sequential dependency chain, cannot parallelize)
```

Total estimated effort: ~6-7h across 7 packets of ≤2h each.

## Priority Note
NanoClawV2/ZeroClaw is a downstream feature with no active user-facing blocking issues. The existing NanoClawV2 implementation works correctly. This work should be prioritized as "low urgency, migrate when convenient" unless ZeroClaw-specific features (fedora:44 base, pure Rust, Apache 2.0 license) are required to unblock other work.
