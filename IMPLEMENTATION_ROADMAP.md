# Litmus Framework Implementation Roadmap

## Quick Start: What to Build First

This roadmap breaks the litmus framework into phased deliverables. **Start with Layer 0 & 1, then add CI integration last.**

---

## Phase 1: Foundation (Week 1)

### 1.1 Create tillandsias-litmus Crate

```bash
cd crates/
cargo new tillandsias-litmus
```

**Cargo.toml:**
```toml
[package]
name = "tillandsias-litmus"
version = "0.1.0"
edition = "2021"

[dependencies]
tokio = { version = "1", features = ["full"] }
async-trait = "0.1"
serde = { version = "1", features = ["derive"] }
serde_json = "1"
tracing = "0.1"

[dev-dependencies]
tokio-test = "0.4"
```

### 1.2 Implement MockPodmanRuntime Trait

**File:** `crates/tillandsias-litmus/src/mock/podman.rs`

Copy pseudocode from `crates/tillandsias-litmus/src/mock/podman.rs.example` and implement:

1. `InMemoryPodmanMock` struct
2. `CallRecord` struct
3. `CallMatcher` enum with predicates
4. `MockPodmanRuntime` trait implementation

**Test:** Unit tests for exact call recording and matching

```bash
cargo test -p tillandsias-litmus --lib mock::tests
```

### 1.3 Implement LitmusSignal & LitmusTest Traits

**File:** `crates/tillandsias-litmus/src/signal/mod.rs`

Define:
- `LitmusSignal` trait with `preconditions_met()`, `execute()`, `spec_ids()`
- `SignalResult` enum: `Pass`, `Fail`, `Skip`
- `LitmusTest` trait with `child_signals()`, `execute_sequential()`
- `TestResult` enum

**File:** `crates/tillandsias-litmus/src/test/mod.rs`

Implement:
- `LitmusContext` struct (holds mock, environment)
- Sequential executor (run signals in order, halt on first failure)

```bash
cargo test -p tillandsias-litmus --lib signal::tests
cargo test -p tillandsias-litmus --lib test::tests
```

---

## Phase 2: First Tests (Week 2)

### 2.1 Implement 4 Atomic Signals

**File:** `crates/tillandsias-litmus/src/signal/examples.rs`

Each signal has:
- Preconditions check
- Mock podman call
- Assertion on exact args/flags
- Spec linkage

1. **CreateSecretSignal**
   - Precondition: mock has no prior secret
   - Execute: `podman secret create --driver=file <name>`
   - Assert: `--driver=file` flag present
   - Spec: `secrets-management`

2. **GitSecretMountSignal**
   - Precondition: secret exists
   - Execute: `podman run --secret tillandsias-github-token ...`
   - Assert: `--secret` flag with correct name
   - Spec: `secrets-management`, `credential-isolation`

3. **ImageExistsSignal**
   - Precondition: none
   - Execute: `podman image exists <image_name>`
   - Assert: exit code 0
   - Spec: `podman-orchestration`

4. **NetworkExistsSignal**
   - Precondition: none
   - Execute: `podman network exists tillandsias-enclave`
   - Assert: exit code 0
   - Spec: `enclave-network`

```bash
cargo test -p tillandsias-litmus --lib signal::examples::tests
```

### 2.2 Compose First Litmus Test

**File:** `crates/tillandsias-litmus/src/test/examples.rs`

Create `GitHubLoginTest` that combines:
1. `CreateSecretSignal`
2. `GitSecretMountSignal`
3. Simple auth signal
4. `CleanupSecretSignal`

```bash
cargo test -p tilmandsias-litmus --lib test::examples::tests
```

---

## Phase 3: Convergence Reporting (Week 3)

### 3.1 Implement ConvergenceObligation & CentiColon Scoring

**File:** `crates/tillandsias-litmus/src/convergence/mod.rs`

1. `ConvergenceObligation` struct:
   - `spec_id: String`
   - `obligation_budget_cc: u32`
   - `earned_cc: u32`
   - `penalties_cc: i32`

2. Scoring function: `compute_obligation(spec_id, signal_results) → ConvergenceObligation`
   - Look up obligation budget from spec registry
   - Apply earning rules per signal result
   - Apply penalties

3. Aggregation: `project_centicolon(all_obligations) → CentiColon`

**File:** `crates/tillandsias-litmus/src/convergence/centicolon.rs`

```rust
pub struct CentiColon {
    pub project_earned_cc: u32,
    pub project_total_cc: u32,
    pub per_spec_results: Vec<ConvergenceObligation>,
    pub top_residual_reasons: Vec<ResidualReason>,
}

impl CentiColon {
    pub fn residual(&self) -> u32 {
        self.project_total_cc.saturating_sub(self.project_earned_cc)
    }
}
```

```bash
cargo test -p tillandsias-litmus --lib convergence::tests
```

### 3.2 Implement JSONL Signature Writer

**File:** `crates/tillandsias-litmus/src/convergence/signature.rs`

```rust
pub fn write_signature(
    sig: &LitmusSignature,
    path: &Path,
) -> Result<()> {
    // Append-only: open in append mode
    // Write one JSON line per signature
    // Never truncate or delete
}
```

Each line:
```json
{
  "timestamp": "2026-05-05T14:23:45Z",
  "version": "0.1.42.103",
  "project_earned_cc": 2650,
  "project_total_cc": 2800,
  "residual_cc": 150,
  "per_spec_results": [...]
}
```

---

## Phase 4: CI Integration (Week 4)

### 4.1 Wire --ci-full Flag to Litmus Runner

**File:** `build.sh`

Add:
```bash
if [[ "$1" == "--ci-full" ]]; then
    cargo build --workspace
    cargo test --workspace
    
    # Run litmus tests
    cargo run -p tillandsias-litmus -- --run-all --ci-mode
    
    # Check critical-path status
    if [[ $? -ne 0 ]]; then
        echo "Critical-path litmus test failed, blocking release"
        exit 1
    fi
fi
```

### 4.2 Implement Parallel Test Runner

**File:** `crates/tillandsias-litmus/src/lib.rs`

```rust
pub async fn run_ci_full(
    config: CIConfig,
) -> Result<CentiColon> {
    // 1. Discover critical-path specs from openspec/litmus-bindings.yaml
    // 2. Group tests by domain
    // 3. Run groups in parallel (300s total budget)
    // 4. Flakiness check: 3 runs, all identical
    // 5. Gate: if critical-path test fails, exit(1)
    // 6. Persist signature
    // 7. Return CentiColon for reporting
}
```

### 4.3 Flakiness Detection

Each test:
1. Run 3 times
2. Collect results
3. If any differ: mark flaky, apply -80cc penalty
4. Report in CI output

### 4.4 Generate CI Artifacts

**target/convergence/centicolon-signature.jsonl** (append)
**target/convergence/centicolon-delta.json** (overwrite)

---

## Phase 5: Documentation & Release (Week 5)

### 5.1 Update Catalog

**File:** `methodology/catalog.yaml`

Add entry:
```yaml
litmus_framework:
  file: methodology/litmus-framework.yaml
  provides: "Rust litmus test framework with mock podman and CentiColon wiring"
```

### 5.2 Create Cheatsheet (Optional)

**File:** `cheatsheets/test/litmus-quick-reference.md`

Quick reference for:
- How to write a signal
- How to compose tests
- How to debug failures
- Scoring rules

### 5.3 Integration Tests

**File:** `crates/tillandsias-litmus/tests/integration_test.rs`

Full end-to-end test:
1. Create mock
2. Run GitHubLoginTest
3. Assert CentiColon computation
4. Verify signature written

### 5.4 Release Evidence Bundle

When ready to release:
```bash
./build.sh --ci-full
# Generates:
# - target/convergence/centicolon-signature.jsonl (appended)
# - target/convergence/centicolon-delta.json (new)
# - GitHub release artifact link
```

---

## File Checklist

**Already Exist:**
- [x] `methodology/litmus.yaml` — Structure and binding rules
- [x] `methodology/convergence.yaml` — Engine metrics
- [x] `methodology/proximity.yaml` — CentiColon model
- [x] `openspec/litmus-bindings.yaml` — Active spec registry

**Must Create (This Roadmap):**
- [x] `methodology/litmus-framework.yaml` — Full framework design
- [x] `methodology/litmus-centicolon-wiring.yaml` — Scoring rules lookup table
- [x] `crates/tillandsias-litmus/README.md` — Getting started
- [x] `crates/tillandsias-litmus/src/mock/podman.rs.example` — Pseudocode
- [ ] `crates/tillandsias-litmus/Cargo.toml` — (Phase 1.1)
- [ ] `crates/tillandsias-litmus/src/lib.rs` — (Phase 1.2–1.3)
- [ ] `crates/tillandsias-litmus/src/mock/podman.rs` — (Phase 1.2)
- [ ] `crates/tillandsias-litmus/src/signal/mod.rs` — (Phase 1.3)
- [ ] `crates/tillandsias-litmus/src/test/mod.rs` — (Phase 1.3)
- [ ] `crates/tillandsias-litmus/src/signal/examples.rs` — (Phase 2.1)
- [ ] `crates/tillandsias-litmus/src/test/examples.rs` — (Phase 2.2)
- [ ] `crates/tillandsias-litmus/src/convergence/mod.rs` — (Phase 3.1)
- [ ] `crates/tillandsias-litmus/src/convergence/centicolon.rs` — (Phase 3.1)
- [ ] `crates/tillandsias-litmus/src/convergence/signature.rs` — (Phase 3.2)
- [ ] `crates/tillandsias-litmus/tests/integration_test.rs` — (Phase 5.3)

---

## Testing at Each Phase

### Phase 1
```bash
cargo test -p tillandsias-litmus --lib
# Expect: All mock, signal, test trait tests pass
```

### Phase 2
```bash
cargo test -p tillandsias-litmus
# Expect: 4 signals + GitHubLoginTest composite test passes
# Mock reports exact podman calls, signals verify them
```

### Phase 3
```bash
cargo test -p tillandsias-litmus --lib convergence
# Expect: CentiColon scoring matches obligation model
# Signature JSONL written correctly
```

### Phase 4
```bash
./build.sh --ci-full
# Expect: All critical-path tests pass (if code is correct)
# CI artifacts generated in target/convergence/
```

### Phase 5
```bash
cargo test --workspace
# Expect: Full integration test passes
# No regressions in existing tests
```

---

## Key Invariants to Maintain

**1. Mock Purity**
- MockPodmanRuntime NEVER touches actual podman
- All I/O is in-memory
- Deterministic (same inputs → same results)

**2. Spec Linkage**
- Every signal has `spec_ids()` returning active spec IDs
- Every failure emits spec trace
- Orphaned specs detected by CI validator

**3. CentiColon Monotonicity**
- Earned credits never exceed obligation budget
- Residual never negative
- Penalties always reduce earned score

**4. Evidence Immutability**
- Signature JSONL is append-only, never truncated
- Each entry is one JSON line
- Timestamp + version ensure ordering

**5. CI Gating**
- Critical-path test failure → exit(1), block release
- Flaky tests → -80cc penalty, alert developer
- All tests must complete in 300s

---

## Convergence Properties

Once this framework is in place:

1. **Spec-Code Alignment:** Litmus tests verify code matches spec intent
2. **Falsifiable:** Tests can only pass if podman calls are correct
3. **Observable:** CentiColons show residual obligations clearly
4. **Composable:** Small tests combine into large ones without interference
5. **Deterministic:** Mock ensures zero flakiness or timing issues
6. **Costable:** CI budget enforced (300s total, 30s per test)

---

## Success Criteria

Release is ready when:

- [ ] All 4 atomic signals have passing tests
- [ ] GitHubLoginTest (composite) passes
- [ ] CentiColon scoring matches obligation model
- [ ] Signature JSONL writes correctly
- [ ] --ci-full flag integrates with build.sh
- [ ] Flakiness detection works (3 runs, all identical)
- [ ] Critical-path test gating blocks on failure
- [ ] Evidence bundle generated for release
- [ ] Zero CI test regressions
- [ ] Documentation complete (README + cheatsheet)
