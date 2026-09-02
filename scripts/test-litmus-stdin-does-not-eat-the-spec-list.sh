#!/usr/bin/env bash
# ORDER 956-llei. A litmus step that READS STDIN must not swallow the rest of
# its spec's bound test list. The runner iterates a spec's tests with a
# here-string on stdin; before the fix, a step containing `cat`/`read` drained
# it and every later test in that spec silently never ran (the instant sweep
# executed 1 of 29 ci-release tests on 2026-09-02 and reported PASS).
#
# Through the real runner in a temp root: one spec, two probes. Probe A's step
# eats stdin, probe B's step prints a marker. Both must execute.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/litmus-stdin.XXXXXX")"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/openspec/litmus-tests" "$tmp/methodology" "$tmp/target"
ln -s "$ROOT/scripts" "$tmp/scripts"
ln -s "$ROOT/methodology/litmus.yaml" "$tmp/methodology/litmus.yaml"

# Names composed, never literal `litmus:<slug>` tokens (721-77yu pin checker).
spec_slug="stdin-probe"
a_slug="stdin-eater"; a_name="litmus:${a_slug}"
b_slug="stdin-second"; b_name="litmus:${b_slug}"
cat > "$tmp/openspec/litmus-bindings.yaml" <<EOF
specs:
  - spec_id: ${spec_slug}
    status: active
    litmus_tests:
      - ${a_name}
      - ${b_name}
EOF
cat > "$tmp/openspec/litmus-tests/litmus-${a_slug}.yaml" <<EOF
name: ${a_name}
spec: ${spec_slug}
phase: pre-build
size: instant
severity: low
description: >
  Fixture probe: its step swallows stdin.
critical_path:
  - step: "eat stdin"
    command: "cat >/dev/null; echo ok: ate-stdin"
    timeout_ms: 5000
    expected_behavior: "ok: ate-stdin"
EOF
cat > "$tmp/openspec/litmus-tests/litmus-${b_slug}.yaml" <<EOF
name: ${b_name}
spec: ${spec_slug}
phase: pre-build
size: instant
severity: low
description: >
  Fixture probe: must still run after the eater.
critical_path:
  - step: "second probe runs"
    command: "echo ok: SECOND-PROBE-RAN"
    timeout_ms: 5000
    expected_behavior: "ok: SECOND-PROBE-RAN"
EOF

out="$(cd "$tmp" && bash "$tmp/scripts/run-litmus-test.sh" "$spec_slug" --phase pre-build 2>&1)" && rc=0 || rc=$?
pass=0; fail=0
check() { if [ "$1" = ok ]; then pass=$((pass+1)); echo "ok   $2"; else fail=$((fail+1)); echo "FAIL $2"; fi; }
grep -q "Executing ${a_name}" <<<"$out" && check ok "eater probe executed" || check FAIL "eater probe executed"
if grep -q "Executing ${b_name}" <<<"$out" && grep -q 'second probe runs.*\[OK\]' <<<"$out"; then
    check ok "second probe executed and passed after the stdin eater"
else
    check FAIL "second probe executed after the stdin eater"; grep -E 'Executing|STEP|Status' <<<"$out" | head -6 | sed 's/^/     /'
fi
[ "$rc" -eq 0 ] && check ok "suite rc=0" || check FAIL "suite rc=$rc"
total=$((pass+fail))
if [ $fail -eq 0 ]; then echo "PASS: litmus stdin does not eat the spec list ${pass}/${total} (956-llei)"; exit 0; fi
echo "FAIL: litmus stdin eats the spec list ${fail}/${total} red (956-llei)"; exit 1
