<!-- @trace spec:ci-release -->

## Status

active

## Requirements

### Release workflow publishes the Linux musl binary

The release workflow MUST publish the `tillandsias-linux-x86_64` musl-static
binary as the canonical Linux release artifact. It MUST NOT depend on Tauri,
AppImage packaging, Node.js, or host WebKit packaging.

#### Scenario: Linux binary artifact
- **WHEN** the release workflow completes
- **THEN** the GitHub Release includes `tillandsias-linux-x86_64`
- **AND** the workflow validates that the binary is statically linked
- **AND** the workflow signs the artifact with a `.cosign.bundle`

### Hosted CI stays static-only

GitHub-hosted CI MUST avoid real Podman runtime execution, e2e container
launches, and desktop/browser runtime smoke tests. Runtime validation belongs
to local release recovery or dedicated runtime environments.

#### Scenario: Hosted litmus workflow
- **WHEN** `.github/workflows/litmus-tests.yml` runs on GitHub-hosted runners
- **THEN** it validates litmus metadata and coverage only
- **AND** it MUST NOT install Podman or run `scripts/run-litmus-test.sh`

#### Scenario: Main branch convergence
- **WHEN** code is pushed to `main`
- **THEN** GitHub Actions runs the static convergence workflow only
- **AND** failures are limited to formatting, clippy, unit tests, spec binding,
  spec-code drift, or cheatsheet tier discipline

## Litmus Chain

Smallest actionable boundary:
- `grep -F 'tillandsias-linux-x86_64' .github/workflows/release.yml`
- `grep -F 'statically linked' .github/workflows/release.yml`
- `! grep -F 'scripts/run-litmus-test.sh' .github/workflows/litmus-tests.yml`

Sibling tests:
- `./scripts/github-actions-convergence.sh`
- `./scripts/local-ci.sh --ci-mode`

Scoped follow-up:
```bash
./build.sh --ci-full --install --filter ci-release --strict ci-release
./build.sh --ci-full --install --strict-all
```

## Litmus Tests

### test_release_workflow_musl_binary_policy (binding: litmus:ci-release-musl-binary-policy)
**Setup**: Inspect `.github/workflows/release.yml`
**Signal**: Release workflow builds, validates, signs, and publishes the Linux
musl binary
**Pass**: Release workflow publishes `tillandsias-linux-x86_64` and hosted
litmus stays metadata-only
**Fail**: Release workflow drifts back to Node/Tauri/AppImage or cloud runtime
execution

## Sources of Truth

- `cheatsheets/utils/gh-cli.md` — Gh Cli reference and patterns
- `cheatsheets/build/cargo.md` — Cargo reference and patterns
- `cheatsheets/build/validation-ci.md` — Static hosted CI policy
- `cheatsheets/runtime/linux-user-session-podman.md` — Local/runtime Podman boundary

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:ci-release" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
