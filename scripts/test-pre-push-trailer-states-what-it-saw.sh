#!/usr/bin/env bash
# @trace order:1352-qbrd
#
# test-pre-push-trailer-states-what-it-saw.sh — the pre-push hook's LAST line
# never claims `./build.sh --check current for this tree` when the hook has
# just seen otherwise. MEASURED PRE-FIX (macneo 2026-09-22, work/1302-7j8p):
#   line 5:    warn:pre-push:pre-push: the tree changed since ./build.sh --check last passed
#   last line: local gate: preflight clean, ./build.sh --check current for this tree
#
#   A  THE OUTPUT, on a deliberately STALED tree (a partial scratch worktree of
#      HEAD: its stamp is necessarily stale:never-run, and the real checkout is
#      never touched): a work/<order> push exits 0, and the last line names the
#      warned deciders and the stamp verdict and does NOT claim a current gate
#   B  THE INSTRUMENT AGREES: the stamp verdict the trailer names is exactly
#      what `bash scripts/gate-stamp.sh verify` prints in that tree
#   C  CONTROL, on the trailer block itself: the green claim is printed when,
#      and only when, no decider warned AND the stamp is ok:gate-fresh; a
#      non-fresh stamp with no warnings is reported, not claimed
#
# Pre-fix: FAILS at arm A (the last line is the unconditional green claim).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/scripts/hooks/pre-push-local-gate.sh"
pass=0
fail=0
ok() { echo "ok:   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail + 1)); }
strip() { sed 's/\x1b\[[0-9;]*m//g'; }

WT="$(mktemp -d "${TMPDIR:-/tmp}/pre-push-trailer.XXXXXX")" && rmdir "$WT" || exit 2
trap 'cd / && git -C "$ROOT" worktree remove --force "$WT" >/dev/null 2>&1; rm -rf "$WT"; git -C "$ROOT" worktree prune >/dev/null 2>&1' EXIT
git -C "$ROOT" worktree add --no-checkout --detach -q "$WT" HEAD &&
    git -C "$WT" checkout -q HEAD -- scripts &&
    cp "$HOOK" "$WT/scripts/hooks/pre-push-local-gate.sh" &&
    cp "$ROOT/scripts/gate-stamp.sh" "$WT/scripts/gate-stamp.sh" || { echo "FAIL: scratch worktree"; exit 2; }

# ── A ───────────────────────────────────────────────────────────────────────
SHA="$(git -C "$WT" rev-parse HEAD)"
out="$(cd "$WT" && printf 'refs/heads/x %s refs/heads/work/1352-qbrd 0000000000000000000000000000000000000000\n' "$SHA" |
    timeout 600 bash scripts/hooks/pre-push-local-gate.sh origin file:///nonexistent 2>&1 | strip)"
rc=$?
last="$(grep -v '^[[:space:]]*$' <<<"$out" | tail -n 1)"
stamp_now="$(cd "$WT" && bash scripts/gate-stamp.sh verify 2>/dev/null)"
if [ "$rc" = 0 ] && grep -q '^warn:pre-push:' <<<"$out" && ! grep -qF -- '--check current for this tree' <<<"$last" &&
    grep -qE 'decider\(s\) warned .*NOT a clean gate' <<<"$last"; then
    ok "arm A: on a staled tree the last line reports the warnings and does not claim a current gate"
else
    bad "arm A: rc=$rc last=[$last]"
fi

# ── B ───────────────────────────────────────────────────────────────────────
if [ -n "$stamp_now" ] && [ "${stamp_now#ok:}" = "$stamp_now" ] && grep -qF -- "gate-stamp ${stamp_now} " <<<"$last"; then
    ok "arm B: the trailer names the stamp verdict gate-stamp.sh prints ($stamp_now)"
else
    bad "arm B: gate-stamp says [$stamp_now], trailer [$last]"
fi

# ── C: the trailer block alone, over its three inputs ──────────────────────
BLOCK="$(awk '/^_trailer_stamp=/,/^fi$/' "$HOOK")"
trailer() { # trailer <warned> <names> <stamp>
    bash -c 'GRN= YLW= RST=; _PREPUSH_WARNED=$1; _PREPUSH_WARNED_NAMES=$2; stamp=$3; eval "$4"' _ "$@" "$BLOCK" 2>&1
}
c1="$(trailer 0 "" ok:gate-fresh)"
c2="$(trailer 0 "" stale:tree-changed-since-gate)"
c3="$(trailer 2 "a,b" ok:gate-fresh)"
if [ -n "$BLOCK" ] && grep -qF -- '--check current for this tree' <<<"$c1" &&
    ! grep -qF -- '--check current for this tree' <<<"$c2" && grep -qF 'stale:tree-changed-since-gate' <<<"$c2" &&
    ! grep -qF -- '--check current for this tree' <<<"$c3" && grep -qF '2 decider(s) warned (a,b)' <<<"$c3"; then
    ok "arm C: the green claim appears only for no warnings + ok:gate-fresh; a stale stamp or any warning is reported, not claimed"
else
    bad "arm C: [$c1] [$c2] [$c3]"
fi

total=$((pass + fail))
if [ "$fail" -eq 0 ]; then
    echo "PASS: pre-push-trailer-states-what-it-saw $pass/$total (1352-qbrd)"
    exit 0
fi
echo "FAIL: pre-push-trailer-states-what-it-saw $pass/$total (1352-qbrd)"
exit 1
