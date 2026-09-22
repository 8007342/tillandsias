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

# ── ARM 7 (LIVE) — the door's own verdict adds up when it can be run ────────
# EVERY ARM ABOVE READS SOURCE. This one runs the thing, and is the only arm
# that can catch a counter incremented in the wrong branch. It is a NAMED SKIP
# where the door cannot run, because a host that cannot open the door learns
# nothing by pretending it did (965-sxec) — which is this order's own subject.
if ! command -v setsid >/dev/null 2>&1; then
    echo "  [SKIP] arm7:live-run:no-setsid — this platform cannot start the door (1352-vmbc); the source arms above still hold"
elif [ "${TILLANDSIAS_PREFLIGHT_LIVE:-0}" != "1" ]; then
    echo "  [SKIP] arm7:live-run:not-requested — set TILLANDSIAS_PREFLIGHT_LIVE=1 to run the real door (minutes, not seconds)"
else
    out="$(cd "$ROOT" && ./build.sh --preflight 2>&1)"
    verdict="$(grep -aoE '^(ok|partial|refused):preflight:ran=.*' <<<"$out" | tail -1)"
    if [ -z "$verdict" ]; then
        bad "arm7:the door printed no category verdict"
    else
        _get() { grep -oE "$1=[0-9]+" <<<"$verdict" | head -1 | tr -cd '0-9'; }
        _s=0
        for k in ran declared-skip skipped-by-deadline could-not-run refused; do
            _v="$(_get "$k")"; _s=$(( _s + ${_v:-0} ))
        done
        _stated="$(_get sum)"
        if [ -z "$_stated" ]; then
            bad "arm7:the verdict states no sum: $verdict"
        elif [ "$_s" -ne "$_stated" ]; then
            bad "arm7:the categories do not add up to the stated sum ($_s vs $_stated): $verdict"
        else
            ok "arm7:the live door's categories add up to its own stated sum ($_stated)"
        fi
    fi
fi

if [ "$fail" -gt 0 ]; then
    echo "violation:preflight-verdict-categories:$fail/$((pass+fail))"
    exit 1
fi
echo "ok:preflight-verdict-categories:$pass/$pass"
