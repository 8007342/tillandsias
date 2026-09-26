#!/usr/bin/env bash
# @trace order:1395-ue3i
#
# test-centicolon-ratchet.sh — the ADVISORY CentiColon R line: printed every
# run, WARNS on a lost satisfaction, reports added/removed obligations as scope
# (never as regression), prints blocked: rather than R=0, and ALWAYS exits 0.
#
# Hermetic corpus (the same shape test-centicolon-grade.sh builds): one
# requirement satisfied by an enforced, bound, pre-build litmus step with a
# green record; others unbound. Arms, in order against one snapshot:
#   1 first run            -> regime=baseline, R/satisfied/denominator printed
#   2 unchanged rerun      -> regime=monotone
#   3 green record removed -> warn:centicolon-ratchet:lost=1:<id>, regime=lost:1, rc 0
#   4 --no-snapshot twice with the loss still present -> both warn (a report
#     never swallows the next --check's warning)
#   5 a requirement added  -> regime=scope-added:1, no lost warning
#   6 a requirement removed -> regime=scope-removed:1
#   7 no spec corpus       -> "centicolon: blocked:…", rc 0, never R=0
# Pre-fix every arm FAILS: the script does not exist.

set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
RATCHET="$ROOT/scripts/check-centicolon-ratchet.sh"
[ -f "$RATCHET" ] || { echo "fail:centicolon-ratchet:no-script:$RATCHET"; exit 1; }

. "$ROOT/scripts/plan-binary-probe.sh"
if ! PLAN="$(resolve_plan_binary)"; then echo "skip:centicolon-ratchet:no-runnable-plan-binary"; exit 0; fi
if ! grep -qx 'predicate' <<<"$("$PLAN" capabilities 2>/dev/null)"; then
    echo "skip:centicolon-ratchet:plan-binary-lacks-predicate-verb:$PLAN"; exit 0
fi
command -v jq >/dev/null 2>&1 || { echo "skip:centicolon-ratchet:no-jq"; exit 0; }
export TILLANDSIAS_PLAN_BIN="$PLAN"

pass=0; fail=0
# Built from a variable so check-litmus-pin-claims.sh (721-77yu) does not read
# the hermetic name as a claim about a real litmus test.
LP="litmus"
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }
if command -v sha256sum >/dev/null 2>&1; then SHA=(sha256sum); else SHA=(shasum -a 256); fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ccr.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
H="$WORK/h"; mkdir -p "$H/openspec/specs/alpha" "$H/openspec/litmus-tests"
spec() { # <req letters...>
    { printf 'status: active\n\n'
      for x in "$@"; do printf '### Requirement: Req %s\n<!-- req-id: aaaa000%s -->\n\n#### Scenario: Scenario %s\n\n' "$x" "$x" "$x"; done
    } >"$H/openspec/specs/alpha/spec.md"
}
spec a b
printf "version: '1.0'\nspecs:\n- spec_id: alpha\n  status: active\n  litmus_tests:\n  - $LP:a-file\n" >"$H/openspec/litmus-bindings.yaml"
: >"$H/openspec/litmus-tests/unbound-grandfathered.txt"
printf 'name: %s:a-file\nspec: alpha\nphase: pre-build\nsize: instant\ncritical_path:\n  - step: "s"\n    requirement: aaaa000a\n    command: "true"\n    assert_exit: 0\n' "$LP" >"$H/openspec/litmus-tests/litmus-a.yaml"
green() {
    printf '{"ts":"2026-09-26T01:00:00Z","host":"fixture","step":"%s:a-file","status":"pass","digest":"%s"}\n' "$LP" \
        "$("${SHA[@]}" <"$H/openspec/litmus-tests/litmus-a.yaml" | cut -c1-64)" >"$WORK/log.jsonl"
}
run() { OUT="$(TILLANDSIAS_REPO_ROOT="$H" TILLANDSIAS_TIMING_LOG="$WORK/log.jsonl" bash "$RATCHET" "$@" 2>&1)"; RC=$?; LINE="$(grep '^centicolon:' <<<"$OUT")"; }
ID_A="cc:aaaa000a:$(printf 'Scenario a' | "${SHA[@]}" | cut -c1-8)"

green; run
[ "$RC" -eq 0 ] && [ "$LINE" = "centicolon: R=1 satisfied=1 denominator=2 histogram=declared:1,traced:0,positively_tested:1 regime=baseline (advisory)" ] \
    && ok "1 baseline line printed" || bad "1: rc=$RC [$LINE]"
run
[ "$RC" -eq 0 ] && grep -q ' regime=monotone (advisory)$' <<<"$LINE" && ok "2 unchanged rerun -> monotone" || bad "2: [$LINE]"

: >"$WORK/log.jsonl"
run --no-snapshot; w1="$(grep -c '^warn:centicolon-ratchet:lost=1:' <<<"$OUT")"
run --no-snapshot; w2="$(grep -c '^warn:centicolon-ratchet:lost=1:' <<<"$OUT")"
[ "$w1" = 1 ] && [ "$w2" = 1 ] && ok "4 --no-snapshot reports the loss without swallowing it" || bad "4: warnings $w1/$w2"
run
if [ "$RC" -eq 0 ] && grep -qx "warn:centicolon-ratchet:lost=1:$ID_A" <<<"$OUT" && grep -q ' satisfied=0 .* regime=lost:1 (advisory)$' <<<"$LINE"; then
    ok "3 lost satisfaction -> warn by id, regime=lost:1, exit 0 (advisory, never refused)"
else bad "3: rc=$RC [$(grep -E '^(warn|centicolon):' <<<"$OUT" | tr '\n' ' ')]"; fi

green; run   # regain A, re-snapshot
spec a b c; run
if grep -q ' denominator=3 .* regime=scope-added:1 (advisory)$' <<<"$LINE" && ! grep -q '^warn:centicolon-ratchet:lost' <<<"$OUT"; then
    ok "5 added requirement -> scope-added:1, R rises honestly, no lost warning"
else bad "5: [$LINE] $(grep '^warn:centicolon-ratchet' <<<"$OUT")"; fi
spec a c; run
grep -q ' denominator=2 .* regime=scope-removed:1 (advisory)$' <<<"$LINE" && ok "6 removed requirement -> scope-removed:1" || bad "6: [$LINE]"

rm -rf "$H/openspec/specs"; run
if [ "$RC" -eq 0 ] && grep -q '^centicolon: blocked:' <<<"$LINE" && ! grep -q 'R=0' <<<"$LINE"; then
    ok "7 no corpus -> blocked, exit 0, never R=0"
else bad "7: rc=$RC [$LINE]"; fi

if [ "$fail" -eq 0 ]; then echo "ok:centicolon-ratchet:$pass"; exit 0; fi
echo "fail:centicolon-ratchet:$fail failed, $pass passed"; exit 1
