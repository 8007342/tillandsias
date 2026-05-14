<!-- @trace spec:ci-release -->

## Status

active

## Requirements

### Release workflow uses Node.js 24

The release workflow MUST use `actions/setup-node@v4` with `node-version: 24`.
This keeps the release job aligned with the current GitHub Actions support
policy without depending on an undocumented force flag.

#### Scenario: Node setup version
- **WHEN** `actions/setup-node@v4` is used in the release workflow
- **THEN** `node-version` is set to `24`

## Litmus Chain

Smallest actionable boundary:
- `grep -F 'node-version: 24' .github/workflows/release.yml`

Sibling tests:
- `./scripts/github-actions-convergence.sh`
- `./scripts/local-ci.sh --ci-mode`

Scoped follow-up:
```bash
./build.sh --ci-full --install --filter ci-release --strict ci-release
./build.sh --ci-full --install --strict-all
```

## Litmus Tests

### test_release_workflow_node24_policy (binding: litmus:ci-release-node24-policy)
**Setup**: Inspect `.github/workflows/release.yml`
**Signal**: Release workflow uses `actions/setup-node@v4` with `node-version: 24`
**Pass**: Release workflow pins Node 24
**Fail**: Release workflow omits Node 24 or uses a different version

## Sources of Truth

- `cheatsheets/utils/gh-cli.md` — Gh Cli reference and patterns
- `cheatsheets/build/cargo.md` — Cargo reference and patterns

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:ci-release" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
