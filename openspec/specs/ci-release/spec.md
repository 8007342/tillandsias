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

## Litmus Tests

### test_ci_workflow_node_version (binding: litmus:ci-correctness)
**Setup**: Inspect `.github/workflows/ci.yml`
**Signal**: Environment variable `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24` set at workflow level
**Pass**: Variable is present and set to `true`
**Fail**: Variable missing, set to `false`, or set only at job/step level instead of workflow level

### test_release_workflow_node_version (binding: litmus:ci-correctness)
**Setup**: Inspect `.github/workflows/release.yml`
**Signal**: Both `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24=true` at workflow level AND `actions/setup-node@v4` with `node-version: 24`
**Pass**: Both conditions met
**Fail**: Either condition missing or variable inconsistent between setup and force-flag

### test_node_version_consistency (binding: litmus:ci-correctness)
**Setup**: Run `grep -A5 'setup-node' .github/workflows/*.yml`
**Signal**: All invocations of `setup-node@v4` specify `node-version: 24`
**Pass**: Every setup-node call uses version 24
**Fail**: Any setup-node call uses different version (v18, v20, etc.)

### test_environment_variable_propagation (binding: litmus:ci-correctness)
**Setup**: Run both CI and release workflows in test environment
**Signal**: Node.js 24 binary is actually invoked (verify via `node --version` in workflow logs)
**Pass**: Workflow logs show `v24.x.x` output
**Fail**: Logs show different Node version or variable not respected by GitHub Actions

### test_upstream_validation_cadence (binding: litmus:ci-correctness)
**Setup**: Check git history for `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24` mentions
**Signal**: At least one commit in past 6 months with message containing "Node.js 24" or "Node setup" validating upstream
**Pass**: Recent validation commit found with rationale
**Fail**: No validation evidence or validation older than 6 months

### test_env_variable_format (binding: litmus:ci-correctness)
**Setup**: Parse YAML in both CI and release workflow files
**Signal**: Environment variable declared at top-level `env:` key with name matching exactly `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24`
**Pass**: Variable present with exact name and `true` value
**Fail**: Typo in name, wrong value, or declared at wrong YAML nesting level

## Sources of Truth

- `cheatsheets/utils/gh-cli.md` — Gh Cli reference and patterns
- `cheatsheets/build/cargo.md` — Cargo reference and patterns

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:ci-release" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
