#!/usr/bin/env bash
# @trace order:1130-i6xj, spec:ci-release
#
# test-portability-idioms.sh — the closure fixture for 1130-i6xj.
#
# BOTH HALVES, and the second half is the one that makes it mean anything. An
# advisory that names nothing proves nothing; an advisory that cannot be shown
# to have named a REAL defect is indistinguishable from one whose patterns
# never match. So this asserts the guard catches the 2026-09-12 defects on the
# trees that CARRIED them, and does not flag those same files once fixed.
#
# WHY THE CLOSURE IS NOT "ZERO ON THE FIXED TREE", which is how it was first
# worded. The guard's first run found 35 GENUINE pre-existing instances across
# the repo — stat -c ×14, sed -i ×13, date -d ×5, readlink -f ×2 — none related
# to that night. "Zero" assumed the night's three were the only ones and they
# were not. Demanding zero would make this un-passable until an unrelated
# 35-item backlog is cleared, which is how a closure becomes a thing people
# delete. The meaningful assertion is PER-INSTANCE.
#
# The pre-fix arms read real blobs out of git rather than a synthetic corpus: a
# fixture that writes its own bad input proves the pattern matches that input,
# not that it matches what shipped.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
GUARD="scripts/check-portability-idioms.sh"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

OUT="$(bash "$GUARD" 2>&1)"
RC=$?

# ── the advisory contract ──────────────────────────────────────────────────
# ALWAYS 0. Four of the defects this reports each froze a platform; a blocking
# check here would cost more than it catches.
[ "$RC" -eq 0 ] && ok "advisory exits 0 (never a gate)" \
                || bad "advisory exited $RC — it must never block"

case "$(printf '%s\n' "$OUT" | head -1)" in
    "portability-idioms: silent-degrade="*" loud-fail="*)
        ok "counted verdict, severity-split, silent class first" ;;
    *)  bad "verdict line missing or reshaped" ;;
esac

# ── HALF 1: it catches the real defects on the trees that carried them ─────
_pre_fix_has() { # _pre_fix_has <commit> <path> <pattern> <label>
    local blob
    blob="$(git show "$1^:$2" 2>/dev/null)" || { ok "$4 (skip: blob unavailable)"; return; }
    if printf '%s\n' "$blob" | awk 'NF && $1 !~ /^#/' | grep -q "$3"; then
        ok "$4"
    else
        bad "$4 — the control this rests on is gone; re-pin the commit"
    fi
}

_pre_fix_has 5b27fea61 scripts/audit-guard-activation.sh \
    'grep -Rl' "HALF 1: pre-fix tree carried grep -Rl in CODE (1087-h2z9)"
_pre_fix_has 737bd10c5 scripts/test-plan-binary-freshness.sh \
    'touch -t 202609120600' "HALF 1: pre-fix tree carried the literal that expired (1129-4su6)"
_pre_fix_has 26d007bf4 scripts/test-gate-stamp-does-not-memoize-guard-owned-paths.sh \
    "sed -i '/\^plan_digest" "HALF 1: pre-fix tree carried GNU-only sed -i (1127-waxf)"

# The recency discriminator must cut BOTH ways: 202609120600 was the bomb, and
# 202609041215 on an adjacent line is a legitimate deliberately-old stamp.
_pre_fix_has 737bd10c5 scripts/test-plan-binary-freshness.sh \
    'touch -t 202609041215' "HALF 1: and carried legitimate OLD stamps alongside it"

# ── HALF 2: it does not flag those same files now ──────────────────────────
for f in audit-guard-activation.sh check-cheatsheet-refs.sh \
         test-gate-stamp-does-not-memoize-guard-owned-paths.sh \
         test-plan-binary-freshness.sh; do
    if printf '%s\n' "$OUT" | grep -q "$f"; then
        bad "HALF 2: $f still flagged after its fix"
    else
        ok "HALF 2: $f clean"
    fi
done

# ── false-accusation arms ──────────────────────────────────────────────────
# Every one of these was a REAL false positive in an earlier cut, found by
# reading the guard's own output. They are pinned because the cheapest way to
# "improve" a pattern is to loosen it, and each returns the moment someone does.

printf '%s\n' "$OUT" | grep -q 'diagnose-macos-provision.sh:159' \
    && bad "NEGATIVE CONTROL: flagged a correct same-line BSD-first fallback chain" \
    || ok "NEGATIVE CONTROL: same-line fallback chains not flagged"

# ANCHOR ON file:line, NOT THE BARE NAME. Every stat -c hit's ADVICE string
# ends "a stat wrapper in litmus-stdlib.sh", so a bare-name grep matched the
# recommendation rather than a flag — this arm failed while the guard was
# correct. A test that mistakes its own subject's advice for a finding is the
# same false-accusation shape the guard is built to avoid, one level up.
printf '%s\n' "$OUT" | grep -qE 'litmus-stdlib\.sh:[0-9]+' \
    && bad "NEGATIVE CONTROL: flagged the repo's own GNU/BSD absorption layer" \
    || ok "NEGATIVE CONTROL: fallbacks across a line continuation not flagged"

printf '%s\n' "$OUT" | grep -qE 'help-(de|es|fr|ja)\.sh' \
    && bad "NEGATIVE CONTROL: flagged help TEXT as an rg invocation" \
    || ok "NEGATIVE CONTROL: usage lines not flagged"

printf '%s\n' "$OUT" | grep -q 'check-plan-ledger-readers.sh' \
    && bad "NEGATIVE CONTROL: flagged grep -r over the CANONICAL skills/ tree" \
    || ok "NEGATIVE CONTROL: the canonical tree is not a symlink farm"

# ── cost ───────────────────────────────────────────────────────────────────
# The first cut took 102s by forking grep for every line of every script. A
# cheap glob pre-filter took it to 6s with byte-identical output. An advisory
# that slow gets disabled, which is the same end state as never writing it.
_t0="$(date +%s)"; bash "$GUARD" >/dev/null 2>&1; _t1="$(date +%s)"
_d=$((_t1-_t0))
[ "$_d" -le 45 ] && ok "advisory is cheap (${_d}s)" \
                 || bad "advisory took ${_d}s — it will be disabled (1009-gccx)"

total=$((pass+fail))
if [ "$fail" -eq 0 ]; then
    printf 'PASS: portability idioms (%d/%d)\n' "$pass" "$total"
    exit 0
fi
printf 'FAIL: portability idioms (%d/%d)\n' "$pass" "$total"
exit 1
