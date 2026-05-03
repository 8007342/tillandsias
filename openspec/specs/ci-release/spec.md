<!-- @trace spec:ci-release -->

## Status: active

## Requirements

### Node.js 24 runtime for GitHub Actions

Both CI and release workflows MUST opt into Node.js 24 for GitHub Actions runners using `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24=true`. This environment variable is not documented in the verified GitHub Actions knowledge base and SHALL be periodically validated against upstream GitHub documentation.

#### Scenario: CI workflow uses Node.js 24
- **WHEN** the CI workflow runs
- **THEN** the `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24` environment variable is set to `true` at the workflow level

#### Scenario: Release workflow uses Node.js 24
- **WHEN** the release workflow runs
- **THEN** the `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24` environment variable is set to `true` at the workflow level

#### Scenario: Node setup version
- **WHEN** `actions/setup-node@v4` is used in the release workflow
- **THEN** `node-version` is set to `24`

#### Scenario: Upstream validation
- **WHEN** the project performs a periodic dependency or CI audit
- **THEN** the `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24` variable is checked against current GitHub Actions documentation to confirm it remains a supported mechanism

## Sources of Truth

- `cheatsheets/utils/gh-cli.md` — Gh Cli reference and patterns
- `cheatsheets/build/cargo.md` — Cargo reference and patterns

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:ci-release" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
