#!/usr/bin/env bash
# @trace order:1060-6fx7
#
# Pin: when the plan binary cannot RUN, the plan-only lane must say so — and
# must not say the LEDGER was refused.
#
# MEASURED on yoga 2026-09-05, with the override pointed at a binary that dies
# on exec. Three arms of test-pre-push-issue-capture-lane.sh went red with,
# verbatim:
#   plan-only lane: validation FAILED — tillandsias-plan check refused the
#   folded ledger (full gate required)
# The ledger was sound; the binary could not link. That is the 923-ws3r class —
# "the instrument is missing, not the data" — surviving inside the lane's own
# validation, and a refusal naming the wrong layer sends the reader to the
# ledger confidently, where they find nothing wrong and stop.
#
# HOW IT GOT THERE, since every part was reasonable. resolve_plan_binary honours
# an explicit TILLANDSIAS_PLAN_BIN on EXISTENCE alone, deliberately (704-zcgi).
# The lane set have_plan from "did the probe return a path". So a file that
# cannot execute became a validator, and its non-zero exit became a verdict
# about the data. One exec at the point the claim is made separates them; exit
# codes at the call sites cannot, because a dynamic-link failure and a genuine
# refusal are both non-zero.
#
# WHY BOTH ARMS. Arm 1 alone is satisfiable by never reporting a ledger fault at
# all, which would delete the check the lane exists to perform. Arm 2 is the
# control: a genuinely malformed ledger must STILL be reported as a ledger
# fault.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/scripts/hooks/pre-push-local-gate.sh"
fail=0; pass=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail+1)); }

W="$(mktemp -d "${TMPDIR:-/tmp}/lane-instrument.XXXXXX")"
trap 'rm -rf "$W"' EXIT INT TERM
export GIT_TERMINAL_PROMPT=0
G() { git -c user.email=t@t -c user.name=t "$@"; }

# A real validator for the control arm, resolved (and therefore EXECUTED) in the
# checkout rather than from inside the scratch repo — the cwd-relative-probe
# trap that took macOS out of the landing path (1056-5344).
_real="$(cd "$ROOT" && . scripts/plan-binary-probe.sh && resolve_plan_binary 2>/dev/null)" || _real=""
case "$_real" in ./*) _real="$ROOT/${_real#./}" ;; esac
if [ -z "$_real" ]; then
    echo "skip:lane-instrument-vs-ledger:no-validator — no runnable tillandsias-plan; the control arm cannot distinguish a ledger fault from a missing instrument here" >&2
    echo "lane-instrument-vs-ledger: 0 passed, 0 failed (skipped)"
    exit 0
fi

git init -q --bare "$W/bare.git"
git init -q -b linux-next "$W/wc"
cd "$W/wc" || exit 2
git remote add origin "$W/bare.git"
git config core.hooksPath .git/hooks
git config core.autocrlf false
mkdir -p scripts/hooks plan/index.d
cp "$GUARD" scripts/hooks/pre-push-local-gate.sh
for f in plan-binary-probe.sh gate-stamp.sh common.sh check-issue-citation-convention.sh; do
    cp "$ROOT/scripts/$f" "scripts/$f" 2>/dev/null || true
done
chmod +x scripts/*.sh scripts/hooks/*.sh 2>/dev/null || true
printf 'packets: []\n' > plan/index.yaml
printf 'base\n' > README.md
G add -A >/dev/null; G commit -q -m base
git push -q -u origin linux-next

cat > "$W/stub" <<'STUB'
#!/usr/bin/env bash
echo "$0: /lib64/libm.so.6: version \`GLIBC_2.44' not found" >&2
exit 127
STUB
chmod +x "$W/stub"

run_guard() { # $1 = TILLANDSIAS_PLAN_BIN
    local rsha; rsha="$(git rev-parse origin/linux-next)"
    printf 'refs/heads/linux-next %s refs/heads/linux-next %s\n' "$(git rev-parse HEAD)" "$rsha" \
        | env "TILLANDSIAS_PLAN_BIN=$1" bash scripts/hooks/pre-push-local-gate.sh 2>&1
}

# ── 1. AN UNRUNNABLE BINARY IS AN INSTRUMENT FAULT ─────────────────────────
printf 'packets: []\n' > plan/index.d/20260905t000000z-fixture.yaml
G add -A >/dev/null; G commit -q -m "ledger append"
out="$(run_guard "$W/stub")"

# EVERY DATA-BLAMING VERDICT, not just the one from the report. The mutation
# control below showed why: against the pre-fix hook this arm PASSED when it
# only looked for "refused the folded ledger", because a dead binary fails
# `validate-yaml` FIRST and the lane says "is not valid YAML" — a different
# sentence, the same misattribution, and one that accuses the pushed fragment
# even more directly. An arm that pins one spelling of a class certifies the
# class is gone when only that spelling is.
_blamed=""
case "$out" in
    *"refused the folded ledger"*) _blamed="refused the folded ledger" ;;
    *"is not valid YAML"*) _blamed="is not valid YAML" ;;
    *"does not parse to a YAML mapping"*) _blamed="does not parse to a YAML mapping" ;;
    *"could not PARSE a pushed fragment"*) _blamed="could not PARSE a pushed fragment" ;;
esac
if [ -n "$_blamed" ]; then
    bad "an unrunnable binary is reported as a fault in the DATA (\"$_blamed\") — this is the incident"
else
    ok "an unrunnable binary is not reported as a fault in the data"
fi
case "$out" in
    *"does NOT run here"*) ok "the verdict names the instrument, and says it does not run" ;;
    *) bad "the verdict does not name the instrument"; printf '%s\n' "$out" | tail -6 | sed 's/^/      /' >&2 ;;
esac
# The linker's own words, not a generic label: without them the reader still has
# to guess whether the binary is missing, stale, or unlinkable.
case "$out" in
    *"GLIBC_2.44"*) ok "the verdict carries the underlying reason" ;;
    *) bad "the verdict does not carry the underlying reason" ;;
esac

# ── 2. CONTROL: A REAL LEDGER FAULT IS STILL A LEDGER FAULT ────────────────
# Arm 1 is satisfiable by never reporting a ledger fault at all, which would
# remove the validation the lane exists to perform.
G reset -q --hard origin/linux-next
mkdir -p plan/index.d
printf 'packets: [unclosed\n' > plan/index.d/20260905t000001z-malformed.yaml
G add -A >/dev/null; G commit -q -m "a malformed fragment"
out="$(run_guard "$_real")"
if printf '%s' "$out" | grep -q 'validation FAILED'; then
    ok "CONTROL: a malformed fragment is still refused by the lane"
else
    bad "CONTROL: a malformed fragment was NOT refused — the lane's validation is gone"
    printf '%s\n' "$out" | tail -6 | sed 's/^/      /' >&2
fi
case "$out" in
    *"does NOT run here"*)
        bad "CONTROL: a real ledger fault was misreported as an instrument fault" ;;
    *) ok "CONTROL: a real ledger fault is not blamed on the instrument" ;;
esac

echo "lane-instrument-vs-ledger: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
