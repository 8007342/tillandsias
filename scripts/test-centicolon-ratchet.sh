#!/usr/bin/env bash
# @trace order:1395-ue3i
#
# test-centicolon-ratchet.sh — the ADVISORY CentiColon R line: printed every
# run, WARNS only on a regression, reports added obligations as scope and
# tombstoned ones as retired, prints blocked: rather than R=0, ALWAYS exits 0.
#
# The ratchet semantics are the operator's (813a552e2, on 1395-ue3i):
# added = scope growth; retired = vanished WITH a tombstone trail (a registry
# `tombstone:` for an obsoleted spec, or an openspec/changes record); lost =
# vanished with no record, or a state moving down. Only lost warns.
#
# Hermetic corpus (the shape test-centicolon-grade.sh builds): requirement a is
# satisfied by an enforced, bound, pre-build litmus step with a green record.
# Arms, in order against one snapshot:
#   1 first run              -> regime=baseline, added/retired/lost 0
#   2 unchanged rerun        -> regime=monotone
#   3 --no-snapshot twice with a's record gone -> both warn (a report never
#     swallows the next --check's warning)
#   4 green record removed   -> lost=1 (down), warn names a's id, rc 0
#   5 a requirement added    -> added=1, regime=scope-added, no warning
#   6 a requirement removed with NO record -> lost=1 (vanished), warn
#   7 a requirement removed WITH an openspec/changes record naming its req-id
#                            -> retired=1, no warning
#   8 a spec obsoleted with a registry tombstone -> retired=<its obligations>,
#     no warning
#   9 no spec corpus         -> "centicolon: blocked:…", rc 0, never R=0
# Pre-fix every arm FAILS: the script does not exist.

set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
RATCHET="$ROOT/scripts/check-centicolon-ratchet.sh"
[ -f "$RATCHET" ] || { echo "fail:centicolon-ratchet:no-script:$RATCHET"; exit 1; }

cd "$ROOT" || exit 1
. "$ROOT/scripts/plan-binary-probe.sh"
if ! PLAN="$(resolve_plan_binary)"; then echo "skip:centicolon-ratchet:no-runnable-plan-binary"; exit 0; fi
if ! grep -qx 'predicate' <<<"$("$PLAN" capabilities 2>/dev/null)"; then
    echo "skip:centicolon-ratchet:plan-binary-lacks-predicate-verb:$PLAN"; exit 0
fi
# Absolute before export: the wrapper cds into a hermetic root (1380-u7sq).
case "$PLAN" in /*) ;; *) PLAN="$ROOT/${PLAN#./}" ;; esac
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

warns() { grep '^warn:centicolon-ratchet:' <<<"$OUT"; }

green; run
[ "$RC" -eq 0 ] && [ "$LINE" = "centicolon: R=1 satisfied=1 denominator=2 added=0 retired=0 lost=0 histogram=declared:1,traced:0,positively_tested:1 regime=baseline (advisory)" ] \
    && ok "1 baseline line printed" || bad "1: rc=$RC [$LINE]"
run
[ "$RC" -eq 0 ] && grep -q ' added=0 retired=0 lost=0 .* regime=monotone (advisory)$' <<<"$LINE" && ok "2 unchanged rerun -> monotone" || bad "2: [$LINE]"

: >"$WORK/log.jsonl"
run --no-snapshot; w1="$(warns | grep -c .)"
run --no-snapshot; w2="$(warns | grep -c .)"
[ "$w1" = 1 ] && [ "$w2" = 1 ] && ok "3 --no-snapshot reports the loss without swallowing it" || bad "3: warnings $w1/$w2"
run
if [ "$RC" -eq 0 ] && [ "$(warns)" = "warn:centicolon-ratchet:lost=1:vanished=0,down=1:$ID_A" ] && grep -q ' satisfied=0 .* lost=1 .* regime=lost (advisory)$' <<<"$LINE"; then
    ok "4 lost satisfaction (down) -> warn by id, exit 0 (advisory, never refused)"
else bad "4: rc=$RC [$(grep -E '^(warn|centicolon):' <<<"$OUT" | tr '\n' ' ')]"; fi

green; run   # regain a, re-snapshot
spec a b c; run
if grep -q ' denominator=3 added=1 retired=0 lost=0 .* regime=scope-added (advisory)$' <<<"$LINE" && [ -z "$(warns)" ]; then
    ok "5 added requirement -> added=1, scope growth, no warning"
else bad "5: [$LINE] $(warns)"; fi

spec a c; run
ID_B="cc:aaaa000b:$(printf 'Scenario b' | "${SHA[@]}" | cut -c1-8)"
if [ "$(warns)" = "warn:centicolon-ratchet:lost=1:vanished=1,down=0:$ID_B" ] && grep -q ' retired=0 lost=1 ' <<<"$LINE"; then
    ok "6 requirement removed with NO record -> lost=1 (vanished), warned"
else bad "6: [$LINE] $(warns)"; fi

mkdir -p "$H/openspec/changes/drop-c"; printf 'Removes requirement aaaa000c (Req c).\n' >"$H/openspec/changes/drop-c/proposal.md"
spec a; run
if grep -q ' retired=1 lost=0 .* regime=retired (advisory)$' <<<"$LINE" && [ -z "$(warns)" ]; then
    ok "7 requirement removed WITH an openspec/changes record -> retired=1, no warning"
else bad "7: [$LINE] $(warns)"; fi

mkdir -p "$H/openspec/specs/beta"
printf 'status: active\n\n### Requirement: Beta one\n<!-- req-id: bbbb0001 -->\n\n#### Scenario: B1\n\n#### Scenario: B2\n' >"$H/openspec/specs/beta/spec.md"
printf -- "- spec_id: beta\n  status: active\n  litmus_tests: []\n" >>"$H/openspec/litmus-bindings.yaml"
run
printf 'status: obsolete\n' >"$H/openspec/specs/beta/spec.md"
awk '{print} /^- spec_id: beta$/ {print "  tombstone: superseded:alpha"}' "$H/openspec/litmus-bindings.yaml" >"$WORK/reg" && mv "$WORK/reg" "$H/openspec/litmus-bindings.yaml"
run
if grep -q ' retired=2 lost=0 .* regime=retired (advisory)$' <<<"$LINE" && [ -z "$(warns)" ]; then
    ok "8 spec obsoleted with a registry tombstone -> retired=2, no warning"
else bad "8: [$LINE] $(warns)"; fi

rm -rf "$H/openspec/specs"; run
if [ "$RC" -eq 0 ] && grep -q '^centicolon: blocked:' <<<"$LINE" && ! grep -q 'R=0' <<<"$LINE"; then
    ok "9 no corpus -> blocked, exit 0, never R=0"
else bad "9: rc=$RC [$LINE]"; fi

if [ "$fail" -eq 0 ]; then echo "ok:centicolon-ratchet:$pass"; exit 0; fi
echo "fail:centicolon-ratchet:$fail failed, $pass passed"; exit 1
