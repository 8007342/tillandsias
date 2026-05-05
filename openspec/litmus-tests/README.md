# Tillandsias Litmus Tests

Executable litmus tests for critical security and ephemeral-first guarantees.

## Test Summary

| Test | Spec(s) | Severity | Description |
|------|---------|----------|-------------|
| `litmus-ephemeral-guarantee.yaml` | `forge-offline` | **CRITICAL** | Verify forge container cannot reach external IP |
| `litmus-enclave-isolation.yaml` | `enclave-network` | **CRITICAL** | Verify forge/proxy network isolation |
| `litmus-credential-isolation.yaml` | `native-secrets-store` | **CRITICAL** | Verify forge has NO access to GitHub token |
| `litmus-browser-ephemeral.yaml` | `chromium-safe-variant` | **CRITICAL** | Verify browser tmpdir deleted on exit |
| `litmus-init-log-cleanup.yaml` | `ephemeral-guarantee` | **HIGH** | Verify init logs deleted on shutdown |
| `litmus-environment-isolation.yaml` | `environment-runtime` | **HIGH** | Verify forge sees minimal environment only |
| `litmus-ca-ephemeral.yaml` | `certificate-authority` | **HIGH** | Verify CA certs deleted on shutdown |
| `litmus-token-file-cleanup.yaml` | `secrets-management` | **CRITICAL** | Verify token files cleaned on exit |
| `litmus-socket-cleanup.yaml` | `enclave-network`, `control-socket` | **HIGH** | Verify no leftover Unix sockets |
| `litmus-mount-cleanup.yaml` | `podman-orchestration` | **HIGH** | Verify no leftover bind mounts |

## Spec Coverage

- **forge-offline**: 1 test
- **enclave-network**: 2 tests (enclave-isolation, socket-cleanup)
- **native-secrets-store**: 1 test
- **chromium-safe-variant**: 1 test
- **ephemeral-guarantee**: 3 tests (ephemeral-guarantee, init-log-cleanup, mount-cleanup)
- **environment-runtime**: 1 test
- **certificate-authority**: 1 test
- **secrets-management**: 1 test
- **podman-orchestration**: 1 test
- **control-socket**: 1 test

**Coverage**: 10 tests covering 10 distinct specs (some with multiple tests for depth)

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
