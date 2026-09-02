#!/usr/bin/env bash
# ORDER 956-llei. The kill-time adjudicator classifies a step TIMEOUT by
# diffing THIS cgroup's cpu.pressure `some total=` counter across the step's
# own window — CONTENDED / NOT contended / UNCLASSIFIED — and never by the
# retired host-wide load1-vs-ncpus rule (not namespaced: forge steps were
# judged by the host's runqueue; utilization is not starvation; the trailing
# window measured the previous step).
#
# Three arms, each run THROUGH THE REAL RUNNER (cheatsheet: verifying a
# fixture means running it through its runner, not executing its commands by
# hand). The runner derives PROJECT_ROOT from its own path, so a temp root
# with a symlinked scripts/ dir and a single probe yaml IS the project for
# the duration of the arm. LITMUS_PSI_FILE points the adjudicator at an
# injected counter file instead of /sys/fs/cgroup/cpu.pressure.
#
# Every arm also asserts the step actually reached TIMEOUT: a probe the
# runner skipped or could not parse would otherwise pass every negative
# assertion by never running (bound-and-still-unrunnable).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/litmus-kill-adjudicator.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/openspec/litmus-tests" "$tmp/methodology" "$tmp/target"
ln -s "$ROOT/scripts" "$tmp/scripts"
ln -s "$ROOT/methodology/litmus.yaml" "$tmp/methodology/litmus.yaml"
# The probe's name is COMPOSED here, never written as a literal `litmus:<slug>`
# token: the 721-77yu pin checker reads such a token in a script as a claim
# that a suite test verifies something, and this probe is fixture-local — it
# exists only in the temp root, for the seconds each arm runs.
probe_slug="kill-adjudicator-probe"
probe_name="litmus:${probe_slug}"

# The runner resolves the positional spec filter through the bindings file;
# the probe's spec exists only here, so bind it here (minimal, active).
cat > "$tmp/openspec/litmus-bindings.yaml" <<EOF
specs:
  - spec_id: ${probe_slug}
    status: active
    litmus_tests:
      - ${probe_name}
EOF

psi="$tmp/cpu.pressure"
probe="$tmp/openspec/litmus-tests/litmus-${probe_slug}.yaml"

# $1 = the step command, as a double-quoted YAML scalar body (no backslashes:
# the runner unescapes quoted scalars, 875-v7hv). It must overrun the 2s
# budget; what it does before that decides the arm.
write_probe() {
    cat > "$probe" <<EOF
# fixture-only probe: deliberately overruns its budget so the TIMEOUT
# adjudicator runs (956-llei). Lives only in a temp root, never in the suite.
name: ${probe_name}
spec: ${probe_slug}
phase: pre-build
size: instant
severity: low
description: >
  Fixture probe for the kill-time adjudicator (956-llei).
critical_path:
  - step: "overrun the budget"
    command: "$1"
    timeout_ms: 2000
    expected_behavior: "never-matches"
EOF
}

# Runner output, both streams; the probe is SUPPOSED to fail, so the runner's
# exit code is not the fixture's verdict.
run_probe() {
    (cd "$tmp" && bash "$tmp/scripts/run-litmus-test.sh" kill-adjudicator-probe --phase pre-build --timeout 2 2>&1) || true
}

pass=0; fail=0
check() { # $1 = ok|FAIL, $2 = label
    if [ "$1" = ok ]; then pass=$((pass + 1)); printf 'ok   %s\n' "$2"
    else fail=$((fail + 1)); printf 'FAIL %s\n' "$2"; fi
}
reached_timeout() { grep -q 'TIMEOUT' <<<"$1"; }
retired_instrument_absent() { ! grep -q 'load1=' <<<"$1"; }

# --- Arm 1: counter advances 3,000,000us during a ~2s step -> >=25% -> CONTENDED
printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=1000000\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' > "$psi"
write_probe "echo 'some avg10=0.00 avg60=0.00 avg300=0.00 total=4000000' > \$LITMUS_PSI_FILE; sleep 30"
out="$(LITMUS_PSI_FILE="$psi" run_probe)"
if reached_timeout "$out" && grep -q 'cpu.pressure some-stall 3000000us over [0-9]*s ([0-9]*%) in this cgroup — step CONTENDED at kill time' <<<"$out"; then
    check ok "advancing counter -> CONTENDED, names cpu.pressure and the stall"
else
    check FAIL "advancing counter -> CONTENDED"; printf '%s\n' "$out" | grep -E 'TIMEOUT|cpu.pressure|load1|SKIP|Error|error' | head -5 | sed 's/^/     /'
fi
check "$(retired_instrument_absent "$out" && echo ok || echo FAIL)" "retired load1-vs-ncpus instrument absent (arm 1)"

# --- Arm 2: counter flat -> 0% -> NOT contended
printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=5000000\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' > "$psi"
write_probe "sleep 30"
out="$(LITMUS_PSI_FILE="$psi" run_probe)"
if reached_timeout "$out" && grep -q 'cpu.pressure some-stall 0us over [0-9]*s (0%) in this cgroup — step NOT contended at kill time' <<<"$out"; then
    check ok "flat counter -> NOT contended"
else
    check FAIL "flat counter -> NOT contended"; printf '%s\n' "$out" | grep -E 'TIMEOUT|cpu.pressure|load1|SKIP|Error|error' | head -5 | sed 's/^/     /'
fi
# 956-llei second rung: a killed test's row in the slowest-tests table is
# marked censored — its elapsed time is the budget, a lower bound, not a
# measurement. The probe is killed at 2s, above the table's 0.5s floor.
if grep -q 'killed at budget — censored' <<<"$out"; then
    check ok "slowest-tests table marks the killed probe as censored"
else
    check FAIL "slowest-tests table marks the killed probe as censored"; grep -A3 'Slowest tests' <<<"$out" | head -4 | sed 's/^/     /'
fi

# --- Arm 3: no pressure file -> UNCLASSIFIED, and no fallback instrument
write_probe "sleep 30"
out="$(LITMUS_PSI_FILE="$tmp/absent-cpu.pressure" run_probe)"
if reached_timeout "$out" && grep -q 'cpu.pressure unavailable in this cgroup — cause UNCLASSIFIED' <<<"$out" && retired_instrument_absent "$out"; then
    check ok "no pressure file -> UNCLASSIFIED, no fallback instrument"
else
    check FAIL "no pressure file -> UNCLASSIFIED"; printf '%s\n' "$out" | grep -E 'TIMEOUT|cpu.pressure|load1|SKIP|Error|error' | head -5 | sed 's/^/     /'
fi

total=$((pass + fail))
if [ "$fail" -eq 0 ]; then
    echo "PASS: litmus kill-time adjudicator diffs cpu.pressure ${pass}/${total} arms (956-llei)"
    exit 0
fi
echo "FAIL: litmus kill-time adjudicator ${fail}/${total} arms red (956-llei)"
exit 1
