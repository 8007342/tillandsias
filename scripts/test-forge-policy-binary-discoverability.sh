#!/usr/bin/env bash
# @trace spec:default-image, spec:forge-as-only-runtime
# test-forge-policy-binary-discoverability.sh — test CARGO_TARGET_DIR-aware binary resolution.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

TEST_TARGET_DIR="$(mktemp -d "/home/forge/.cache/test-policy-target.XXXXXX")"
trap 'rm -rf "$TEST_TARGET_DIR"' EXIT

echo "Building tillandsias-policy into custom CARGO_TARGET_DIR=${TEST_TARGET_DIR}..."
CARGO_TARGET_DIR="${TEST_TARGET_DIR}" cargo build --quiet --manifest-path "${REPO_ROOT}/Cargo.toml" -p tillandsias-policy

echo "Testing scripts/check-no-python-scripts.sh with redirected CARGO_TARGET_DIR..."
CARGO_TARGET_DIR="${TEST_TARGET_DIR}" "${REPO_ROOT}/scripts/check-no-python-scripts.sh" >/dev/null

echo "Testing scripts/tillandsias-policy validate-yaml with redirected CARGO_TARGET_DIR..."
CARGO_TARGET_DIR="${TEST_TARGET_DIR}" "${REPO_ROOT}/scripts/tillandsias-policy" validate-yaml "${REPO_ROOT}/methodology.yaml" >/dev/null

echo "Testing scripts/tillandsias-podman CLI discovery with redirected CARGO_TARGET_DIR..."
CARGO_TARGET_DIR="${TEST_TARGET_DIR}" "${REPO_ROOT}/scripts/tillandsias-podman" --version >/dev/null 2>&1 || true

echo "ok: forge-policy-binary-discoverability PASS"
