#!/usr/bin/env bash
# @trace order:1465-ijv3, spec:spec-traceability
#
# test-litmus-test-selector.sh — `run-litmus-test.sh --test litmus:<name>` runs
# EXACTLY ONE bound test through the spec that binds it, so a floor-tier host
# can measure one test without running (and being reaped for) a whole spec.
# Synthetic bindings: one spec binding two tests.
#
#   1  --test litmus:<a> runs a and not b (Total: 1), and PASSes
#   2  a name no spec binds is refused:litmus-runner:test-not-bound:<name>, exit 3
#   3  NEGATIVE CONTROL: the same spec run WITHOUT --test runs both (Total: 2)
#   4  the positional filter's contract is unchanged: a test name given as the
#      positional spec still fails loud (764-8m5j, name-filter-hint-shape)
#   5  --test accepts the name without its litmus: prefix; --test with a
#      different positional spec is refused (exit 3), never silently merged
#
# Pre-fix: FAILS at arm 1 ("Unknown option: --test", exit 3).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W="$(mktemp -d "${TMPDIR:-/tmp}/litmus-test-selector.XXXXXX")"
trap 'rm -rf "$W"' EXIT
pass=0
fail=0
ok() { echo "ok:   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail + 1)); }

LIT="litmus"
mkdir -p "$W/lt"
cat >"$W/bindings.yaml" <<YAML
version: '1.0'
description: fixture for 1465-ijv3
specs:
- spec_id: spec-traceability
  status: active
  ${LIT}_tests:
  - ${LIT}:sel-a
  - ${LIT}:sel-b
  coverage_ratio: 100
  last_verified: '2026-09-28'
YAML
for t in a b; do
    cat >"$W/lt/${LIT}-sel-$t.yaml" <<YAML
name: ${LIT}:sel-$t
spec: spec-traceability
phase: pre-build
severity: high
size: instant
description: >
  probe $t for 1465-ijv3
critical_path:
  - step: "probe $t"
    command: "echo sel-$t-done"
    timeout_ms: 20000
    expected_behavior: "sel-$t-done"
YAML
done
run() { # run <args...> -> cleaned output; rc in $W/rc
    (cd "$ROOT" && TILLANDSIAS_LITMUS_BINDINGS="$W/bindings.yaml" TILLANDSIAS_LITMUS_TESTS_DIR="$W/lt" \
        timeout 120 bash scripts/run-litmus-test.sh "$@" >"$W/out" 2>&1; echo $? >"$W/rc")
    sed 's/\x1b\[[0-9;]*m//g' "$W/out"
}
rc() { cat "$W/rc"; }

# ── 1 ───────────────────────────────────────────────────────────────────────
out="$(run --test "${LIT}:sel-a")"
if [ "$(rc)" = 0 ] && grep -q "Executing ${LIT}:sel-a" <<<"$out" && ! grep -q "${LIT}:sel-b" <<<"$out" &&
    grep -qE 'Total: 1 ' <<<"$out" && grep -qE 'Status: \[PASS\]' <<<"$out"; then
    ok "arm 1: --test ${LIT}:sel-a runs exactly that test (Total: 1) and passes"
else
    bad "arm 1: rc=$(rc) [$(grep -E 'Executing|Total|Status|Unknown' <<<"$out" | head -5)]"
fi

# ── 2 ───────────────────────────────────────────────────────────────────────
out="$(run --test "${LIT}:nope")"
if [ "$(rc)" = 3 ] && grep -qx "refused:litmus-runner:test-not-bound:${LIT}:nope" <<<"$out" && grep -q 'bindings.yaml' <<<"$out"; then
    ok "arm 2: an unbound name is refused:litmus-runner:test-not-bound, exit 3, naming the bindings file"
else
    bad "arm 2: rc=$(rc) [$(head -n 5 <<<"$out")]"
fi

# ── 3 ───────────────────────────────────────────────────────────────────────
out="$(run spec-traceability)"
if [ "$(rc)" = 0 ] && grep -q "Executing ${LIT}:sel-a" <<<"$out" && grep -q "Executing ${LIT}:sel-b" <<<"$out" &&
    grep -qE 'Total: 2 ' <<<"$out"; then
    ok "arm 3: the spec run without --test still runs both bound tests (Total: 2)"
else
    bad "arm 3: rc=$(rc) [$(grep -E 'Executing|Total|Status' <<<"$out" | head -5)]"
fi

# ── 4 ───────────────────────────────────────────────────────────────────────
out="$(run "${LIT}:sel-a")"
if [ "$(rc)" != 0 ] && grep -q "no litmus tests matched filter '${LIT}:sel-a'" <<<"$out"; then
    ok "arm 4: a test name as the POSITIONAL filter still fails loud (the 764-8m5j contract is untouched)"
else
    bad "arm 4: rc=$(rc) [$(grep -E 'matched|Status' <<<"$out" | head -3)]"
fi

# ── 5 ───────────────────────────────────────────────────────────────────────
out="$(run --test sel-b)"
[ "$(rc)" = 0 ] && grep -q "Executing ${LIT}:sel-b" <<<"$out" && ! grep -q "Executing ${LIT}:sel-a" <<<"$out" &&
    ok "arm 5: --test accepts the name without its prefix" || bad "arm 5 prefix: rc=$(rc) [$(grep -E 'Executing|Total' <<<"$out" | head -3)]"
out="$(run --test "${LIT}:sel-a" some-other-spec)"
[ "$(rc)" = 3 ] && grep -q "bound under spec spec-traceability, not some-other-spec" <<<"$out" &&
    ok "arm 5: --test with a different positional spec is refused (exit 3)" || bad "arm 5 conflict: rc=$(rc) [$(head -n 5 <<<"$out")]"

total=$((pass + fail))
if [ "$fail" -eq 0 ]; then
    echo "PASS: litmus-test-selector $pass/$total (1465-ijv3)"
    exit 0
fi
echo "FAIL: litmus-test-selector $pass/$total (1465-ijv3)"
exit 1
