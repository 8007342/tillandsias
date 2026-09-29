#!/usr/bin/env bash
# @trace order:1500-gu5r, spec:ci-release
#
# test-groundtruth-regime-fails-closed.sh — check-groundtruth-regime-invariance
# grades its sets CONCURRENTLY (1500-gu5r), and one of those grades can be
# killed or crash on a loaded host. The check must then FAIL CLOSED naming the
# set and regime, never compare the survivors and print ok. A fake plan binary
# (TILLANDSIAS_PLAN_BIN) delegates to the real one except where an arm tells it
# to misbehave:
#   1 CONTROL: every grade completes -> ok:groundtruth-regime-invariant
#   2 one grade (a set, one regime) is KILLED after printing some verdicts ->
#     unavailable:grade-incomplete:<set>:<regime>, exit 2, nothing compared
#   3 one grade COMPLETES with a failing case (grade exits non-zero, as it does
#     for any FAIL) -> read as a divergence, NOT as an incomplete grade: the
#     check keys on the summary line, never on grade's exit status
# Pre-fix: arm 2 FAILS (the killed grade became an empty verdict list and the
# check printed ok).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="${TILLANDSIAS_TEST_CHECK:-$ROOT/scripts/check-groundtruth-regime-invariance.sh}"
. "$ROOT/scripts/plan-binary-probe.sh"
REAL="$(cd "$ROOT" && resolve_plan_binary)" || { echo "FAIL: no runnable plan binary" >&2; exit 1; }
case "$REAL" in /*) ;; *) REAL="$ROOT/${REAL#./}" ;; esac
W="$(mktemp -d "${TMPDIR:-/tmp}/gt-fails-closed.XXXXXX")"
trap 'rm -rf "$W"' EXIT
pass=0; fail=0
ok() { echo "ok:   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail + 1)); }

# The fake: GT_MODE=kill|failcase, GT_SET=<basename>, GT_REGIME=live|dead.
# The dead regime is recognised by the closed-port endpoint the check sets.
cat > "$W/plan" <<FAKE
#!/usr/bin/env bash
if [ "\${1:-}" = grade ] && [ -n "\${GT_MODE:-}" ] && [ "\$(basename "\${2:-}")" = "\${GT_SET:-}" ]; then
    regime=live
    # EXACTLY the check's closed port: a live endpoint such as a local
    # http://127.0.0.1:11434 must not read as the dead regime.
    [ "\${TILLANDSIAS_INFERENCE_ENDPOINT:-}" = "http://127.0.0.1:1" ] && regime=dead
    if [ "\$regime" = "\${GT_REGIME:-}" ]; then
        case "\$GT_MODE" in
            kill)
                "$REAL" grade "\$2" | grep -E '^(PASS|FAIL)' | head -n 1
                kill -9 \$\$ ;;
            failcase)
                "$REAL" grade "\$2" | awk '!d && /^PASS / { sub(/^PASS /, "FAIL "); d = 1 } { sub(/ fail=0 /, " fail=1 "); print }'
                exit 1 ;;
        esac
    fi
fi
exec "$REAL" "\$@"
FAKE
chmod +x "$W/plan"
SET="$(basename "$(ls "$ROOT"/openspec/litmus-tests/groundtruth/*.yaml | head -n 1)")"
run() { TILLANDSIAS_PLAN_BIN="$W/plan" "$@" bash "$CHECK" --strict 2>/dev/null; }

out="$(run env)"; rc=$?
case "$out" in ok:groundtruth-regime-invariant:*) [ "$rc" = 0 ] && ok "1: CONTROL: every grade completes -> $out" || bad "1: rc=$rc [$out]" ;;
    *) bad "1: control answered [$out] rc=$rc" ;; esac

out="$(run env GT_MODE=kill GT_SET="$SET" GT_REGIME=dead)"; rc=$?
if [ "$out" = "unavailable:grade-incomplete:$SET:dead" ] && [ "$rc" = 2 ]; then
    ok "2: a killed dead-regime grade of $SET fails closed by name (exit 2)"
else
    bad "2: a killed grade answered [$out] rc=$rc (want unavailable:grade-incomplete:$SET:dead, exit 2)"
fi

out="$(run env GT_MODE=failcase GT_SET="$SET" GT_REGIME=live)"; rc=$?
case "$out" in
    violation:groundtruth-regime-dependent:*) ok "3: a completed grade with a failing case reads as a divergence, not as incomplete ($out)" ;;
    *) bad "3: a completed failing grade answered [$out] rc=$rc" ;;
esac

if [ "$fail" -eq 0 ]; then echo "PASS: groundtruth-regime-fails-closed $pass/$((pass + fail))"; exit 0; fi
echo "FAIL: groundtruth-regime-fails-closed $pass/$((pass + fail))"; exit 1
