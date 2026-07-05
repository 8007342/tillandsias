<!-- @trace spec:ci-release -->

## Status

active

## Requirements

### Release workflow publishes the Linux musl binary

The release workflow MUST publish the `tillandsias-linux-x86_64` musl-static
binary as the canonical Linux release artifact. It MUST NOT depend on Tauri,
AppImage packaging, Node.js, or host WebKit packaging.
The hosted runner MUST build the musl-static release artifacts through the
repository Nix targets and MUST use the configured FlakeHub cache.

#### Scenario: Linux binary artifact
- **WHEN** the release workflow completes
- **THEN** the GitHub Release includes `tillandsias-linux-x86_64`
- **AND** the workflow validates that the binary is statically linked
- **AND** the workflow signs the artifact with a `.cosign.bundle`
- **AND** the workflow builds `.#tillandsias-x86_64-musl`

### Hosted workflows stay release-only

GitHub-hosted workflows MUST be reserved for remote-only release work:
platform builds, artifact sanity checks, Cosign keyless signing through GitHub
OIDC, GitHub Release upload, and rolling tags. Verification, litmus execution,
dashboard generation, cache probing, merge work, and integration checks belong
to the local release gate.

#### Scenario: Local litmus and dashboard gate
- **WHEN** an operator prepares a release
- **THEN** they run `scripts/release-preflight-local.sh`
- **AND** the local preflight runs `scripts/local-ci.sh`
- **AND** hosted workflows do not run litmus, convergence dashboard, cache warm,
  or general CI jobs

#### Scenario: Manual hosted release
- **WHEN** `.github/workflows/release.yml` is dispatched manually
- **THEN** it builds, validates, signs, publishes, and updates rolling tags only

## Litmus Chain

Smallest actionable boundary:
- `grep -F 'tillandsias-linux-x86_64' .github/workflows/release.yml`
- `grep -F 'statically linked' .github/workflows/release.yml`
- `grep -F 'nix build -L .#tillandsias-x86_64-musl' .github/workflows/release.yml`
- `test -x scripts/release-preflight-local.sh`
- `! test -e .github/workflows/litmus-tests.yml`

Sibling tests:
- `./scripts/release-preflight-local.sh --fast`
- `./scripts/local-ci.sh --fast`

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
**Pass**: Release workflow publishes `tillandsias-linux-x86_64` and litmus
execution stays local
**Fail**: Release workflow drifts back to Node/Tauri/AppImage or cloud runtime
execution

## Sources of Truth

- `cheatsheets/utils/gh-cli.md` — Gh Cli reference and patterns
- `cheatsheets/build/cargo.md` — Cargo reference and patterns
- `cheatsheets/build/validation-ci.md` — Local release gate policy
- `cheatsheets/runtime/linux-user-session-podman.md` — Local/runtime Podman boundary

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:ci-release" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
