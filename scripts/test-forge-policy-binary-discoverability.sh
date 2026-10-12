#!/usr/bin/env bash
# @trace spec:default-image, spec:forge-as-only-runtime
# test-forge-policy-binary-discoverability.sh — test CARGO_TARGET_DIR-aware binary resolution.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# The redirected target dir lives OUTSIDE the repo root, under the forge's
# cache by default. TILLANDSIAS_POLICY_TARGET_PARENT moves it, so a host can
# run the same steps (1630-dwab measured them on darwin that way).
TEST_TARGET_DIR="$(mktemp -d "${TILLANDSIAS_POLICY_TARGET_PARENT:-/home/forge/.cache}/test-policy-target.XXXXXX")"
trap 'rm -rf "$TEST_TARGET_DIR"' EXIT

echo "Building tillandsias-policy into custom CARGO_TARGET_DIR=${TEST_TARGET_DIR}..."
CARGO_TARGET_DIR="${TEST_TARGET_DIR}" cargo build --quiet --manifest-path "${REPO_ROOT}/Cargo.toml" -p tillandsias-policy

# 1630-dwab: the decider is a Lua script on the one runner since its port.
PLAN_BIN="$(cd "$REPO_ROOT" && . scripts/plan-binary-probe.sh && resolve_plan_binary)" || {
    echo "could-not-run: no tillandsias-plan resolves to run scripts/lua/check-no-python-scripts.lua"; exit 1; }
echo "Testing scripts/lua/check-no-python-scripts.lua with redirected CARGO_TARGET_DIR..."
(cd "$REPO_ROOT" && CARGO_TARGET_DIR="${TEST_TARGET_DIR}" "$PLAN_BIN" script run scripts/lua/check-no-python-scripts.lua >/dev/null)

echo "Testing scripts/tillandsias-policy validate-yaml with redirected CARGO_TARGET_DIR..."
CARGO_TARGET_DIR="${TEST_TARGET_DIR}" "${REPO_ROOT}/scripts/tillandsias-policy" validate-yaml "${REPO_ROOT}/methodology.yaml" >/dev/null

echo "Testing scripts/tillandsias-podman CLI discovery with redirected CARGO_TARGET_DIR..."
CARGO_TARGET_DIR="${TEST_TARGET_DIR}" "${REPO_ROOT}/scripts/tillandsias-podman" --version >/dev/null 2>&1 || true

echo "ok: forge-policy-binary-discoverability PASS"
