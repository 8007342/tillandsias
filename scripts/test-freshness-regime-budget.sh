#!/usr/bin/env bash
# @trace order:1038-d7vw
#
# test-freshness-regime-budget.sh — the freshness budget must be selected by
# FILESYSTEM REGIME, and the selection must be able to fail.
#
# WHY THIS EXISTS. The budget it guards replaced a single global 15000 ms that
# could not serve both regimes honestly: esme-windows measured the same script,
# same machine, same tree, in-tree each time, at 725 ms on native ext4 and
# 13,841 ms through MSYS over drvfs. A budget set for one is either permanently
# red or permanently blind on the other.
#
# WHAT IT PINS, and deliberately not "the numbers are 15000 and 20000" alone:
# that the two budgets remain ORDERED and BRACKETED by the measurements that
# derived them. A test asserting only the literals would pass after someone
# raised the remote budget past the pre-fix cost, which is the one change that
# would silently stop the check catching a quadratic regression.

set -uo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

BUDGET="scripts/freshness-regime-budget.sh"
pass=0; fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

[ -f "$BUDGET" ] || { echo "skip:test-freshness-regime-budget:absent"; exit 0; }

# ── the grammar, because the litmus step parses ms= out of it with sed ────────
out="$(bash "$BUDGET" 2>&1)"
if printf '%s' "$out" | grep -qE '^freshness-budget: ms=[0-9]+ regime=(native|remote) fs=[a-z0-9-]+ source=(findmnt|path-inference|default)$'; then
    ok "output matches the pinned grammar the litmus step parses"
else
    bad "grammar drifted — the litmus step's sed would extract nothing: $out"
fi

ms="$(printf '%s' "$out" | sed -E 's/.*ms=([0-9]+).*/\1/')"
case "$ms" in ''|*[!0-9]*) bad "ms= did not extract an integer (got '$ms')" ;; *) ok "ms= extracts as an integer ($ms)" ;; esac

# ── the two budgets, bracketed by the measurements that derived them ──────────
NATIVE="$(grep -E '^BUDGET_NATIVE_MS=' "$BUDGET" | head -1 | cut -d= -f2)"
REMOTE="$(grep -E '^BUDGET_REMOTE_MS=' "$BUDGET" | head -1 | cut -d= -f2)"

# Measured, and these are the numbers the budgets must stay between. Named here
# so a future edit has to argue with the measurement rather than with a literal.
MEASURED_REMOTE_WORST=13841   # esme, MSYS over drvfs, idle, in-tree
MEASURED_PREFIX_REMOTE=25186  # esme, same host and regime, BEFORE the fix
MEASURED_NATIVE_WORST=725     # esme, native ext4 (lenovinha btrfs: 680)

[ "$REMOTE" -gt "$MEASURED_REMOTE_WORST" ] \
    && ok "remote budget clears the measured worst arm ($REMOTE > $MEASURED_REMOTE_WORST)" \
    || bad "remote budget $REMOTE does not clear the measured $MEASURED_REMOTE_WORST — permanently red on Windows"

# THE UPPER BOUND IS THE ONE THAT MATTERS AND THE ONE MOST EASILY LOST. Raising
# the remote budget past the pre-fix cost would leave the step green through a
# full regression to the quadratic — the exact defect this packet fixed.
[ "$REMOTE" -lt "$MEASURED_PREFIX_REMOTE" ] \
    && ok "remote budget still catches a quadratic regression ($REMOTE < $MEASURED_PREFIX_REMOTE pre-fix)" \
    || bad "remote budget $REMOTE is at or above the $MEASURED_PREFIX_REMOTE pre-fix cost — a full regression would pass"

[ "$NATIVE" -gt "$MEASURED_NATIVE_WORST" ] \
    && ok "native budget clears its measured arm ($NATIVE > $MEASURED_NATIVE_WORST)" \
    || bad "native budget $NATIVE does not clear the measured $MEASURED_NATIVE_WORST"

[ "$NATIVE" -lt "$REMOTE" ] \
    && ok "native budget is tighter than remote ($NATIVE < $REMOTE)" \
    || bad "native budget $NATIVE is not tighter than remote $REMOTE — the regime split does nothing"

# ── selection: the classifier must actually discriminate ─────────────────────
# Without this, a script that returned the remote budget unconditionally would
# satisfy every arm above. Drive the case statement directly.
_classify() { # <fstype> -> regime
    sed -n '/^case "\$fstype" in/,/^esac/p' "$BUDGET" \
        | grep -qE "^[[:space:]]*([a-z0-9|]*\|)?$1(\||\))" && return 0 || return 1
}
for fs in ext4 btrfs apfs; do
    _classify "$fs" || bad "$fs is not classified — it would fall through to the remote budget"
done
for fs in 9p drvfs cifs; do
    _classify "$fs" || bad "$fs is not classified as a crossing regime"
done
[ "$fail" -eq 0 ] && ok "native and crossing filesystems are both classified"

# THE ARM ABOVE IS NOT ENOUGH, and I only know that because it let a mutation
# through. Collapsing both case arms to `regime=remote; ms=$BUDGET_REMOTE_MS`
# left every check above green while the selector returned 20000 on btrfs —
# because grepping the case statement asks whether a filesystem is MENTIONED,
# not whether it MAPS to the right budget. That is the same defect shape as
# counting a string's occurrences instead of its callers (901-jtvi), reproduced
# inside the test written to catch it.
#
# So assert the ACTUAL OUTPUT on this host: if the filesystem we are standing on
# is a known-native one, the selector must say native and hand back the native
# budget. This runs wherever the suite runs and needs no fixture.
_fs="$(printf '%s' "$out" | sed -E 's/.*fs=([^ ]+).*/\1/')"
_regime="$(printf '%s' "$out" | sed -E 's/.*regime=([^ ]+).*/\1/')"
case "$_fs" in
    ext2|ext3|ext4|btrfs|xfs|f2fs|zfs|apfs|hfs|overlay|tmpfs)
        if [ "$_regime" = "native" ] && [ "$ms" = "$NATIVE" ]; then
            ok "live selection is correct on this host ($_fs -> $_regime, ${ms}ms)"
        else
            bad "on $_fs the selector returned regime=$_regime ms=$ms; expected native/$NATIVE — the classifier is not discriminating"
        fi ;;
    9p|v9fs|drvfs|cifs|smb3|nfs|nfs4|fuseblk|msys-inferred)
        if [ "$_regime" = "remote" ] && [ "$ms" = "$REMOTE" ]; then
            ok "live selection is correct on this host ($_fs -> $_regime, ${ms}ms)"
        else
            bad "on $_fs the selector returned regime=$_regime ms=$ms; expected remote/$REMOTE"
        fi ;;
    *)
        # Not a skip dressed as a pass: say plainly that this host could not
        # exercise the arm, so a suite that never runs it anywhere is visible.
        echo "  note: live-selection arm not exercised — unclassified fs '$_fs' on this host" ;;
esac

# UNKNOWN TAKES THE REMOTE BUDGET, and that is deliberate rather than a
# fallthrough nobody thought about: the failure being avoided is an intermittent
# red on a host whose regime could not be read, and the generous budget still
# catches the quadratic (25.2s pre-fix against 20s).
grep -qE '^\s*\*\)\s*$' "$BUDGET" && grep -A2 -E '^\s*\*\)\s*$' "$BUDGET" | grep -q 'BUDGET_REMOTE_MS' \
    && ok "an unreadable regime takes the remote budget, not the native one" \
    || bad "the default arm does not take BUDGET_REMOTE_MS"

# ── the litmus step must actually consume this, not carry a stale literal ────
LIT="openspec/litmus-tests/litmus-freshness-inventory-shape.yaml"
if grep -q 'freshness-regime-budget.sh' "$LIT" 2>/dev/null; then
    ok "the litmus step invokes the budget selector"
else
    bad "the litmus step does not invoke $BUDGET — the budget would be a dead file"
fi
# timeout_ms is a hard ceiling now; it must sit ABOVE the largest regime budget,
# or the runner kills the step before the step can report its own verdict, and
# a timeout kill reads as a hang rather than as a budget breach.
# 1083-gzqj: SEPARATE "I could not find the ceiling" FROM "the ceiling is wrong".
# This was `grep -A1 <selector> | grep -oE 'timeout_ms: [0-9]+'`: a POSITIONAL
# parse requiring timeout_ms to be the very next line after the command, over a
# file scanned INCLUDING its comments (the selector's name appears in prose in
# the block above the step). Insert a `description:` between the two keys,
# reorder them, or wrap the long command in a block scalar — all edits that
# change nothing semantically — and the parse yields "", and the arm reds with
# "runner ceiling '' does not exceed the remote budget". Two different failures
# collapsed into one message, and the message names the wrong one: the ceiling
# is fine, the fixture cannot read it. Found in my own file by the 1083-gzqj
# sweep, which is the class I raised.
_lit_code="$(sed '/^[[:space:]]*#/d' "$LIT")"
_ceiling="$(awk '
    /^[[:space:]]*-[[:space:]]*step:/ { inblk = 0 }
    /freshness-regime-budget\.sh/    { inblk = 1 }
    inblk && match($0, /timeout_ms:[[:space:]]*[0-9]+/) {
        s = substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", s); print s; exit
    }
' <<<"$_lit_code")"
if [ -z "$_ceiling" ]; then
    bad "no timeout_ms found in the budget-selector step block of $LIT — the fixture cannot READ the ceiling, which is not the same as the ceiling being too low"
elif [ "$_ceiling" -gt "$REMOTE" ]; then
    ok "the runner ceiling ($_ceiling ms) is above the largest regime budget ($REMOTE ms)"
else
    bad "the runner ceiling ${_ceiling}ms does not exceed the remote budget ${REMOTE}ms — the runner would kill the step before it could report a budget breach"
fi

printf 'freshness-regime-budget: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || { echo "fail:test-freshness-regime-budget:$fail"; exit 1; }
echo "ok:test-freshness-regime-budget:$pass"
