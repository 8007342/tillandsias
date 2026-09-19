#!/usr/bin/env bash
# @trace order:1274-cbk7, spec:spec-traceability
#
# THE DEFECT. Two checks answer two different questions, and the one authors
# reach for did not say which was which:
#
#   run-litmus-test.sh --parse-only    -> "can the RUNNER extract steps here"
#   scripts/check-litmus-yaml-parses.sh -> "does this LOAD as YAML"
#
# The runner's parser is line-based and tolerates a duplicated mapping key,
# silently taking the last occurrence. A YAML loader rejects the document
# outright. So a file could be reported parseable and be unloadable at once.
#
# It happened: during the 1252-znbn migration three corpus files gained a
# duplicate key, --parse-only reported every file ok, and the gate refused with
# blocked:yaml-load-failed roughly fifteen minutes later. The author had run a
# check and read a green verdict. The check was real; it was aimed at a
# different question than the one being asked of it.
#
# ARM 1 IS THE LOAD-BEARING ONE. It neutralises the fix in a COPY of the runner
# and requires the defect to come back. Without it, every other arm here would
# stay green if the detector were deleted tomorrow — a fixture that cannot fail
# has moved the prose, not the teeth.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

TMP="$(mktemp -d)"
# The pre-fix copy MUST live under scripts/ — the runner derives PROJECT_ROOT
# from its own path, and a copy in /tmp would resolve a different tree.
PREFIX_RUNNER="$ROOT/scripts/.cbk7-prefix-runner.$$.sh"
trap 'rm -rf "$TMP" "$PREFIX_RUNNER"' EXIT

# check-litmus-pin-claims.sh scans scripts/ for `<prefix>:<name>` and treats a
# bare occurrence as a pin claim, so the token is assembled rather than written.
LIT="litmus"
OK_PARSEABLE="ok:${LIT}-parseable"

pass=0; fail=0
ok()   { printf 'ok:   %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); }

# write_probe <file> <extra-key-lines>
write_probe() {
    local dest="$1" extra="$2"
    {
        printf '%s\n' "name: ${LIT}:cbk7-probe"
        printf '%s\n' "spec: spec-traceability"
        printf '%s\n' "phase: pre-build"
        printf '%s\n' "severity: high"
        printf '%s\n' "size: instant"
        printf '%s\n' "description: >"
        printf '%s\n' "  probe for 1274-cbk7"
        printf '%s\n' "critical_path:"
        printf '%s\n' '  - step: "a step"'
        printf '%s\n' '    command: "echo hello"'
        printf '%s\n' "    timeout_ms: 3000"
        [ -n "$extra" ] && printf '%s\n' "$extra"
        printf '%s\n' '    expected_behavior: "hello"'
    } > "$dest"
}

write_probe "$TMP/clean.yaml"       '    assert_output_contains: "hello"'
write_probe "$TMP/dup-assert.yaml"  '    assert_output_contains: "hello"
    assert_output_contains: "hello"'
write_probe "$TMP/dup-timeout.yaml" '    timeout_ms: 9000'
write_probe "$TMP/dup-command.yaml" '    command: "echo again"'

# ---------------------------------------------------------------- ARM 0
# THE PREMISE. Asserted before any verdict is read: the duplicates really are
# YAML-invalid and the clean file really is valid. If a future YAML reader
# started accepting duplicate keys, every arm below would still "pass" while
# testing nothing, and this arm is what would notice.
READER="$(command -v tillandsias-plan 2>/dev/null || true)"
if [ -z "$READER" ]; then
    printf 'skip:%s-parse-only-duplicate-key:no-yaml-reader-on-PATH\n' "$LIT"
    exit 0
fi
"$READER" validate-yaml "$TMP/clean.yaml" >/dev/null 2>&1
rc_clean_yaml=$?
"$READER" validate-yaml "$TMP/dup-assert.yaml" >/dev/null 2>&1
rc_dup_yaml=$?
if [ "$rc_clean_yaml" -eq 0 ] && [ "$rc_dup_yaml" -ne 0 ]; then
    ok "ARM 0: premise — a YAML loader ACCEPTS the clean probe and REJECTS the duplicate"
else
    bad "ARM 0: premise broken (clean rc=$rc_clean_yaml, dup rc=$rc_dup_yaml) — the gap this row closes is not reproducible, so no arm below means anything"
fi

# ---------------------------------------------------------------- ARM 1
# PRE-FIX CONTROL. Neutralise the detector in a copy and require the false
# green to return.
sed 's|^ *duplicate_keys+=(.*|                    : # neutralised for ARM 1|' \
    "$ROOT/scripts/run-litmus-test.sh" > "$PREFIX_RUNNER" 2>/dev/null
chmod +x "$PREFIX_RUNNER" 2>/dev/null

# ASSERT THE MUTATION LANDED. A sed that matched nothing produces a copy
# identical to the subject, and "the defect did not reproduce" would then be
# indistinguishable from "the mutation never applied".
live_hits="$(grep -c 'duplicate_keys+=(' "$ROOT/scripts/run-litmus-test.sh")"
mut_hits="$(grep -c 'duplicate_keys+=(' "$PREFIX_RUNNER")"
if [ "$live_hits" -ge 1 ] && [ "$mut_hits" -eq 0 ]; then
    prefix_out="$("$PREFIX_RUNNER" --parse-only "$TMP/dup-assert.yaml" 2>&1)"
    prefix_rc=$?
    if [ "$prefix_rc" -eq 0 ] && printf '%s' "$prefix_out" | grep -Fq "$OK_PARSEABLE"; then
        ok "ARM 1: PRE-FIX the duplicate is reported parseable and exits 0 — the defect reproduces on demand"
    else
        bad "ARM 1: pre-fix copy did NOT reproduce the false green (rc=$prefix_rc) — the arm is not exercising the defect"
    fi
else
    bad "ARM 1: mutation did not apply (live=$live_hits mutant=$mut_hits) — refusing to read a verdict from an unmutated copy"
fi

# ---------------------------------------------------------------- ARMS 2-4
# THE FIX, on the assert key that was actually hit AND on two keys outside the
# assert family. A fix keyed on assert_* would close the instance and leave
# every other key open.
for probe in dup-assert:assert_output_contains dup-timeout:timeout_ms dup-command:command; do
    f="${probe%%:*}"; key="${probe##*:}"
    out="$(scripts/run-litmus-test.sh --parse-only "$TMP/$f.yaml" 2>&1)"
    rc=$?
    if [ "$rc" -ne 0 ] \
       && printf '%s' "$out" | grep -Fq "$f.yaml" \
       && printf '%s' "$out" | grep -Fq "$key"; then
        ok "ARM: duplicated '$key' refused, exit $rc, refusal names the file and the key"
    else
        bad "ARM: duplicated '$key' not refused as required (rc=$rc): $(printf '%s' "$out" | tail -1)"
    fi
done

# ---------------------------------------------------------------- ARM 5
# NEGATIVE CONTROL. A refusal that also fires on valid input has replaced a
# false green with a false red.
out="$(scripts/run-litmus-test.sh --parse-only "$TMP/clean.yaml" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -Fq "${OK_PARSEABLE}"; then
    ok "ARM 5: a clean probe still reports parseable with its step count, exit 0"
else
    bad "ARM 5: clean probe no longer passes (rc=$rc) — false green traded for false red"
fi

# ---------------------------------------------------------------- ARM 6
# THE CORPUS IS UNCHANGED. The row's criterion quotes a fixed count, but a
# fixed number rots as the corpus grows; what must hold is that this change
# adds no refusal. Compared against the neutralised copy on the SAME tree.
if [ "$mut_hits" -eq 0 ]; then
    live_n="$(scripts/run-litmus-test.sh --parse-only openspec/${LIT}-tests/*.yaml 2>&1 | grep -c "^${OK_PARSEABLE}:")"
    base_n="$("$PREFIX_RUNNER" --parse-only openspec/${LIT}-tests/*.yaml 2>&1 | grep -c "^${OK_PARSEABLE}:")"
    if [ "$live_n" -eq "$base_n" ]; then
        ok "ARM 6: real corpus unchanged — $live_n files parseable with the detector, $base_n without it"
    else
        bad "ARM 6: corpus changed ($base_n -> $live_n) — the detector fires on a file the loader accepts"
    fi
else
    bad "ARM 6: no usable baseline copy"
fi

# ---------------------------------------------------------------- ARM 7
# THE MODE SAYS WHICH QUESTION IT ANSWERS, and names the other check by path.
out="$(scripts/run-litmus-test.sh --parse-only "$TMP/clean.yaml" 2>&1)"
if printf '%s' "$out" | grep -Fq 'check-litmus-yaml-parses.sh' \
   && printf '%s' "$out" | grep -Fqi 'NOT YAML validity'; then
    ok "ARM 7: --parse-only states its scope and names the check for YAML validity"
else
    bad "ARM 7: --parse-only does not say which question it answers"
fi

printf '\n'
if [ "$fail" -eq 0 ]; then
    printf 'ok:%s-parse-only-duplicate-key:%d/%d\n' "$LIT" "$pass" "$((pass + fail))"
    exit 0
fi
printf 'blocked:%s-parse-only-duplicate-key:%d-failed-of-%d\n' "$LIT" "$fail" "$((pass + fail))"
exit 1
