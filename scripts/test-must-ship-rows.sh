#!/usr/bin/env bash
# @trace spec:versioning, spec:ci-release
#
# test-must-ship-rows.sh — falsify scripts/check-must-ship-rows.sh.
#
# Order 1218-25z3.
#
# REGIME: hermetic where it can be, and REAL-HISTORY where that is the whole
# point. Arms 1-6 build throwaway indexes and throwaway git repos under a temp
# dir. Arms 7-8 assert against this repository's OWN history, because the row's
# evidence IS a historical fact — 1211-34v6 is on trunk and absent from the tag
# that shipped after it — and a fixture that only ever saw synthetic commits
# could not tell whether the subject-matching rule works on real subjects.
#
# NO ABSOLUTE TIMESTAMP APPEARS HERE. The verdicts are a function of (marked
# rows, commit subjects reachable from a ref) and nothing else; pinning a date
# would assert about something the subject never reads. The tag name v56.9.13.1
# is a REF, not a time, and arm 8 skips rather than fails if it is absent, so a
# fresh clone without tags reports honestly instead of reding.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2
GUARD="scripts/check-must-ship-rows.sh"

pass=0; fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }
[ -f "$GUARD" ] || { echo "FAIL: $GUARD absent"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "  skip: jq absent — this fixture needs it"; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/must-ship-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

echo "ARM 1: a clean cut prints ONE line and does not become noise (negative control)"
out1="$(bash "$GUARD" --cut-ref HEAD 2>/dev/null)"; rc1=$?
n1="$(printf '%s\n' "$out1" | /usr/bin/grep -c .)"
if [ "$rc1" -eq 0 ] && [ "$n1" -eq 1 ] && printf '%s' "$out1" | /usr/bin/grep -qE '^(ok|advisory):must-ship:[0-9]+ outstanding of [0-9]+ marked$'; then
    ok "stdout is exactly one verdict line in the closed grammar, rc=0"
else
    bad "expected one grammar line at rc=0; got rc=$rc1 lines=$n1 [$out1]"
fi

echo "ARM 2: the advisory NEVER exits non-zero, on any ref"
allrc=0
for r in HEAD HEAD~1 refs/heads/definitely-no-such-ref; do
    bash "$GUARD" --cut-ref "$r" >/dev/null 2>&1 || allrc=$?
done
[ "$allrc" -eq 0 ] && ok "every verdict exits 0 — it reports, it does not block" \
                   || bad "an arm exited $allrc; a blocking cut gate gets bypassed, not obeyed (748-tkjx)"

echo "ARM 3: an unresolvable cut ref SKIPS rather than reporting a clean cut"
out3="$(bash "$GUARD" --cut-ref refs/heads/definitely-no-such-ref 2>/dev/null)"
printf '%s' "$out3" | /usr/bin/grep -q '^skipped:must-ship:no-cut-ref' \
    && ok "unresolvable ref reports skipped:, never ok: (785-sqe6)" \
    || bad "expected skipped:no-cut-ref; got [$out3]"

echo "ARM 4: THE STALE-BINARY PROBE — a binary that cannot see the field must not report zero."
# The dangerous failure: a tillandsias-plan predating 1218-25z3 projects no
# must_ship at all, so every row reads unmarked and the verdict is a confident
# 'ok: 0 of 0'. A zero that means "cannot see" must never print as "none".
cat > "$TMP/fake-plan" <<'FAKE'
#!/usr/bin/env bash
# A binary with no must_ship in its projection — i.e. every version before this order.
for a in "$@"; do [ "$a" = "--json" ] && { echo '[{"order":"1","packet_id":"p","status":"ready"}]'; exit 0; }; done
exit 0
FAKE
chmod +x "$TMP/fake-plan"
out4="$(PATH="$TMP:$PATH" TILLANDSIAS_PLAN_BIN="$TMP/fake-plan" bash "$GUARD" --cut-ref HEAD 2>/dev/null)"
if printf '%s' "$out4" | /usr/bin/grep -q '^skipped:must-ship:stale-plan-binary'; then
    ok "a binary that cannot project must_ship reports stale-plan-binary, not a clean zero"
elif printf '%s' "$out4" | /usr/bin/grep -q '^ok:must-ship:0 outstanding of 0 marked'; then
    bad "a binary that CANNOT SEE the field reported a clean zero — the answer that looks like success"
else
    echo "  skip: the probe could not be pointed at a fake binary here ($out4)"
fi

echo "ARM 5: a MENTION is not a fix — driving the GUARD, not a copy of its rule"
# THIS ARM USED TO RE-IMPLEMENT THE MATCHING RULE INSIDE THE FIXTURE and assert
# on its own awk. Measured: mutating the GUARD to count naive --grep mentions
# left this fixture 10/10 — a test asserting about its own copy cannot see the
# subject change. It now builds an ORPHAN commit whose SUBJECT names an
# unrelated order while its BODY mentions a marked one, points the real guard at
# it, and requires OUTSTANDING. Naive mention-counting reports it present.
_probe_ref="refs/tmp/must-ship-fixture-probe"
_empty_tree="$(git hash-object -t tree /dev/null)"
_mention_commit="$(git commit-tree "$_empty_tree" -m "plan(9998-aaaa): a commit whose body mentions 1211-34v6 without fixing it

this body names 1211-34v6 at length and fixes nothing" 2>/dev/null)"
if [ -n "${_mention_commit:-}" ]; then
    git update-ref "$_probe_ref" "$_mention_commit"
    out5="$(bash "$GUARD" --cut-ref "$_probe_ref" 2>&1)"
    git update-ref -d "$_probe_ref" 2>/dev/null || true
    if printf '%s' "$out5" | /usr/bin/grep -q "OUTSTANDING  1211-34v6"; then
        ok "a body mention does not count as the fix (the guard reports OUTSTANDING)"
    elif printf '%s' "$out5" | /usr/bin/grep -q "present      1211-34v6"; then
        bad "the guard counted a MENTION as a fix — a row would report shipped because someone discussed it"
    else
        bad "the guard said neither present nor outstanding for 1211-34v6: [$(printf '%s' "$out5" | head -2)]"
    fi
else
    echo "  skip: could not synthesise a probe commit"
fi

echo "ARM 6: a real fix SUBJECT is counted — same guard, same probe shape"
_fix_commit="$(git commit-tree "$_empty_tree" -m "fix(1211-34v6): a synthetic subject naming the order" 2>/dev/null)"
if [ -n "${_fix_commit:-}" ]; then
    git update-ref "$_probe_ref" "$_fix_commit"
    out6="$(bash "$GUARD" --cut-ref "$_probe_ref" 2>&1)"
    git update-ref -d "$_probe_ref" 2>/dev/null || true
    printf '%s' "$out6" | /usr/bin/grep -q "present      1211-34v6" \
        && ok "a type(order): subject counts as the fix" \
        || bad "a real fix subject was not counted: [$(printf '%s' "$out6" | head -2)]"
else
    echo "  skip: could not synthesise a probe commit"
fi

echo "ARM 7: REAL HISTORY — 1211-34v6's fix is reachable from this branch"
real="$(git log --format='%s' HEAD | awk '$0 ~ /^[a-z]+\([^)]*1211-34v6[^)]*\)/ {n++} END{print n+0}')"
[ "${real:-0}" -ge 1 ] && ok "found $real subject-anchored commit(s) for 1211-34v6 on HEAD" \
                       || bad "1211-34v6's fix is not reachable from HEAD — the rule does not work on real subjects"

echo "ARM 8: REAL HISTORY — and it is ABSENT from the tag that shipped after it"
# This is the row's own measured instance: 1211-34v6 landed on trunk, was not in
# the following cut, and the promoted stable therefore still misdirects.
if git rev-parse --verify -q v56.9.13.1 >/dev/null 2>&1; then
    intag="$(git log --format='%s' v56.9.13.1 | awk '$0 ~ /^[a-z]+\([^)]*1211-34v6[^)]*\)/ {n++} END{print n+0}')"
    [ "${intag:-0}" -eq 0 ] && ok "1211-34v6 is absent from v56.9.13.1 — the miss this row exists for is reproduced" \
                            || bad "expected 0 subject matches in the tag, got $intag"
else
    echo "  skip: tag v56.9.13.1 not present in this clone — real-history arm not run"
fi

echo "ARM 11: an UNKNOWN ARGUMENT is refused, not silently discarded"
# FOUND BY A PEER HITTING IT, not by review. The arg loop used to end
# `*) shift ;;`, so a positional ref or a mistyped flag was dropped and the run
# proceeded against HEAD — printing a confident clean verdict about a tree
# nobody asked about. The caller here is a release cutter typing a flag from
# memory; a wrong answer that looks right is the one failure this instrument
# must not have, since it is the instrument's own subject.
for _bad in "v56.9.13.1" "--against v56.9.13.1" "--marker"; do
    # shellcheck disable=SC2086
    _out="$(bash "$GUARD" $_bad 2>/dev/null)"; _rc=$?
    if printf '%s' "$_out" | /usr/bin/grep -qE '^(ok|advisory):must-ship:'; then
        bad "invocation [$_bad] printed a VERDICT about a tree nobody asked for: $_out"
    elif [ "$_rc" -ne 0 ]; then
        bad "invocation [$_bad] exited $_rc — the advisory must never be able to block a cut"
    else
        ok "invocation [$_bad] refused without printing a verdict, rc=0"
    fi
done

echo "ARM 9: the guard is BOUND — the release path invokes it"
if /usr/bin/grep -q 'check-must-ship-rows.sh' scripts/release-preflight.sh; then
    ok "scripts/release-preflight.sh invokes the advisory"
else
    bad "nothing in the release path invokes it — it is an orphan and protects nothing"
fi

echo "ARM 10: release-preflight's ONE-LINE stdout contract survives the addition"
pf="$(bash scripts/release-preflight.sh 2>/dev/null | /usr/bin/grep -c .)"
[ "$pf" -eq 1 ] && ok "release-preflight still prints exactly one line on stdout" \
                || bad "release-preflight now prints $pf stdout lines; its grammar is one line and nothing else"

echo
echo "must-ship-rows: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ] || exit 1
exit 0
