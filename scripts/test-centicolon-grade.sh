#!/usr/bin/env bash
# @trace order:1395-88tp
#
# test-centicolon-grade.sh — the CentiColon grader earns positively_tested only
# from an ENFORCED, REACHABLE, tiered litmus step naming the req-id AND a green
# results record for that file's exact bytes. Everything else stays traced (or
# declared) with a named reason.
#
# A hermetic corpus (extractor input, litmus files, a bindings registry and a
# results stream) run through scripts/centicolon-grade.sh:
#   A  requirement:-keyed step, assert key, bound, pre-build instant, green
#      record for its digest            -> positively_tested (reason green)
#   B  same, but the file is UNBOUND    -> traced, inert:unbound
#   C  same, but `phase: retired`       -> traced, inert:retired
#   D  step with only expected_behavior -> traced, unenforced
#   E  a requirement: key naming a req-id the extractor did not emit -> refused
#      BY NAME (warn line; the grade is still computed so R stays printable)
#   Z  zero resolved keys over a non-empty litmus corpus -> refused, never ok:0
# MUTATION arms on A: its record deleted -> traced (unrun); a record for OTHER
# bytes -> traced (unrun); a later `fail` for the same bytes -> traced (failed);
# a green record run against an older spec.md -> traced (spec-changed).
# Pre-fix every arm FAILS: the grader and its wrapper do not exist.

set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
GRADE="$ROOT/scripts/centicolon-grade.sh"
[ -f "$GRADE" ] || { echo "fail:centicolon-grade:no-wrapper:$GRADE"; exit 1; }

cd "$ROOT" || exit 1
. "$ROOT/scripts/plan-binary-probe.sh"
if ! PLAN="$(resolve_plan_binary)"; then echo "skip:centicolon-grade:no-runnable-plan-binary"; exit 0; fi
if ! grep -qx 'predicate' <<<"$("$PLAN" capabilities 2>/dev/null)"; then
    echo "skip:centicolon-grade:plan-binary-lacks-predicate-verb:$PLAN"; exit 0
fi
# JSON reads go through the plan binary (`json get`, 1375-rn9b), not jq.
jg() { "$PLAN" json get -r "$1" - <<<"$2" 2>/dev/null | tr -d '\r'; }
# Absolute before export: the wrapper cds into a hermetic root (1380-u7sq).
case "$PLAN" in /*) ;; *) PLAN="$ROOT/${PLAN#./}" ;; esac
export TILLANDSIAS_PLAN_BIN="$PLAN"

pass=0; fail=0
# Built from a variable so check-litmus-pin-claims.sh (721-77yu) does not read
# the hermetic names as claims about real litmus tests.
LP="litmus"
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }
if command -v sha256sum >/dev/null 2>&1; then SHA=(sha256sum); else SHA=(shasum -a 256); fi
digest() { "${SHA[@]}" <"$1" | cut -c1-64; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ccg.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# corpus <root> <with-keys:yes|no>
corpus() {
    local r="$1" keys="$2"
    mkdir -p "$r/openspec/specs/alpha" "$r/openspec/litmus-tests"
    {
        printf 'status: active\n\n'
        for x in a b c d; do
            printf '### Requirement: Req %s\n<!-- req-id: aaaa000%s -->\n\n#### Scenario: Scenario %s\n\n' "$x" "$x" "$x"
        done
    } >"$r/openspec/specs/alpha/spec.md"
    printf "version: '1.0'\nspecs:\n- spec_id: alpha\n  status: active\n  litmus_tests:\n  - $LP:a-file\n  - $LP:c-file\n  - $LP:d-file\n  - $LP:e-file\n" \
        >"$r/openspec/litmus-bindings.yaml"
    : >"$r/openspec/litmus-tests/unbound-grandfathered.txt"
    # lt <file> <name> <phase> <req> <assert yes|no>
    lt() {
        {
            printf 'name: %s\nspec: alpha\nphase: %s\nsize: instant\ncritical_path:\n  - step: "the step"\n' "$2" "$3"
            [ "$keys" = yes ] && printf '    requirement: %s\n' "$4"
            printf '    command: "true"\n'
            if [ "$5" = yes ]; then printf '    assert_exit: 0\n'; else printf '    expected_behavior: "it works"\n'; fi
        } >"$r/openspec/litmus-tests/$1.yaml"
    }
    lt litmus-a $LP:a-file pre-build aaaa000a yes
    lt litmus-b $LP:b-file pre-build aaaa000b yes
    lt litmus-c $LP:c-file retired   aaaa000c yes
    lt litmus-d $LP:d-file pre-build aaaa000d no
    lt litmus-e $LP:e-file pre-build ffff9999 yes
}
rec() { # <status> <digest> <ts> [spec_digest]
    printf '{"ts":"%s","host":"fixture","step":"%s:a-file","phase":"pre-build","duration_ms":1,"exit":0,"status":"%s","digest":"%s","regime":"linux","spec":"alpha","spec_digest":"%s"}\n' "$3" "$LP" "$1" "$2" "${4:-$DS}"
}
# grade <root> <log> — sets OUT (stdout) and G (grade.json content)
grade() {
    OUT="$(TILLANDSIAS_REPO_ROOT="$1" TILLANDSIAS_TIMING_LOG="$2" bash "$GRADE" 2>&1)"
    G="$(cat "$1/target/centicolon/grade.json" 2>/dev/null)"
}
# "<req-id> <state>/<reason>" per obligation, then pick one — plain gets, no
# select/interpolation (the jq-retirement subset, 1375-tsfu).
state_of() {
    paste -d' ' <(jg '.obligations[].req_id' "$G") <(jg '.obligations[].state' "$G") <(jg '.obligations[].reason' "$G") \
        | awk -v r="aaaa000$1" '$1 == r {print $2 "/" $3; exit}'
}

H="$WORK/h"; corpus "$H" yes
DA="$(digest "$H/openspec/litmus-tests/litmus-a.yaml")"
DS="$(digest "$H/openspec/specs/alpha/spec.md")"
rec pass "$DA" 2026-09-26T01:00:00Z >"$WORK/green.jsonl"
grade "$H" "$WORK/green.jsonl"

[ "$(state_of a)" = "positively_tested/green" ] && ok "A enforced+reachable+pre-build with a green record for its digest -> positively_tested" || bad "A: $(state_of a) :: $(tail -1 <<<"$OUT")"
[ "$(state_of b)" = "traced/inert:unbound" ] && ok "B unbound file -> traced inert:unbound" || bad "B: $(state_of b)"
[ "$(state_of c)" = "traced/inert:retired" ] && ok "C retired file -> traced inert:retired" || bad "C: $(state_of c)"
[ "$(state_of d)" = "traced/unenforced" ] && ok "D expected_behavior only -> traced unenforced" || bad "D: $(state_of d)"
if grep -q '^warn:centicolon-grade:violation:centicolon-requirement-unresolved:openspec/litmus-tests/litmus-e.yaml:1:ffff9999$' <<<"$OUT"; then
    ok "E unknown req-id refused by name (warn line), grade still computed"
else bad "E: $(grep '^warn:' <<<"$OUT" | head -2)"; fi
if grep -q '^ok:centicolon-grade:R=3 satisfied=1 denominator=4 declared=0 traced=3 positively_tested=1 records=1$' <<<"$OUT"; then
    ok "verdict line R=3 satisfied=1 denominator=4"
else bad "verdict: $(tail -1 <<<"$OUT")"; fi

# ── mutation arms on A ───────────────────────────────────────────────────────
: >"$WORK/empty.jsonl"; grade "$H" "$WORK/empty.jsonl"
[ "$(state_of a)" = "traced/unrun" ] && ok "MUTATION: A's record deleted -> traced (unrun)" || bad "MUTATION delete: $(state_of a)"
rec pass "$(printf 'other bytes' | "${SHA[@]}" | cut -c1-64)" 2026-09-26T01:00:00Z >"$WORK/other.jsonl"; grade "$H" "$WORK/other.jsonl"
[ "$(state_of a)" = "traced/unrun" ] && ok "MUTATION: a green record for OTHER bytes earns nothing" || bad "MUTATION digest: $(state_of a)"
{ rec pass "$DA" 2026-09-26T01:00:00Z; rec fail "$DA" 2026-09-26T02:00:00Z; } >"$WORK/later-fail.jsonl"; grade "$H" "$WORK/later-fail.jsonl"
[ "$(state_of a)" = "traced/failed" ] && ok "MUTATION: a later fail for the same bytes un-earns A" || bad "MUTATION later fail: $(state_of a)"

rec pass "$DA" 2026-09-26T01:00:00Z "$(printf 'an older spec.md' | "${SHA[@]}" | cut -c1-64)" >"$WORK/old-spec.jsonl"; grade "$H" "$WORK/old-spec.jsonl"
[ "$(state_of a)" = "traced/spec-changed" ] && ok "MUTATION: a green record run against an OLDER spec.md earns nothing (spec-changed)" || bad "MUTATION spec: $(state_of a)"

# ── Z: zero resolved keys over a non-empty corpus ────────────────────────────
Z="$WORK/z"; corpus "$Z" no; grade "$Z" "$WORK/empty.jsonl"
if grep -q '^warn:centicolon-grade:zero-resolved-requirement-keys:files=5$' <<<"$OUT" && grep -q '^ok:centicolon-grade:R=4 satisfied=0 denominator=4 declared=4 ' <<<"$OUT"; then
    ok "Z zero resolved keys -> refused by name, R still printed (4 declared)"
else bad "Z: $(grep -E '^(warn|ok|blocked):' <<<"$OUT" | head -3)"; fi

if [ "$fail" -eq 0 ]; then echo "ok:centicolon-grade:$pass"; exit 0; fi
echo "fail:centicolon-grade:$fail failed, $pass passed"; exit 1
