---
id: github-actions
title: GitHub Actions CI/CD
category: ci/github
tags: [github-actions, ci, cd, workflow, automation, releases]
upstream: https://docs.github.com/en/actions
version_pinned: "2024"
last_verified: "2026-03-30"
authority: official
---

# GitHub Actions CI/CD

## Workflow File Basics

Workflows live in `.github/workflows/*.yml`. Each file defines one workflow.

```yaml
name: CI
on:
  push:
    branches: [main]
    paths: ["src/**", "Cargo.toml"]
  pull_request:
    branches: [main]
  schedule:
    - cron: "0 6 * * 1"            # weekly Monday 06:00 UTC

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: echo "Hello"
```

## Manual Triggers (workflow_dispatch)

Supports up to 25 inputs (raised from 10 in late 2025).

```yaml
on:
  workflow_dispatch:
    inputs:
      version:
        description: "Release version"
        required: true
        type: string
      dry_run:
        description: "Skip publish"
        type: boolean
        default: false

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - run: echo "Version=${{ inputs.version }}, dry=${{ inputs.dry_run }}"
```

Trigger from CLI: `gh workflow run release.yml -f version=1.2.3 -f dry_run=true`

## Matrix Builds

```yaml
jobs:
  test:
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-latest, macos-latest, windows-latest]
        rust: [stable, "1.78"]
        exclude:
          - os: windows-latest
            rust: "1.78"
        include:
          - os: ubuntu-latest
            rust: nightly
            experimental: true
    runs-on: ${{ matrix.os }}
    continue-on-error: ${{ matrix.experimental || false }}
    steps:
      - uses: dtolnay/rust-toolchain@master
        with:
          toolchain: ${{ matrix.rust }}
      - run: cargo test --workspace
```

## Caching

**Generic cache:**

```yaml
- uses: actions/cache@v4
  with:
    path: |
      ~/.cargo/registry
      ~/.cargo/git
      target/
    key: ${{ runner.os }}-cargo-${{ hashFiles('**/Cargo.lock') }}
    restore-keys: ${{ runner.os }}-cargo-
```

**Rust-specific (recommended):**

```yaml
- uses: Swatinem/rust-cache@v2
  with:
    shared-key: "ci"               # share across jobs
    cache-on-failure: true
```

## Artifacts

```yaml
# Upload
- uses: actions/upload-artifact@v4
  with:
    name: binaries-${{ matrix.os }}
    path: target/release/myapp
    retention-days: 7

# Download (in a later job)
- uses: actions/download-artifact@v4
  with:
    name: binaries-ubuntu-latest
    path: ./dist
```

## Job Dependencies and Outputs

```yaml
jobs:
  check:
    runs-on: ubuntu-latest
    outputs:
      should_deploy: ${{ steps.decide.outputs.deploy }}
    steps:
      - id: decide
        run: echo "deploy=true" >> "$GITHUB_OUTPUT"

  deploy:
    needs: [check]
    if: needs.check.outputs.should_deploy == 'true'
    runs-on: ubuntu-latest
    steps:
      - run: echo "deploying"
```

## Conditional Execution

```yaml
steps:
  - run: echo "only on main"
    if: github.ref == 'refs/heads/main'

  - run: echo "not a fork"
    if: github.event.pull_request.head.repo.full_name == github.repository

  - run: echo "previous failed"
    if: failure()

  - run: echo "always runs"
    if: always()

  # case function (added Jan 2026)
  - run: echo "env=${{ case(github.ref, 'refs/heads/main', 'prod', 'refs/heads/staging', 'stg', 'dev') }}"
```

## Concurrency Groups

Prevent parallel runs; optionally cancel in-progress ones.

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
```

Per-environment (deploy serialization):

```yaml
concurrency:
  group: deploy-production
  cancel-in-progress: false        # queue, don't cancel
```

## Environment Secrets

```yaml
jobs:
  deploy:
    environment:
      name: production
      url: https://example.com
    runs-on: ubuntu-latest
    steps:
      - run: deploy --token "${{ secrets.DEPLOY_TOKEN }}"
```

Environments support required reviewers, wait timers, and branch protection rules.

## OIDC for Cloud Auth (No Static Secrets)

Short-lived tokens replace stored cloud credentials.

```yaml
permissions:
  id-token: write
  contents: read

steps:
  - uses: aws-actions/configure-aws-credentials@v4
    with:
      role-to-arn: arn:aws:iam::123456789:role/gh-actions
      aws-region: us-east-1
```

Works with AWS, GCP, Azure. The cloud provider validates the OIDC token claims
(repo, branch, environment) and issues a scoped, ephemeral credential.

## Reusable Workflows (workflow_call)

**Callee** (`.github/workflows/shared-build.yml`):

```yaml
on:
  workflow_call:
    inputs:
      rust_version:
        type: string
        default: stable
    secrets:
      DEPLOY_KEY:
        required: false

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: dtolnay/rust-toolchain@master
        with:
          toolchain: ${{ inputs.rust_version }}
```

**Caller:**

```yaml
jobs:
  call-build:
    uses: ./.github/workflows/shared-build.yml
    with:
      rust_version: "1.80"
    secrets: inherit                # pass all secrets
```

Nesting limit: 10 deep, 50 total workflows per run.

## Composite Actions

Bundle multiple steps into a single reusable action (`.github/actions/setup-rust/action.yml`):

```yaml
name: Setup Rust
description: Install Rust and restore cache
inputs:
  toolchain:
    default: stable
runs:
  using: composite
  steps:
    - uses: dtolnay/rust-toolchain@master
      with:
        toolchain: ${{ inputs.toolchain }}
    - uses: Swatinem/rust-cache@v2
      shell: bash
```

Usage: `uses: ./.github/actions/setup-rust`

## GitHub CLI in Workflows

`gh` is pre-installed on all runners. Auth is automatic with `GITHUB_TOKEN`.

```yaml
steps:
  - uses: actions/checkout@v4
  - run: gh release create "v1.2.3" ./dist/*.tar.gz --title "v1.2.3" --notes "Release notes"
    env:
      GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

Other useful commands:

```yaml
- run: gh pr comment ${{ github.event.number }} --body "Build passed"
- run: gh issue close 42
- run: gh workflow run deploy.yml -f version=1.2.3
```

## Release Workflow Pattern

```yaml
on:
  workflow_dispatch:
    inputs:
      version:
        required: true
        type: string

jobs:
  build:
    strategy:
      matrix:
        include:
          - os: ubuntu-latest
            target: x86_64-unknown-linux-gnu
          - os: macos-latest
            target: aarch64-apple-darwin
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - run: cargo build --release --target ${{ matrix.target }}
      - uses: actions/upload-artifact@v4
        with:
          name: bin-${{ matrix.target }}
          path: target/${{ matrix.target }}/release/myapp

  publish:
    needs: build
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: actions/download-artifact@v4
      - run: |
          gh release create "v${{ inputs.version }}" \
            bin-*/* \
            --title "v${{ inputs.version }}" \
            --generate-notes
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

## Quick Reference

| Feature | Key | Limit / Note |
|---|---|---|
| workflow_dispatch inputs | `inputs.<name>` | 25 max |
| Reusable workflow nesting | `workflow_call` | 10 deep, 50 total |
| Matrix combinations | `strategy.matrix` | 256 max per job |
| Concurrency | `concurrency.group` | string key, org-wide |
| Artifact retention | `retention-days` | 1-90, default 90 |
| GITHUB_TOKEN scope | `permissions` | least-privilege recommended |
| Job timeout | `timeout-minutes` | default 360 (6h) |

## Sources

- [Workflow syntax for GitHub Actions](https://docs.github.com/actions/using-workflows/workflow-syntax-for-github-actions)
- [Reusing workflow configurations](https://docs.github.com/en/actions/concepts/workflows-and-actions/reusing-workflow-configurations)
- [Creating a composite action](https://docs.github.com/en/actions/sharing-automations/creating-actions/creating-a-composite-action)
- [OpenID Connect](https://docs.github.com/en/actions/concepts/security/openid-connect)
- [workflow_dispatch now supports 25 inputs](https://github.blog/changelog/2025-12-04-actions-workflow-dispatch-workflows-now-support-25-inputs/)
- [case function (Jan 2026)](https://github.blog/changelog/2026-01-29-github-actions-smarter-editing-clearer-debugging-and-a-new-case-function/)
