#!/usr/bin/env bash
# @trace order:798-9xpq, spec:litmus-framework
#
# test-litmus-fake-backend-under-remote-podman.sh — a `backend: fake` litmus test
# is REFUSED up front when a remote podman is configured, because common.sh's
# remote mode pins TILLANDSIAS_PODMAN_BIN ahead of the harness's fake and the
# fixture would silently drive the real podman.
#   1 backend: fake + TILLANDSIAS_PODMAN_REMOTE_URL set -> [ENV-FAIL] refused:litmus-gate:fake-backend-under-remote-podman naming the variable
#   1b the same with CONTAINER_HOST set instead -> refused, naming CONTAINER_HOST
#   2 NEGATIVE CONTROL: the same fake test with neither set RUNS and PASSES
#   3 a non-fake test under a remote URL is not touched by this refusal
# Pre-fix: FAILS at arm 1 (the fake test ran and passed).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W="$(mktemp -d "${TMPDIR:-/tmp}/fake-under-remote.XXXXXX")"
trap 'rm -rf "$W"' EXIT
pass=0
fail=0
ok() { echo "ok:   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail + 1)); }
mkdir -p "$W/lt"
LIT="litmus"
cat >"$W/bindings.yaml" <<YAML
version: '1.0'
description: fixture for 798-9xpq
specs:
- spec_id: spec-traceability
  status: active
  ${LIT}_tests:
  - ${LIT}:x9xpq-probe
  coverage_ratio: 100
  last_verified: '2026-09-29'
YAML
probe() { # probe <backend-line-or-empty> <env...> -> runner output, colour stripped
    local backend="$1"; shift
    cat >"$W/lt/${LIT}-x9xpq-probe.yaml" <<YAML
name: ${LIT}:x9xpq-probe
spec: spec-traceability
phase: pre-build
severity: high
size: instant
${backend}
description: >
  probe for 798-9xpq
critical_path:
  - step: "probe"
    command: "echo probe-done"
    timeout_ms: 20000
    expected_behavior: "probe-done"
YAML
    (cd "$ROOT" && env -u TILLANDSIAS_PODMAN_REMOTE_URL -u CONTAINER_HOST "$@" \
        TILLANDSIAS_LITMUS_BINDINGS="$W/bindings.yaml" TILLANDSIAS_LITMUS_TESTS_DIR="$W/lt" \
        timeout 120 bash scripts/run-litmus-test.sh spec-traceability --phase pre-build --size instant 2>&1 |
        sed 's/\x1b\[[0-9;]*m//g')
}
out="$(probe "backend: fake" TILLANDSIAS_PODMAN_REMOTE_URL=unix:///nonexistent/podman.sock)"
if grep -q 'refused:litmus-gate:fake-backend-under-remote-podman.*TILLANDSIAS_PODMAN_REMOTE_URL is set' <<<"$out" && ! grep -qE 'Status: \[PASS\]' <<<"$out"; then
    ok "1: a fake-backend test under TILLANDSIAS_PODMAN_REMOTE_URL is refused by name"
else
    bad "1: [$(grep -E 'ENV-FAIL|Status' <<<"$out" | head -3)]"
fi
out="$(probe "backend: fake" CONTAINER_HOST=unix:///nonexistent/podman.sock)"
grep -q 'refused:litmus-gate:fake-backend-under-remote-podman.*CONTAINER_HOST is set' <<<"$out" \
    && ok "1b: the same under CONTAINER_HOST is refused, naming CONTAINER_HOST" \
    || bad "1b: [$(grep -E 'ENV-FAIL|Status' <<<"$out" | head -3)]"
out="$(probe "backend: fake")"
if grep -qE 'Status: \[PASS\]' <<<"$out" && ! grep -q 'fake-backend-under-remote-podman' <<<"$out"; then
    ok "2: NEGATIVE CONTROL: the fake test with no remote configured runs and passes"
else
    bad "2: [$(grep -E 'ENV-FAIL|Status' <<<"$out" | head -3)]"
fi
out="$(probe "" TILLANDSIAS_PODMAN_REMOTE_URL=unix:///nonexistent/podman.sock)"
if ! grep -q 'fake-backend-under-remote-podman' <<<"$out" && grep -qE 'Status: \[PASS\]' <<<"$out"; then
    ok "3: a non-fake test under a remote URL is not touched by this refusal"
else
    bad "3: [$(grep -E 'ENV-FAIL|Status' <<<"$out" | head -3)]"
fi
if [ "$fail" -eq 0 ]; then echo "PASS: litmus-fake-backend-under-remote-podman $pass/$((pass + fail))"; exit 0; fi
echo "FAIL: litmus-fake-backend-under-remote-podman $pass/$((pass + fail))"; exit 1
