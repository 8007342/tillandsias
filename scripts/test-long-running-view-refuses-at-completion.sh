#!/usr/bin/env bash
# @trace order:1211-q9bm, order:251, spec:ci-release
#
# test-long-running-view-refuses-at-completion.sh — a terminal flip that would
# strand plan/long-running.md is refused AT THE FLIP, not at someone else's gate.
#
# THE DEFECT, measured 2026-09-15 and caused by this fixture's author. Completing
# order 330 left its row in plan/long-running.md. That file is a filtered view of
# ACTIVE multi_cycle packets, so a terminal packet must leave it, and
# check-long-running-view.sh enforces that correctly — but it runs inside the
# GATE (build.sh), so the refusal fired for whoever landed next. That was yoga,
# who had to move their own fragment out of the tree and re-count references to
# prove the refusal was not theirs, then find the owner, then decide whether
# editing another host's lane was acceptable. The person with the least context
# paid; the person who could have fixed it in one keystroke never saw it.
#
# The checker's own message names the right moment and cannot enforce it —
# "remove each stale one, in the same commit as the change that moved it" is a
# COMPLETION-TIME instruction delivered at LAND TIME to a different person.
#
# THE ARMS THAT MATTER ARE THE NEGATIVE CONTROLS (2, 3, 4). The obvious
# over-reach — refusing every terminal flip that smells related — would tax every
# closure in the fleet, and this guard must fire only on the exact stranding
# condition. Arm 5 pins that the LAND-TIME CHECK REMAINS: this is an early
# courtesy to the author, never a replacement for the backstop, because a flip
# made by anything that bypasses set-field is invisible here.
#
# Hermetic: every arm builds a throwaway plan/ tree and runs the binary there, so
# no arm writes a fragment into this checkout or reads its real view.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 3

BIN=""
if [ -f "$ROOT/scripts/plan-binary-probe.sh" ]; then
    # shellcheck source=scripts/plan-binary-probe.sh
    . "$ROOT/scripts/plan-binary-probe.sh" 2>/dev/null || true
    command -v resolve_plan_binary >/dev/null 2>&1 && BIN="$(resolve_plan_binary 2>/dev/null || true)"
fi
case "$BIN" in "") ;; /*) ;; *) BIN="$ROOT/${BIN#./}" ;; esac
[ -n "$BIN" ] && [ -x "$BIN" ] || { echo "skip:long-running-completion:no tillandsias-plan binary to exercise"; exit 3; }

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS  $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL  $1"; }

# A throwaway plan/ tree. The view's contents are the variable under test.
scratch() { # scratch <view-contents>
    local d; d="$(mktemp -d "${TMPDIR:-/tmp}/lrv-completion.XXXXXX")"
    mkdir -p "$d/plan/index.d"
    cp "$ROOT/plan/index.yaml" "$d/plan/" 2>/dev/null
    cp "$ROOT/plan/schema.yaml" "$d/plan/" 2>/dev/null
    printf '%s' "$1" > "$d/plan/long-running.md"
    printf '%s' "$d"
}

# flip <dir> <order> <status> ; sets FLIP_RC and FLIP_OUT, and FLIP_WROTE
flip() {
    local d="$1" order="$2" status="$3"; shift 3
    FLIP_OUT="$( cd "$d" && "$BIN" --index "$d/plan/index.yaml" set-field "$order" status "$status" \
        --evidence deadbeef --reason "1211-q9bm fixture probe" "$@" 2>&1 )"
    FLIP_RC=$?
    FLIP_WROTE=$(find "$d/plan/index.d" -name '*.yaml' 2>/dev/null | wc -l)
}

# 245 is multi_cycle in the committed ledger; 278 is not.
MC_ORDER=245
PLAIN_ORDER=278

echo "arm 1 — a terminal flip on a LISTED multi_cycle packet is REFUSED at the flip"
D="$(scratch "| $MC_ORDER | x | y | z | w |
")"
flip "$D" "$MC_ORDER" completed
if [ "$FLIP_RC" -ne 0 ] && printf '%s' "$FLIP_OUT" | grep -q 'still listed in'; then
    ok "refused (rc=$FLIP_RC) naming the view"
else
    bad "expected a refusal; rc=$FLIP_RC out=$(printf '%s' "$FLIP_OUT" | head -1)"
fi
if [ "$FLIP_WROTE" -eq 0 ]; then
    ok "and wrote no fragment — the refusal precedes the write"
else
    bad "it refused but still wrote $FLIP_WROTE fragment(s); a refused flip must not land"
fi
rm -rf "$D"

echo "arm 2 — NEGATIVE CONTROL: the same flip with the row ABSENT is allowed"
D="$(scratch "| 999999 | unrelated | row | only | here |
")"
flip "$D" "$MC_ORDER" completed
if [ "$FLIP_RC" -eq 0 ] && [ "$FLIP_WROTE" -gt 0 ]; then
    ok "allowed and wrote the fragment — the guard keys on the ROW, not on multi_cycle alone"
else
    bad "a multi_cycle packet whose row is already gone was refused; rc=$FLIP_RC out=$(printf '%s' "$FLIP_OUT" | head -1)"
fi
rm -rf "$D"

echo "arm 3 — NEGATIVE CONTROL: a NON-multi_cycle packet is never refused, listed or not"
# Otherwise this becomes a tax on every closure in the fleet.
D="$(scratch "| $PLAIN_ORDER | x | y | z | w |
")"
flip "$D" "$PLAIN_ORDER" completed
if [ "$FLIP_RC" -eq 0 ]; then
    ok "allowed — a row naming a non-multi_cycle packet is the view's problem, not this flip's"
else
    bad "a non-multi_cycle packet was refused; rc=$FLIP_RC out=$(printf '%s' "$FLIP_OUT" | head -1)"
fi
rm -rf "$D"

echo "arm 4 — NEGATIVE CONTROL: a NON-terminal flip on a listed multi_cycle packet is allowed"
# in_progress is exactly what a multi_cycle packet does between cycles; refusing
# it would make the view unclaimable.
D="$(scratch "| $MC_ORDER | x | y | z | w |
")"
flip "$D" "$MC_ORDER" in_progress --host fixturehost
if [ "$FLIP_RC" -eq 0 ]; then
    ok "allowed — only a TERMINAL status strands the view"
else
    bad "a non-terminal flip was refused; rc=$FLIP_RC out=$(printf '%s' "$FLIP_OUT" | head -1)"
fi
rm -rf "$D"

echo "arm 5 — the LAND-TIME check remains as the backstop"
# This guard is a courtesy to the author and cannot see a flip that bypasses
# set-field. Removing the gate check would trade a late refusal for no refusal.
if grep -q 'check-long-running-view.sh' "$ROOT/build.sh"; then
    ok "build.sh still runs check-long-running-view.sh"
else
    bad "the land-time backstop is gone — a flip bypassing set-field would strand the view silently"
fi

echo "arm 6 — the refusal quotes the checker's own instruction, so the two cannot drift"
if grep -q 'commit as the change that moved it' "$ROOT/scripts/check-long-running-view.sh" \
   && grep -q 'SAME COMMIT as this status change' "$ROOT/crates/tillandsias-plan/src/main.rs"; then
    ok "both sides name the same moment"
else
    bad "the refusal and the checker no longer agree on when the row must be removed"
fi

echo
echo "long-running view completion-time refusal: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
    echo "violation:long-running-completion:$fail"
    exit 1
fi
echo "ok:long-running-completion:$pass"
exit 0
