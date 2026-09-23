#!/usr/bin/env bash
# @trace order:1353-ryhq, spec:ci-release
#
# THE PREFLIGHT VERDICT DISTINGUISHES WHAT RAN FROM WHAT DID NOT, AND NEVER
# VOUCHES FOR A GUARD THAT DID NOT EXAMINE THE TREE.
#
# WHY, measured on three hosts in one night (2026-09-22):
#   yolanda-windows  ok:preflight:ran=68 skipped=31 wall=241s, exit 0 — and
#                    TWENTY of those 31 were guards cut off by the 5s deadline,
#                    each missing it by one or two seconds. `ok:` and a zero
#                    exit, for a door that covered about two thirds.
#   macneo           ran=0 skipped=3 failed=110 — 110 guards booked as
#                    REFUSALS when the thing that failed was one absent binary
#                    (exec: setsid: not found). The guards were blameless and
#                    the tree was never examined.
#   forge            refused: printed for guards that never executed, because
#                    the checkout tmpfs filled (1349-53h6).
# Three platforms, three symptoms, one defect: the verdict could not say
# whether a guard had answered.
#
# NO ARM ASSERTS A GUARD COUNT. The roster differs by checkout — two Macs
# measured the same defect as failed=108 and failed=110 minutes apart — so the
# arms assert the CATEGORIES and their SUM, which is true on every host.
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "refused:preflight-verdict-categories:not-bash"; exit 2; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  [OK]   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  [FAIL] %s\n' "$1"; }

[ -f "$BUILD" ] || { echo "refused:preflight-verdict-categories:no-build-sh"; exit 1; }
src="$(cat "$BUILD")"

# ── ARM 1 — every category appears in the verdict line ──────────────────────
missing=""
for c in "ran=" "declared-skip=" "skipped-by-deadline=" "could-not-run=" "refused="; do
    grep -q -- "$c" <<<"$src" || missing="$missing $c"
done
if [ -n "$missing" ]; then
    bad "arm1:the verdict does not name every category; missing:$missing"
else
    ok "arm1:the verdict names ran, declared-skip, skipped-by-deadline, could-not-run and refused"
fi

# ── ARM 2 — the door refuses when its own categories do not add up ──────────
# THE ARM THAT MAKES THE OTHERS MEAN ANYTHING. Categories a reader cannot check
# are a vocabulary, not an accounting; a guard dropped between two branches
# would be invisible in exactly the way this row exists to stop.
if grep -q 'accounting-mismatch' <<<"$src" && grep -q '_pf_sum' <<<"$src"; then
    ok "arm2:a category set that does not sum to the roster refuses instead of reporting"
else
    bad "arm2:nothing checks that the categories account for every enumerated guard"
fi

# ── ARM 3 — ok: is unreachable while a guard is unanswered ──────────────────
# THE ARM THE PRE-FIX CODE FAILS, and the one that fixes the Windows reader.
if grep -q 'partial:preflight:' <<<"$src" && grep -q '_pf_unanswered' <<<"$src"; then
    ok "arm3:a run with unanswered guards reports partial:, not ok:"
else
    bad "arm3:a run that left guards unanswered can still print ok: — the defect this order names"
fi

# ── ARM 4 — a DECLARED skip is not counted as unanswered ────────────────────
# The complement of arm 3, and load-bearing: without it the cheapest way to
# pass arm 3 is to treat every skip as a gap, which would make `skip:not-darwin`
# on a Linux host read as missing coverage and teach hosts to suppress named
# skips — the opposite of 965-sxec.
_una="$(grep -n '_pf_unanswered=' <<<"$src" | head -1)"
if [ -z "$_una" ]; then
    bad "arm4:no unanswered tally exists to check"
elif grep -q '_pf_declskip' <<<"$_una"; then
    bad "arm4:a guard that declared its own skip is being counted as unanswered; a named skip is an observation, not a gap (965-sxec)"
else
    ok "arm4:a declared skip is an observation, not an unanswered guard"
fi

# ── ARM 5 — a guard the runner could not START is not booked as a refusal ───
if grep -q 'could-not-run:preflight:' <<<"$src" && grep -q '_pf_cantrun' <<<"$src"; then
    ok "arm5:a guard the runner could not start is could-not-run, not refused"
else
    bad "arm5:a guard that never executed is still reported as having refused the tree"
fi

# ── ARM 6 — no fixed guard count is asserted ────────────────────────────────
# The roster differs by checkout (108 vs 110 on two Macs, same defect, minutes
# apart). A hardcoded expectation would be red on one Mac and green on another.
if grep -nE '(ran|refused|skipped[a-z-]*|could-not-run|declared-skip)[[:space:]]*[!=]=[[:space:]]*[0-9]+' <<<"$src" | grep -qv '_pf_sum\|_pf_unanswered\|_pf_failed\|-gt 0\|-ne 0'; then
    bad "arm6:something compares a category against a fixed number; the roster differs by checkout"
else
    ok "arm6:no arm or branch asserts a fixed guard count"
fi

# ── ARM 7 — 1352-vmbc's isolation= field survives on EVERY verdict line ────
# THIS ARM PROTECTS ANOTHER ORDER'S EVIDENCE. 1352-vmbc added isolation=session
# / isolation=none-no-setsid because a run without setsid keeps every deadline
# but loses process-GROUP signalling, so a guard leaving background children can
# outlive its deadline — a real difference in what the run PROVED. Their reason
# for pinning it on BOTH lines applies to the two lines this order added: a
# green run must not be able to hide a degraded one. These two orders rewrote
# the same summary in the same week and the merge could have dropped the field
# silently, which is why it is asserted here rather than trusted.
# SUMMARY lines only, identified by the counts they carry — NOT every line
# matching the token. The per-guard `refused:preflight:<name>` and the partial
# detail line are not summaries and correctly carry no isolation; a first draft
# of this arm flagged both. And the count is asserted, so the arm cannot pass
# by matching nothing: a selector that stops matching is a guard that stops
# guarding, silently.
_iso_missing=""
_iso_seen=0
while IFS= read -r _line; do
    [ -n "$_line" ] || continue
    _iso_seen=$((_iso_seen + 1))
    grep -q '_pf_iso' <<<"$_line" || _iso_missing="$_iso_missing ${_line%%:*}"
done <<<"$(grep -nE 'echo "(ok|partial|refused):preflight[^"]*\$_pf_counts' <<<"$src")"
if [ "$_iso_seen" -lt 3 ]; then
    bad "arm7:found $_iso_seen summary verdict line(s), expected at least 3 (ok/partial/refused) — the selector has gone stale"
elif [ -n "$_iso_missing" ]; then
    bad "arm7:a summary verdict line does not carry isolation= (build.sh line(s):$_iso_missing) — 1352-vmbc's evidence"
else
    ok "arm7:all $_iso_seen summary verdict lines carry 1352-vmbc's isolation= field"
fi

# ── ARM 8 — AN OUTPUT CARRYING BOTH TOKENS IS A DECLARED SKIP ──────────────
# THE ARM THAT WAS MISSING, and its absence is the finding. When could-not-run
# was first added to this runner it was placed BEFORE the ^skip: arm, which
# demoted a properly named skip into the unanswered bucket — and every other arm
# here stayed green, because none of them asserted the PRECEDENCE. The fix and
# its exact inverse both passed.
#
# MEASURED 2026-09-22 on the merged tree: after 1354-apns,
# check-gate-memory-floor prints BOTH `could-not-run:gate-memory:no-meminfo:...`
# and `skip:gate-memory:no-meminfo`, and it RAN. Same host, same tree, only the
# arm order differing:
#   could-not-run first  declared-skip=4 could-not-run=1  -> 14 unvouched
#   ^skip: first         declared-skip=5 could-not-run=0  -> 13 unvouched
# A guard that ran and gave its considered statement has not left a gap
# (965-sxec), so the named skip wins and could-not-run is for a guard that says
# ONLY that. Without this arm a later reorder silently demotes every honest skip
# in the corpus and nothing goes red.
# THE SELECTORS DO NOT KEY ON if/elif, and that is not cosmetic. The first form
# required `if` on the skip arm and `elif` on the could-not-run arm — exactly
# the incidental detail the mutation changes — so inverting the order made BOTH
# selectors match nothing and the arm red with "the selector has gone stale"
# instead of naming the wrong order. It red, but for the wrong reason, which is
# the defect macbookair recorded in their own needle hours earlier. Keyed on the
# grep pattern alone, the mutation now names what it actually did.
_skip_ln="$(grep -nE "^[[:space:]]*(el)?if grep -qE '\^skip:'" <<<"$src" | head -1 | cut -d: -f1)"
_cnr_ln="$(grep -nE "^[[:space:]]*(el)?if grep -qE '\^could-not-run:'" <<<"$src" | head -1 | cut -d: -f1)"
if [ -z "$_skip_ln" ] || [ -z "$_cnr_ln" ]; then
    bad "arm8:could not find both arms to compare (skip=${_skip_ln:-none} could-not-run=${_cnr_ln:-none}) — the selector has gone stale, which is not the same as the order being right"
elif [ "$_skip_ln" -ge "$_cnr_ln" ]; then
    bad "arm8:the could-not-run arm (line $_cnr_ln) precedes or replaces the named-skip arm (line $_skip_ln); a guard printing BOTH tokens would be scored a gap when it ran and said so (965-sxec)"
else
    ok "arm8:a guard printing both tokens scores as a declared skip — the named-skip arm (line $_skip_ln) wins over could-not-run (line $_cnr_ln)"
fi

# ── ARM 9 (LIVE) — the door's own verdict adds up when it can be run ────────
# EVERY ARM ABOVE READS SOURCE. This one runs the thing, and is the only arm
# that can catch a counter incremented in the wrong branch. It is a NAMED SKIP
# where the door cannot run, because a host that cannot open the door learns
# nothing by pretending it did (965-sxec) — which is this order's own subject.
# THE setsid SKIP IS GONE, DELIBERATELY. Before 1352-vmbc this arm skipped where
# setsid was absent, because the door could not start a single guard there. That
# order makes the door run WITHOUT setsid and say so, so the old skip condition
# describes a state that no longer exists — and a skip that outlives its reason
# is a guard quietly not running (885-92iu). Gated only on the opt-in now,
# because the real door takes minutes and this fixture is size: instant.
if [ "${TILLANDSIAS_PREFLIGHT_LIVE:-0}" != "1" ]; then
    echo "  [SKIP] arm9:live-run:not-requested — set TILLANDSIAS_PREFLIGHT_LIVE=1 to run the real door (minutes, not seconds)"
else
    out="$(cd "$ROOT" && ./build.sh --preflight 2>&1)"
    verdict="$(grep -aoE '^(ok|partial|refused):preflight:ran=.*' <<<"$out" | tail -1)"
    if [ -z "$verdict" ]; then
        bad "arm9:the door printed no category verdict"
    else
        _get() { grep -oE "$1=[0-9]+" <<<"$verdict" | head -1 | tr -cd '0-9'; }
        _s=0
        for k in ran declared-skip skipped-by-deadline could-not-run refused; do
            _v="$(_get "$k")"; _s=$(( _s + ${_v:-0} ))
        done
        _stated="$(_get sum)"
        if [ -z "$_stated" ]; then
            bad "arm9:the verdict states no sum: $verdict"
        elif [ "$_s" -ne "$_stated" ]; then
            bad "arm9:the categories do not add up to the stated sum ($_s vs $_stated): $verdict"
        elif ! grep -q 'isolation=' <<<"$verdict"; then
            bad "arm9:the live verdict carries no isolation= field: $verdict"
        else
            ok "arm9:the live door's categories add up to its own stated sum ($_stated), isolation present"
        fi
    fi
fi

if [ "$fail" -gt 0 ]; then
    echo "violation:preflight-verdict-categories:$fail/$((pass+fail))"
    exit 1
fi
echo "ok:preflight-verdict-categories:$pass/$pass"
