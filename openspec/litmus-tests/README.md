# Tillandsias Litmus Tests

Executable litmus tests for critical security and ephemeral-first guarantees.

Phase notes:
- `phase: pre-build` covers command-shape and static contract checks before install
- `phase: post-build` covers the single representative built-artifact smoke
- `phase: runtime` covers the residual container-backed suite
- `phase: retired` marks tombstoned tests kept only for traceability

## Test Summary

| Test | Spec(s) | Severity | Description |
|------|---------|----------|-------------|
| `litmus-ephemeral-guarantee.yaml` | `forge-offline` | **CRITICAL** | Verify forge container cannot reach external IP |
| `litmus-enclave-isolation.yaml` | `enclave-network` | **CRITICAL** | Verify forge/proxy network isolation |
| `litmus-credential-isolation.yaml` | `native-secrets-store` | **CRITICAL** | Verify forge has NO access to GitHub token |
| `litmus-browser-ephemeral.yaml` | `chromium-safe-variant` | **CRITICAL** | Verify browser tmpdir deleted on exit |
| `litmus-init-log-cleanup.yaml` | `ephemeral-guarantee` | **HIGH** | Verify init logs do not persist after init |
| `litmus-environment-isolation.yaml` | `environment-runtime` | **HIGH** | Verify forge sees minimal environment only |
| `litmus-ca-ephemeral.yaml` | `certificate-authority` | **HIGH** | Verify CA certs deleted on shutdown |
| `litmus-podman-build-command-shape.yaml` | `podman-orchestration` | **MEDIUM** | Verify build-image emits the expected podman command shape |
| `litmus-podman-container-spec-shape.yaml` | `podman-container-spec` | **MEDIUM** | Verify the typed Podman spec builder stays pure and deterministic |
| `litmus-podman-container-handle-shape.yaml` | `podman-container-handle` | **MEDIUM** | Verify the typed Podman handle retains identity and spec snapshot |
| `litmus-nix-builder-shape.yaml` | `nix-builder` | **MEDIUM** | Verify the Nix builder stays build-time only and uses git-tracked sources plus copyToRoot |
| `litmus-podman-web-launch-profile.yaml` | `podman-orchestration` | **MEDIUM** | Verify web-mode launch stays detached and mount-safe |
| `litmus-container-naming.yaml` | `podman-orchestration` | **MEDIUM** | Verify forge container naming stays deterministic |
| `litmus-forge-cache-dual-shape.yaml` | `forge-cache-dual` | **MEDIUM** | Verify cache discipline stays wired to the dual-cache contract |
| `litmus-forge-environment-discoverability-shape.yaml` | `forge-environment-discoverability` | **MEDIUM** | Verify discovery commands and the welcome banner stay in sync |
| `litmus-forge-hot-cold-split-shape.yaml` | `forge-hot-cold-split` | **MEDIUM** | Verify the hot/cold split stays visible and the config budget seam remains stable |
| `litmus-forge-opencode-onboarding-shape.yaml` | `forge-opencode-onboarding` | **MEDIUM** | Verify the OpenCode onboarding bundle and startup bootstrap stay wired together |
| `litmus-forge-shell-tools-shape.yaml` | `forge-shell-tools` | **MEDIUM** | Verify the forge image still ships the shell tool package set and interactive shell integrations |
| `litmus-forge-staleness-shape.yaml` | `forge-staleness` | **MEDIUM** | Verify forge image freshness checks, alias refresh, and pruning still match the live build script contract |
| `litmus-forge-welcome-shape.yaml` | `forge-welcome` | **MEDIUM** | Verify the welcome banner layout, rotating tips, and once-per-session gating stay wired to the terminal launch path |
| `litmus-gh-auth-script-smoke.yaml` | `gh-auth-script` | **MEDIUM** | Verify the GitHub login flow still exercises the fake ephemeral Podman harness |
| `litmus-clickable-trace-index-generation.yaml` | `clickable-trace-index` | **MEDIUM** | Verify trace generation, backlink files, and build integration |
| `litmus-clickable-trace-index-observatorium-skeleton.yaml` | `clickable-trace-index` | **MEDIUM** | Verify the local observatorium launcher and three-pane shell |
| `litmus-cheatsheet-tooling-structure.yaml` | `cheatsheet-tooling` | **MEDIUM** | Verify cheatsheet tree layout, template, and generated index invariants |
| `litmus-cheatsheet-source-layer-validation.yaml` | `cheatsheet-source-layer` | **MEDIUM** | Verify the cheatsheet source validator stays callable on a fresh workspace |
| `litmus-cheatsheet-tier-discipline.yaml` | `cheatsheets-license-tiered` | **MEDIUM** | Verify cheatsheet tier discipline stays valid under the tier validator |
| `litmus-ci-release-node24-policy.yaml` | `ci-release` | **MEDIUM** | Verify CI and release workflows enforce the Node 24 policy |
| `litmus-cli-mode-shape.yaml` | `cli-mode` | **MEDIUM** | Verify cli-mode command-shape seams stay deterministic in unit tests |
| `litmus-mcp-on-demand-shape.yaml` | `mcp-on-demand` | **MEDIUM** | Verify the MCP on-demand tray socket mount remains wired into the forge profile |
| `litmus-podman-path-availability.yaml` | `podman-orchestration` | **CRITICAL** | Verify podman is installed on PATH before stack scripts run |
| `litmus-headless-init-status-check-command-shape.yaml` | `dev-build` | **HIGH** | Verify the installed binary emits the expected direct podman argv for init plus status-check |
| `litmus-inference-readiness-probe-shape.yaml` | `inference-container`, `async-inference-launch` | **HIGH** | Verify inference readiness is split between health and API probes |
| `litmus-status-check-stack-verification.yaml` | `dev-build` | **HIGH** | Verify post-build smoke launches the stack and reports online evidence |
| `litmus-release-artifact-integrity.yaml` | `binary-signing` | **HIGH** | Verify release signing and verification stay on the Cosign bundle contract |
| `litmus-browser-tray-launch-profile.yaml` | `browser-isolation-tray-integration` | **MEDIUM** | Verify tray-driven OpenCode Web launch stays detached and persistent |
| `litmus-opencode-web-startup-sequence.yaml` | `browser-isolation-tray-integration` | **HIGH** | Verify OpenCode Web emits a health-gated startup sequence before browser launch |
| `litmus-host-browser-mcp-shape.yaml` | `host-browser-mcp` | **MEDIUM** | Verify the browser MCP surface, bridge, and launcher wiring remain intact |
| `litmus-socket-cleanup.yaml` | `enclave-network`, `control-socket` | **HIGH** | Verify no leftover Unix sockets after a stack run |
| `litmus-mount-cleanup.yaml` | `podman-orchestration` | **HIGH** | Verify no leftover bind mounts |

## Spec Coverage

- **forge-offline**: 1 test
- **enclave-network**: 2 tests (enclave-isolation, socket-cleanup)
- **native-secrets-store**: 1 test
- **security-privacy-isolation**: 7 tests (credential-isolation, environment-isolation, enclave-isolation, socket-cleanup, podman-container-spec, podman-container-handle, podman-orchestration)
- **chromium-safe-variant**: 1 test
- **ephemeral-guarantee**: 3 tests (ephemeral-guarantee, init-log-cleanup, mount-cleanup)
- **inference-container**: 2 tests (enclave-isolation, inference-readiness-probe-shape)
- **async-inference-launch**: 1 test (inference-readiness-probe-shape)
- **environment-runtime**: 1 test
- **certificate-authority**: 1 test
- **secrets-management**: 1 test
- **podman-orchestration**: 4 tests (podman-build-command-shape, podman-web-launch-profile, container-naming, podman-path-availability)
- **forge-cache-dual**: 1 test (forge-cache-dual-shape)
- **forge-environment-discoverability**: 1 test (forge-environment-discoverability-shape)
- **forge-hot-cold-split**: 1 test (forge-hot-cold-split-shape)
- **forge-opencode-onboarding**: 1 test (forge-opencode-onboarding-shape)
- **forge-shell-tools**: 1 test (forge-shell-tools-shape)
- **forge-staleness**: 1 test (forge-staleness-shape)
- **forge-welcome**: 1 test (forge-welcome-shape)
- **gh-auth-script**: 1 test (gh-auth-script-smoke)
- **nix-builder**: 1 test (nix-builder-shape)
- **mcp-on-demand**: 1 test (mcp-on-demand-shape)
- **cheatsheet-tooling**: 1 test (cheatsheet-tooling-structure)
- **clickable-trace-index**: 2 tests (clickable-trace-index-generation, clickable-trace-index-observatorium-skeleton)
- **cheatsheet-source-layer**: 1 test (cheatsheet-source-layer-validation)
- **cheatsheets-license-tiered**: 1 test (cheatsheet-tier-discipline)
- **ci-release**: 1 test (ci-release-node24-policy)
- **cli-mode**: 1 test (cli-mode-shape)
- **podman-container-spec**: 1 test
- **podman-container-handle**: 1 test
- **binary-signing**: 1 test
- **browser-isolation-tray-integration**: 2 tests
- **host-browser-mcp**: 1 test (host-browser-mcp-shape)
- **control-socket**: 1 test
- **dev-build**: 3 tests (environment-isolation, headless-init-status-check-command-shape, status-check-stack-verification)

**Coverage**: 40 tests covering 35 distinct specs (some with multiple tests for depth)

## Running Tests

### All Tests
```bash
cd /var/home/machiyotl/src/tillandsias
for test in openspec/litmus-tests/litmus-*.yaml; do
  echo "Running $(basename $test)..."
  ./scripts/run-litmus-test.sh "$test"
done
```

### Single Test
```bash
./scripts/run-litmus-test.sh openspec/litmus-tests/litmus-ephemeral-guarantee.yaml
```

### By Severity
```bash
# Critical tests only
grep -l "severity: critical" openspec/litmus-tests/litmus-*.yaml | while read f; do
  ./scripts/run-litmus-test.sh "$f"
done
```

## Test Format

Each test is a self-contained YAML file with:

1. **Metadata**: name, spec linkage, description, severity
2. **Preconditions**: what must be true before test runs
3. **Critical path**: ordered steps with timeouts and expected behavior
4. **Gating points**: success/failure criteria
5. **Observability**: @trace annotations, expected logs, log fields
6. **Rollback**: cleanup on failure

## Key Principles

- **Event-driven, not polling**: Tests use explicit waits and signals
- **Timeout discipline**: Every command has a timeout_ms
- **Spec linkage**: Every test traces back to spec(s) via `@trace` annotations
- **Failure isolation**: Rollback actions prevent cascading failures
- **Meaningful signals**: Success/failure criteria are unambiguous

## Running via CI/CD

See `.github/workflows/litmus-tests.yml` for automated execution on every push.

## Related Documentation

- `docs/cheatsheets/ephemeral-first.md` — Ephemeral guarantee design
- `openspec/specs/enclave-network/spec.md` — Enclave architecture
- `openspec/specs/secrets-management/spec.md` — Token/credential lifecycle

## Retired Litmus

These tests are tombstoned and no longer counted in active coverage:

- `litmus-build-cache-transparent.yaml`
- `litmus-build-clean-from-scratch-works.yaml`
- `litmus-ci-unchanged-behavior.yaml`
- `litmus-toolbox-isolation.yaml`
