#!/usr/bin/env bash
# @trace order:1124-7f3u, order:889-twhe, order:531-*
#
# test-pre-push-plan-lane-fails-closed-without-binary.sh — pin that the pre-push
# plan-only lane REFUSES a fragment-bearing push when no runnable
# tillandsias-plan resolves, instead of passing it with a "checks skipped" note.
#
# WHAT THIS IS ABOUT. The lane's fail-closed test (889-twhe) is satisfied by yq
# ALONE. That is correct for the per-blob validation — "is this YAML, is it a
# map" is a question yq answers. It is wrong for the two checks further down,
# which are the FOLD: `tillandsias-plan check --strict-fragments` reads every
# fragment together, and check-fragment-status-loss.sh asks whether a status
# transition a fragment DECLARES actually survives folding. Neither is a
# property of any single blob and no YAML parser can compute either. So a host
# with yq and no plan binary passed the fail-closed test, reached those checks,
# and skipped them with a LANE_NOTE beside a successful push.
#
# WHY IT MATTERED, measured 2026-09-12: yoga's honest reopen of 1115-yvrq
# reached origin/linux-next carrying a 'completed' event beside a status that
# folds as in_progress. ./build.sh --check refuses that shape — but a
# fragment-only push never runs build.sh, and a ledger reopen is EXACTLY a
# fragment-only push. Every host that then obeyed the pre-push merge rule was
# refused at its own gate for about an hour, for a shape this lane admitted.
#
# "skipped" printed as a note beside a green push reads as a pass (order 531,
# one hook deep).
#
# Hermetic: local bare remote, no network, no credentials. Scratch tree removed
# on exit.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/scripts/hooks/pre-push-local-gate.sh"
fail=0; pass=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail+1)); }

# yq PRESENT is the PRECONDITION of arm 1, not an incidental dependency: the
# 889-twhe fail-closed test is satisfied by yq alone, so without it the lane
# refuses for a DIFFERENT reason and the arm would pass while testing nothing.
#
# A STUB, DELIBERATELY, so this fixture is hermetic. The hook's entire use of yq
# is two calls (lines 655, 659): `yq eval '.' <file>` must succeed, and
# `yq eval 'type' <file>` must print `!!map`. Nothing here tests yq's
# correctness — the arm tests what happens AFTER the yq tier passes, which is
# precisely the gap: yq validates one blob's SHAPE and cannot fold the ledger.
# Requiring a real yq would make this fixture skip on every host that lacks one
# (measured: lenovinha has none, on PATH or via tool-dispatch or in the builder
# toolbox), and a guard that silently skips where nobody looks is the shape this
# whole packet is about.
_mk_yq_stub() { # $1 = bin dir
    cat > "$1/yq" <<'YQSTUB'
#!/usr/bin/env bash
# Minimal stand-in for the two calls scripts/hooks/pre-push-local-gate.sh makes.
# `eval '.' FILE` -> exit 0 if the file is readable; `eval 'type' FILE` -> !!map
# for a file whose first non-comment, non-blank line ends in a colon or is a
# mapping key. Sufficient for the lane's shape tier, and nothing more is claimed.
expr="" ; file=""
while [ $# -gt 0 ]; do
    case "$1" in
        eval) shift ;;
        -*) shift ;;
        *) if [ -z "$expr" ]; then expr="$1"; else file="$1"; fi; shift ;;
    esac
done
[ -r "$file" ] || exit 1
case "$expr" in
    type)
        if grep -qE '^[[:space:]]*[A-Za-z0-9_.-]+:' "$file"; then echo '!!map'; else echo '!!seq'; fi
        ;;
    *) : ;;
esac
exit 0
YQSTUB
    chmod +x "$1/yq"
}

W="$(mktemp -d "${TMPDIR:-/tmp}/prepush-failclosed.XXXXXX")"
trap 'rm -rf "$W"' EXIT INT TERM
export GIT_TERMINAL_PROMPT=0
G() { git -c user.email=t@t -c user.name=t "$@"; }

git init -q --bare "$W/bare.git"
git init -q -b linux-next "$W/wc"
cd "$W/wc" || exit 2
git remote add origin "$W/bare.git"
# core.hooksPath is GLOBAL and OVERRIDES .git/hooks — pin it per scratch repo,
# or a forge's ~/.gitconfig substitutes the real hooks for the one under test.
git config core.hooksPath .git/hooks
mkdir -p scripts/hooks plan/issues plan/index.d
cp "$GUARD" scripts/hooks/pre-push-local-gate.sh
# check-issue-citation-convention.sh is needed by ARM 3: without it an
# issues-only push is refused for a DIFFERENT missing validator, and arm 3
# would report the lane over-refusing when the fixture simply arrived unarmed.
for f in plan-binary-probe.sh gate-stamp.sh common.sh check-fragment-status-loss.sh check-issue-citation-convention.sh; do
    cp "$ROOT/scripts/$f" "scripts/$f" 2>/dev/null || true
done
chmod +x scripts/*.sh scripts/hooks/*.sh 2>/dev/null
printf 'packets: []\n' > plan/index.yaml
printf 'base\n' > plan/issues/existing.md
G add -A >/dev/null; G commit -q -m base
git push -q -u origin linux-next

# A PATH with no tillandsias-plan on it. resolve_plan_binary falls back to PATH
# (704-zcgi), so hiding target/release alone would not make the binary absent —
# and on this fleet the binary is usually installed at ~/.local/bin, which is
# precisely the case a hardcoded target/release test would have missed.
mkdir -p "$W/emptybin"
for t in git bash sh env grep sed awk cat mktemp rm cp mkdir printf head tail tr sort comm wc dirname basename cut find xargs chmod date; do
    _p="$(command -v "$t" 2>/dev/null)" && ln -sf "$_p" "$W/emptybin/$t" 2>/dev/null
done
_mk_yq_stub "$W/emptybin"      # yq PRESENT, plan binary ABSENT — the exact gap
NOPLAN_PATH="$W/emptybin"

_run_push() { # $1=extra env assignments as a string; prints output, returns rc
    local out rc
    out="$(env -u TILLANDSIAS_PLAN_BIN PATH="$NOPLAN_PATH" \
        bash scripts/hooks/pre-push-local-gate.sh origin "$W/bare.git" 2>&1 <<< \
        "refs/heads/linux-next $(git rev-parse HEAD) refs/heads/linux-next $(git rev-parse origin/linux-next)")"
    rc=$?
    printf '%s\n' "$out"
    return $rc
}

# ── ARM 1: fragment-bearing push, no runnable binary → REFUSE ────────────────
printf 'packets: []\n' > plan/index.d/20260912t000000z-arm1.yaml
G add -A >/dev/null; G commit -q -m "arm1: a fragment-only push"
out="$(_run_push)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'full gate required'; then
    ok "arm1: a fragment-bearing push with no runnable plan binary is REFUSED (full gate required)"
else
    bad "arm1: the lane admitted a fragment-bearing push it could not fold (rc=$rc)"
    printf '%s\n' "$out" | sed 's/^/      /' >&2
fi
# The refusal must not read as a verdict about the DATA (923-ws3r / 1060-6fx7):
# the instrument is missing, not the ledger.
if printf '%s' "$out" | grep -qiE 'cannot (run|fold)|no runnable tillandsias-plan|does NOT run here'; then
    ok "arm1: the refusal names the missing INSTRUMENT, not a defect in the ledger"
else
    bad "arm1: refusal does not say the instrument is what is missing"
fi
# And it must NOT have been a LANE_NOTE beside a success — the exact old shape.
if printf '%s' "$out" | grep -qiE 'checks skipped'; then
    bad "arm1: the lane still prints 'checks skipped' — the 531 shape survives"
else
    ok "arm1: no 'checks skipped' note (a skip here is a refusal, 1124-7f3u)"
fi

# ── ARM 2, NEGATIVE CONTROL: binary present → fast lane still works ──────────
# Lane SPEED is the reason the lane exists (930-i6x4). A fix that refuses
# everything would pass arm 1 and destroy the lane, so this arm is what makes
# arm 1 mean something.
_probe_bin="$(bash -c '. "$1/scripts/plan-binary-probe.sh"; resolve_plan_binary' _ "$ROOT" 2>/dev/null)"
if [ -n "$_probe_bin" ] && "$_probe_bin" capabilities >/dev/null 2>&1; then
    out2="$(TILLANDSIAS_PLAN_BIN="$_probe_bin" \
        bash scripts/hooks/pre-push-local-gate.sh origin "$W/bare.git" 2>&1 <<< \
        "refs/heads/linux-next $(git rev-parse HEAD) refs/heads/linux-next $(git rev-parse origin/linux-next)")"
    rc2=$?
    if [ "$rc2" -eq 0 ] && printf '%s' "$out2" | grep -q 'plan-only lane'; then
        ok "arm2 (negative control): with a runnable binary the fast lane still accepts the same push"
    else
        bad "arm2 (negative control): the fast lane no longer accepts a valid fragment push (rc=$rc2) — the fix would have destroyed the lane"
        printf '%s\n' "$out2" | sed 's/^/      /' >&2
    fi
else
    echo "note:arm2-skipped: no runnable plan binary on this host to drive the control" >&2
fi

# ── ARM 3: NO fragments in the push, no binary → still accepted ──────────────
# The refusal must be SCOPED to pushes that carry what the missing validator
# reads, exactly as 889-twhe scoped the yq rule. A blanket refusal would send
# every issues-only push to the full gate for a tool it never needed.
G rm -q --cached plan/index.d/20260912t000000z-arm1.yaml >/dev/null 2>&1
rm -f plan/index.d/20260912t000000z-arm1.yaml
printf 'a capture\n' > plan/issues/arm3-note.md
G add -A >/dev/null; G commit -q -m "arm3: an issues-only push"
out3="$(_run_push)"; rc3=$?
if [ "$rc3" -eq 0 ]; then
    ok "arm3: an issues-only push is still accepted with no plan binary (refusal stays scoped)"
else
    bad "arm3: a push carrying no fragments was refused for a missing fold validator (rc=$rc3)"
    printf '%s\n' "$out3" | sed 's/^/      /' >&2
fi

echo "test-pre-push-plan-lane-fails-closed-without-binary: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
