#!/usr/bin/env bash
# test-ledger-distillation-advisory.sh — 914-nkc4: the README release-ledger
# distillation advisory reports when the table is over its own threshold, stays
# quiet when it is not, and refuses rather than answering when it cannot look.
#
# WHY THE HISTORICAL REFS ARE THE TEETH. The live table is AT threshold, so a
# run against HEAD can only ever print `ok:` — and a check that only ever prints
# ok: on a healthy tree is indistinguishable from one that is broken. The
# positive controls are real commits whose README carried 19 and 24 rows, which
# is the state 914-nkc4 measured and filed. If the counter breaks, those arms go
# green-looking and this fixture reds.
#
# THE ARGUMENT ARMS ARE yoga-silverblue's, inherited deliberately (1218-25z3):
# a `*) shift ;;` arm silently discards a typo'd flag and answers about the
# default tree, and a flag missing its value makes `shift 2` fail with the count
# unchanged, spinning forever under `set -uo pipefail` with no `-e`. Both are
# driven here with a HARD TIMEOUT, because verifying a hang fix by invoking it
# unbounded reproduces the hang in the verifier.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/check-ledger-distillation.sh"
pass=0; fail=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

[ -x "$CHECK" ] || { echo "skip:ledger-distillation-advisory:no-check-script"; echo "ledger-distillation-advisory: 0 passed, 0 failed (skipped)"; exit 0; }

# CAPTURE THEN COMPARE. Never `if ! <pipeline>`: under pipefail a SIGPIPE from a
# consumer can invert the guard and an arm passes for the wrong reason.
run() { timeout 60 bash "$CHECK" "$@" 2>/dev/null | tail -1; }

# ── ARM 1: at or under threshold is quiet ────────────────────────────────────
out="$(run --ref HEAD)"
case "$out" in
    ok:ledger-distillation:*) ok "ARM 1: a table at or under threshold reports ok (got: $out)" ;;
    *) bad "ARM 1: wanted ok:ledger-distillation:*, got '$out'" ;;
esac

# ── ARM 2+3: the measured over-threshold states report due ───────────────────
# These refs are load-bearing: they are the states 914-nkc4 filed against.
for ref in v56.9.12.2 66d615e3f~1; do
    if ! git -C "$ROOT" rev-parse --verify "$ref" >/dev/null 2>&1; then
        echo "skip: ARM for $ref — ref not present in this clone"
        continue
    fi
    out="$(run --ref "$ref")"
    case "$out" in
        due:ledger-distillation:*) ok "ARM: the over-threshold table at $ref reports due (got: $out)" ;;
        *) bad "ARM: $ref carried an over-threshold table; wanted due:, got '$out'" ;;
    esac
done

# ── ARM 4: cannot look is NOT zero ───────────────────────────────────────────
# A missing README must never read as an empty table. 'could not look' and 'no
# rows' are different answers and only one of them is about the ledger.
out="$(run --ref refs/heads/no-such-ref-914-nkc4)"
case "$out" in
    skipped:ledger-distillation:no-readme:*) ok "ARM 4: an unreadable ref is skipped, not counted as zero rows" ;;
    *) bad "ARM 4: wanted skipped:ledger-distillation:no-readme:*, got '$out'" ;;
esac

# ── ARM 5: an unknown argument examines nothing ──────────────────────────────
out="$(run --no-such-flag)"
case "$out" in
    fail:ledger-distillation:unknown-argument:*) ok "ARM 5: an unknown argument refuses instead of answering about the default tree" ;;
    *) bad "ARM 5: wanted fail:ledger-distillation:unknown-argument:*, got '$out'" ;;
esac

# ── ARM 6: a flag missing its value refuses and DOES NOT HANG ────────────────
# The timeout is the assertion. rc=124 means it spun.
for flag in --ref --threshold; do
    timeout 10 bash "$CHECK" "$flag" >/tmp/.ldist-$$ 2>/dev/null
    rc=$?
    out="$(tail -1 /tmp/.ldist-$$ 2>/dev/null)"; rm -f /tmp/.ldist-$$
    if [ "$rc" -eq 124 ]; then
        bad "ARM 6: '$flag' with no value HUNG (rc=124) — shift 2 failed with the argument count unchanged"
    elif case "$out" in fail:ledger-distillation:missing-value:*) true ;; *) false ;; esac; then
        ok "ARM 6: '$flag' with no value refuses and terminates (got: $out)"
    else
        bad "ARM 6: '$flag' wanted fail:ledger-distillation:missing-value:*, got '$out' (rc=$rc)"
    fi
done

# ── ARM 7: the advisory never refuses a cut ──────────────────────────────────
# Its whole strength decision is REPORT. An exit code other than 0 on a `due:`
# would turn table length into a release blocker.
timeout 60 bash "$CHECK" --ref v56.9.12.2 >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
    ok "ARM 7: a due: verdict still exits 0 — the advisory cannot refuse a cut"
else
    bad "ARM 7: a due: verdict exited $rc; this advisory must never block a release"
fi

total=$((pass+fail))
if [ "$fail" -eq 0 ]; then
    echo "ok:ledger-distillation-advisory"
    echo "PASS: ledger-distillation-advisory $pass/$total (914-nkc4)"
    exit 0
fi
echo "FAIL: ledger-distillation-advisory $pass/$total (914-nkc4)"
exit 1
