# Litmus Test Framework Design Summary

## Overview

A **Rust-based litmus test framework** that verifies Tillandsias code produces correct podman calls, with CentiColon-tracked residual obligations feeding into convergence metrics. Bridges the gap between specs (intent) and code (implementation) through falsifiable, composable tests.

**Key insight:** Litmus tests are not just unit tests—they are the _mechanism_ by which the convergence engine validates spec compliance and computes CentiColon residual work.

---

## Core Architecture (4 Layers)

### Layer 0: Mock Podman Abstraction
**File:** `crates/tillandsias-litmus/src/mock/podman.rs`

Intercepts `podman` subprocess calls without requiring actual podman. Records exact arguments, environment, stdout/stderr. Tests inject preconfigured responses to simulate errors.

**Trait:**
```rust
pub trait MockPodmanRuntime {
    fn exec(&mut self, cmd: &str, args: &[&str], env: &[(&str, &str)]) -> Result<ProcessOutput>;
    fn calls_matching(&self, predicate: CallMatcher) -> Vec<&CallRecord>;
    fn inject_response(&mut self, predicate: CallMatcher, response: ProcessOutput);
    fn reset(&mut self);
    fn stats(&self) -> MockStats;
}
```

**Why:** Enables testing without container pollution, guarantees determinism, captures exact podman behavior.

---

### Layer 1: Atomic Litmus Signals
**File:** `crates/tillandsias-litmus/src/signal/mod.rs`

Validates a **single** semantic requirement from a spec. Success/failure are unambiguous. Smallest independently runnable unit.

**Trait:**
```rust
#[async_trait]
pub trait LitmusSignal {
    async fn preconditions_met(&self, runtime: &MockPodmanRuntime) -> Result<()>;
    async fn execute(&mut self, ctx: &mut LitmusContext) -> SignalResult;
    fn spec_ids(&self) -> Vec<&str>;
    fn timeout_millis(&self) -> u32;
}
```

**Example: CreateGitHubSecretSignal**
- **Spec:** `spec:secrets-management` — "Credentials are read from ephemeral podman secrets"
- **Precondition:** podman is available
- **Execute:** Call handler, assert exact podman call: `podman secret create --driver=file tillandsias-github-token`
- **Result:** Pass with `[+80cc earned]` OR Fail with `@trace spec:secrets-management`
- **Timeout:** 5 seconds

**Minimality principle:** Each signal answers exactly one question. Multiple signals compose into tests.

---

### Layer 2: Composite Litmus Tests
**File:** `crates/tillandsias-litmus/src/test/mod.rs`

Combines atomic signals into a coherent feature test. Executes sequentially; child signal failure immediately fails parent. Forms a DAG (directed acyclic graph) with topological ordering.

**Example: GitHubLoginTest**
```
GitHubLoginTest
├── CreateGitHubSecretSignal → Assert `podman secret create --driver=file`
├── GitSecretMountSignal     → Assert `podman run --secret tillandsias-github-token`
├── GitAuthenticateSignal    → Assert git command succeeds
└── CleanupSecretSignal      → Assert `podman secret rm`
```

**Execution:**
1. Run signal 1 → Pass
2. If failed, stop here with spec trace
3. Else run signal 2, etc.

**All must complete within test timeout (30s default).**

---

### Layer 3: Convergence Reporting
**File:** `crates/tillandsias-litmus/src/convergence/centicolon.rs`

Transform test results into CentiColon metrics and evidence artifacts.

**Data flow:**
```
SignalResult (Pass/Fail/Skip)
  → LitmusBinding (signal → spec mapping)
  → ConvergenceObligation (budget/earned/penalty)
  → CentiColon (earned_cc, residual_cc, top_reasons)
  → LitmusSignature JSONL (immutable, append-only)
```

---

## CentiColon Obligation Model

Each spec receives a **weighted obligation budget** based on its requirements and multipliers:

```
obligation_budget = sum(
    100 cc × MUST requirements,
    100 cc × MUST_NOT requirements,
    40 cc × SHOULD requirements,
    120 cc × invariants
) × multiplier_critical_path
  × multiplier_security_boundary
```

**Example: spec:secrets-management**
```
100 cc (MUST: ephemeral secrets)
+ 100 cc (MUST_NOT: no disk write)
+ 40 cc (SHOULD: rotate tokens)
× 1.5 (security boundary)
= 270 cc total obligation
```

### Earning Rules
Per-signal credit when **litmus test passes**:
- `+0.20` for positive test (happy path)
- `+0.20` for negative test (error path)
- `+0.15` for runtime trace signal
- `-0.10` if temporal stability < 95% (flakiness penalty)

**Example:**
- CreateGitHubSecretSignal passes → `+80 cc` (0.20 × 270)
- GitSecretMountSignal passes → `+80 cc`
- GitAuthenticateSignal **fails** → `+0 cc` earned, `-70 cc` penalty (untested MUST)
- CleanupSecretSignal passes → `+80 cc`

**Total earned:** 80 + 80 + 0 + 80 = 240 cc
**Residual:** 270 - 240 - 70 (penalty) = -40 → capped at 0 → **30 cc residual**

### Penalties
Withheld from earned credit:
- `-70 cc` — untested MUST requirement
- `-50 cc` — no negative test for MUST_NOT
- `-80 cc` — flaky signal (≥2 runs diverge)
- `-30 cc` — ambiguous spec or `test_required` status

---

## Unit Test → Litmus Assertion Pattern

### Traditional Unit Test (Insufficient)
```rust
#[tokio::test]
async fn test_github_login() {
    let result = handlers::github_login().await;
    assert!(result.is_ok());
}
// Problem: Doesn't verify actual podman calls, passes even if calls are wrong
```

### Litmus Translation (Correct)
```rust
pub struct CreateGitHubSecretSignal { secret_name: String }

#[async_trait]
impl LitmusSignal for CreateGitHubSecretSignal {
    async fn execute(&mut self, ctx: &mut LitmusContext) -> SignalResult {
        handlers::github_login_create_secret(&self.secret_name, &ctx.podman).await?;

        // Assert EXACT podman call
        let calls = ctx.podman.calls_matching(CallMatcher::All(vec![
            CallMatcher::ByCmd("secret"),
            CallMatcher::ByFlag("--driver", "file"),
        ]));

        if calls.is_empty() {
            return SignalResult::Fail {
                reason: "podman secret create not called with --driver=file",
                spec_trace: "spec:secrets-management",
                recovery: "Check handlers.rs passes correct flags",
            };
        }

        SignalResult::Pass { specs_validated: vec!["secrets-management"], wall_time_ms: ... }
    }

    fn spec_ids(&self) -> Vec<&str> { vec!["secrets-management"] }
}
```

**Key difference:** Asserts on **exact subprocess behavior**, not just "function succeeded."

---

## CI Integration (--ci-full)

```bash
./build.sh --ci-full
```

**Workflow:**

1. **Discover:** Scan `openspec/litmus-bindings.yaml` for specs marked `critical_path: true`
2. **Run:** Execute all bound litmus tests in parallel (grouped by domain), 30s per test
3. **Budget:** Total 300 seconds; 30 seconds per test (enforced timeout)
4. **Flakiness:** Each test runs 3 times; all must have identical result (zero flakiness allowed)
5. **Gate:**
   - If critical-path test fails → Block release with spec trace
   - If all pass → Compute CentiColon, allow archive
6. **Persist:** Write immutable `target/convergence/centicolon-signature.jsonl` (append-only)
7. **Report:** Generate `target/convergence/centicolon-delta.json` for GitHub release notes

**Release artifact example:**
```json
{
  "timestamp": "2026-05-05T14:23:45Z",
  "version": "0.1.42.103",
  "litmus_tests_run": 34,
  "litmus_passed": 34,
  "project_cc_earned": 2650,
  "project_cc_total": 2800,
  "residual_cc": 150,
  "top_residual_reasons": [
    { "reason": "Untested requirement: forge-offline#R1", "cc": 70 },
    { "reason": "Ambiguous spec: browser-isolation-core", "cc": 80 }
  ]
}
```

---

## Files & Deliverables

### Specification & Design
- **`methodology/litmus-framework.yaml`** — Complete design spec (layers, traits, examples, CI integration, CentiColon model)
- **`crates/tillandsias-litmus/README.md`** — Getting started guide and API reference
- **`crates/tillandsias-litmus/src/mock/podman.rs.example`** — Pseudocode implementation pattern for MockPodmanRuntime, LitmusSignal, ConvergenceObligation

### Implementation Tasks (Checklist)
**Framework Core:**
- [ ] `crates/tillandsias-litmus/` crate creation
- [ ] `MockPodmanRuntime` trait + in-memory implementation
- [ ] `LitmusSignal` trait definition
- [ ] `LitmusTest` trait definition + DAG executor
- [ ] `SignalResult` and `TestResult` enums with spec trace support

**First Atomic Signals:**
- [ ] `CreateSecretSignal` — validates `podman secret create --driver=file`
- [ ] `GitSecretMountSignal` — validates `podman run --secret <name>`
- [ ] `ImageExistsSignal` — validates `podman image exists`
- [ ] `NetworkExistsSignal` — validates enclave network exists

**First Composite Test:**
- [ ] `GitHubLoginTest` — compose 3–4 signals into full --github-login flow

**Convergence Reporting:**
- [ ] `ConvergenceObligation` struct + obligation budget rules
- [ ] `CentiColon` scoring logic (earned, penalties, residual)
- [ ] `LitmusSignature` JSONL writer (append-only, immutable)
- [ ] `CentiColonDelta` JSON emitter for CI reports

**CI Integration:**
- [ ] `--ci-full` flag handler in `build.sh`
- [ ] Parallel test runner (300s total budget, 30s per test)
- [ ] Flakiness detector (3 runs, identical required)
- [ ] Critical-path test gating (block release on failure)
- [ ] Evidence bundle generator

---

## Traceability Chain

Every litmus test connects the full convergence stack:

```
Spec (spec:secrets-management)
  ↓ @trace spec:secrets-management
Code (handlers.rs calls podman)
  ↓ (intercepted by)
CreateGitHubSecretSignal
  ↓ (emits @trace)
SignalResult::Fail { spec_trace: "spec:secrets-management" }
  ↓ (mapped to)
ConvergenceObligation { spec_id: "secrets-management", earned: 80, penalty: -70 }
  ↓ (aggregated to)
CentiColon { earned: 2650, residual: 150, top_reasons: [...] }
  ↓ (persisted to)
target/convergence/centicolon-signature.jsonl
  ↓ (reported in)
GitHub release notes + convergence dashboard
```

---

## Key Properties

**1. Observable:** All assertions are on external subprocess behavior (podman calls), not internal state.

**2. Composable:** Atomic signals combine into tests; tests compose into end-to-end flows. No inheritance required.

**3. Deterministic:** Mock eliminates timing, flakiness, and side effects. Same inputs → same results, always.

**4. Falsifiable:** A failing test immediately names the violated spec and suggests recovery.

**5. Cost-tracked:** Wall time, I/O, flakiness all measured. CI budget enforced (300s total).

**6. Spec-driven:** Every test validates requirements from `openspec/litmus-bindings.yaml`. Coverage tracked as CentiColon residual.

---

## References

**Methodology:**
- `methodology/litmus.yaml` — Litmus test structure, binding rules, completeness mapping
- `methodology/litmus-framework.yaml` — THIS FRAMEWORK (full design)
- `methodology/convergence.yaml` — Convergence engine, metrics, drift control
- `methodology/proximity.yaml` — CentiColon obligation model and earning rules

**Code:**
- `crates/tillandsias-podman/src/client.rs` — PodmanClient abstraction being tested
- `openspec/litmus-bindings.yaml` — Active spec-to-test registry

**Getting Started:**
- `crates/tillandsias-litmus/README.md` — Implementation guide
- `crates/tillandsias-litmus/src/mock/podman.rs.example` — Pseudocode patterns
