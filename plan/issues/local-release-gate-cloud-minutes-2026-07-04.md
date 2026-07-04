# optimization: move release preflight work off GitHub-hosted minutes

- class: optimization
- filed: 2026-07-04T01:25:00Z
- agent: codex-meta-orchestration
- host: linux_mutable
- relates: `.github/workflows/release.yml`, `scripts/local-ci.sh`,
  `scripts/release-preflight-local.sh`, `openspec/specs/ci-release/spec.md`

## Observation

The release path had GitHub-hosted workflows for normal CI, convergence dashboard
updates, litmus checks, and Nix cache warming. Those jobs consumed limited
GitHub cloud minutes for work that a local mutable Linux host can perform before
dispatching a release. The expensive remote boundary should be restricted to the
parts that need GitHub infrastructure: platform release builds, OIDC-backed
signing, release asset upload, and rolling tag movement.

Two process gaps made the waste repeatable:

- The release runbook did not name a local preflight gate as the required first
  step before triggering hosted release work.
- `scripts/verify-version-monotonic.sh` compared against tags merged into the
  current branch only, so a branch behind the latest release tag could pass with
  a globally regressive `VERSION`.

## Reduction

Implemented a local release preflight path and removed hosted workflows that
duplicated local checks:

- Added `scripts/release-preflight-local.sh` to fetch remote state and tags,
  verify global version monotonicity, run `scripts/local-ci.sh`, and optionally
  perform local Nix release-target probes.
- Kept `.github/workflows/release.yml` as the hosted release boundary for final
  builds, signing, publishing, and rolling tags.
- Removed hosted normal CI, convergence dashboard, litmus, and cache-warm
  workflows, plus the GitHub Actions convergence dashboard script and generated
  dashboard files.
- Updated release documentation, cheatsheets, specs, and litmus tests so agents
  do integration checks and dashboard updates locally before spending cloud
  minutes.
- Updated the version monotonicity guard to compare against all fetched release
  tags, not only tags reachable from the current branch.

## Verification

- `git diff --check`
- YAML parser pass over release workflow, edited litmus YAML, and methodology
  YAML.
- `bash -n scripts/release-preflight-local.sh scripts/local-ci.sh`
- `scripts/verify-version-monotonic.sh`
- `cargo metadata --locked --no-deps --format-version 1`
- `cargo fmt --all --check`
- `cargo clippy --workspace -- -D warnings`
- `scripts/run-litmus-test.sh --phase pre-build --size instant --filter ci-release,nix-builder,observability-convergence,cheatsheet-tooling --compact`
- `scripts/local-ci.sh --fast --phase pre-build`

Status: implemented in this cycle. Residual risk is limited to the existing
all-spec advisory litmus debt already filed in
`plan/issues/pre-existing-litmus-debt-2026-07-03.md`.
