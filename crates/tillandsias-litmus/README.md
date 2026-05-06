# tillandsias-litmus: Rust Litmus Test Framework

**Purpose:** Verify that Tillandsias code produces correct podman calls, with CentiColon convergence tracking.

## Architecture

```
tillandsias-litmus/
├── src/
│   ├── mock/                  # MockPodmanRuntime trait + in-memory impl
│   │   ├── podman.rs          # Subprocess interception
│   │   └── env.rs             # Environment variable mocking
│   ├── signal/                # Atomic litmus signals
│   │   ├── mod.rs             # LitmusSignal trait
│   │   ├── registry.rs        # Signal registry and discovery
│   │   └── examples/          # CreateSecret, GitMount, ImageExists, etc.
│   ├── test/                  # Composite tests (DAG of signals)
│   │   ├── mod.rs             # LitmusTest trait
│   │   ├── graph.rs           # Dependency graph and topological sort
│   │   └── examples/          # GitHubLoginTest, EnclaveBringUpTest
│   ├── convergence/           # CentiColon metrics
│   │   ├── mod.rs             # ConvergenceObligation struct
│   │   ├── centicolon.rs      # CentiColon scoring and residual tracking
│   │   └── signature.rs       # JSONL persistence (append-only)
│   └── lib.rs                 # Public API
├── Cargo.toml
└── tests/
    ├── integration_tests.rs    # Full-stack test execution
    └── fixtures/              # Podman response fixtures
```

## Core Traits

### MockPodmanRuntime

```rust
pub trait MockPodmanRuntime {
    fn exec(&mut self, cmd: &str, args: &[&str], env: &[(&str, &str)]) -> Result<ProcessOutput>;
    fn inject_response(&mut self, predicate: CallMatcher, response: ProcessOutput);
    fn calls_matching(&self, predicate: CallMatcher) -> Vec<&CallRecord>;
    fn reset(&mut self);
    fn stats(&self) -> MockStats;
}
```

Intercepts `podman` CLI calls without requiring actual podman. Records exact arguments, environment, stdout/stderr. Tests inject pre-configured responses to simulate errors, missing images, network failures.

### LitmusSignal

```rust
#[async_trait]
pub trait LitmusSignal {
    async fn preconditions_met(&self, runtime: &MockPodmanRuntime) -> Result<()>;
    async fn execute(&mut self, ctx: &mut LitmusContext) -> SignalResult;
    fn spec_ids(&self) -> Vec<&str>;
    fn timeout_millis(&self) -> u32;
}
```

Validates one semantic requirement from a spec. Preconditions are checked first; if unmet, signal is SKIPPED. Execute runs the actual test logic. Failure includes a spec trace for CI logging.

### LitmusTest

```rust
pub trait LitmusTest {
    fn child_signals(&self) -> Vec<&dyn LitmusSignal>;
    async fn execute_sequential(&mut self, ctx: &mut LitmusContext) -> TestResult;
    fn spec_ids(&self) -> Vec<&str>;
    fn critical_path(&self) -> bool;
}
```

Combines atomic signals into a coherent test. Executes signals sequentially; first failure halts the test and fails the parent immediately. All signals must complete within the test timeout (default 30s).

## Example: GitHub Login Test

**Spec Requirement:** `spec:secrets-management` — "Credentials are read from ephemeral podman secrets, never stored on disk or logged."

**Test Structure:**

```
GitHubLoginTest
├── CreateGitHubSecretSignal
│   └── Assert: `podman secret create --driver=file tillandsias-github-token`
├── GitSecretMountSignal
│   └── Assert: `podman run ... --secret tillandsias-github-token ...`
├── GitAuthenticateSignal
│   └── Assert: git command succeeds with token from `/run/secrets/tillandsias-github-token`
└── CleanupSecretSignal
    └── Assert: `podman secret rm tillandsias-github-token`
```

**Signal Implementation:**

```rust
/// Signal: "GitHub login creates podman secret with --driver=file"
/// @trace spec:secrets-management
pub struct CreateGitHubSecretSignal {
    secret_name: String,
}

#[async_trait]
impl LitmusSignal for CreateGitHubSecretSignal {
    async fn preconditions_met(&self, runtime: &MockPodmanRuntime) -> Result<()> {
        // Ensure clean state
        Ok(())
    }

    async fn execute(&mut self, ctx: &mut LitmusContext) -> SignalResult {
        handlers::github_login_create_secret(&self.secret_name, &ctx.podman).await?;

        // Assert exact podman call
        let calls = ctx.podman.calls_matching(
            CallMatcher::All(vec![
                CallMatcher::ByCmd("secret"),
                CallMatcher::ByFlag("--driver", "file"),
            ])
        );

        if calls.is_empty() {
            return SignalResult::Fail {
                reason: "podman secret create not called with --driver=file",
                spec_trace: "spec:secrets-management (ephemeral requirement)",
                recovery: "Check handlers.rs passes correct flags to podman".into(),
            };
        }

        SignalResult::Pass {
            specs_validated: vec!["secrets-management".into()],
            wall_time_ms: calls[0].wall_time_ms,
        }
    }

    fn spec_ids(&self) -> Vec<&str> {
        vec!["secrets-management"]
    }

    fn timeout_millis(&self) -> u32 {
        5000
    }
}
```

## CentiColon Scoring

**Obligation Budget for `spec:secrets-management`:**
```
100 cc (MUST: ephemeral secrets)
+ 100 cc (MUST_NOT: credentials on disk)
+ 40 cc (SHOULD: rotate tokens)
× 1.5 (security boundary multiplier)
= 270 cc total
```

**GitHubLoginTest Results:**
```
Pass CreateGitHubSecretSignal     → +80 cc (positive test)
Pass GitSecretMountSignal         → +80 cc (positive test)
Fail GitAuthenticateSignal        → 0 cc earned, -70 cc (untested MUST)
Pass CleanupSecretSignal          → +80 cc (positive test)
                                     -30 cc (no negative case for MUST_NOT)
Total earned: 210 cc
Residual: 270 - 210 = 60 cc
```

## CI Integration (--ci-full)

```bash
./build.sh --ci-full
```

1. **Discover Tests:** Scan `openspec/litmus-bindings.yaml` for `critical_path: true` specs
2. **Run Tests:** Execute all bound litmus tests in parallel (grouped by domain)
   - Each test has 30s timeout
   - Total budget: 300s
   - Flakiness check: each test runs 3 times, all must be identical
3. **Compute Metrics:** Aggregate CentiColons, identify residual obligations
4. **Gate Release:** Block if critical-path test fails; emit failing spec trace
5. **Persist Evidence:** Write `target/convergence/centicolon-signature.jsonl` (append-only)
6. **Report:** Generate `target/convergence/centicolon-delta.json` for GitHub release notes

## Traceability

Every litmus test connects the convergence stack:

```
Spec (spec:secrets-management)
  ↓ @trace spec:secrets-management
Code (handlers.rs)
  ↓ (calls)
CreateGitHubSecretSignal
  ↓ (validates)
@trace spec:secrets-management (in LitmusSignal)
  ↓ (earned/penalty)
CentiColon (60 residual cc)
  ↓ (persisted)
target/convergence/centicolon-signature.jsonl
```

## Getting Started

1. Create `crates/tillandsias-litmus/Cargo.toml` (new crate)
2. Implement `MockPodmanRuntime` in-memory backend
3. Define first 4 atomic signals (CreateSecret, GitMount, ImageExists, NetworkExists)
4. Compose GitHubLoginTest with those signals
5. Run: `cargo test -p tillandsias-litmus`
6. Integrate with `--ci-full`: call litmus runner before release archive

## References

- `methodology/litmus-framework.yaml` — Full design spec
- `methodology/litmus.yaml` — Litmus test structure and binding rules
- `methodology/proximity.yaml` — CentiColon obligation model
- `openspec/litmus-bindings.yaml` — Active spec-to-test bindings
