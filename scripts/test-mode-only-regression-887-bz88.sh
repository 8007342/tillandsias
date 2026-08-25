#!/usr/bin/env bash
# Fixture for order 887-bz88 — a MODE-ONLY regression must not reach the trunk.
#
# THE INCIDENT. On 2026-08-25 scripts/check-credential-channel.sh went
# 100755 -> 100644 in a pushed commit and left origin/linux-next failing
# `violation:script-not-executable:1` on a pristine clone — the credential guard
# itself, which every meta-orchestration cycle invokes by path before any
# committable work, where a lost exec bit is a permission error and not a verdict.
#
# TWO BLIND SPOTS COMPOSED. Neither alone would have done it, which is why this
# fixture asserts BOTH halves and carries a mutation control for each:
#
#   1. check-script-exec-bits.sh read only the INDEX (`git ls-files -s`), and the
#      skill runs the gate BEFORE `git add`. A worktree-only chmod was invisible.
#   2. gate-stamp.sh hashed path + kind + CONTENT and never st_mode, so the
#      subsequent `git add` that wrote 100644 changed no bytes, the stamp stayed
#      fresh, and the pre-push hook accepted a tree the gate never saw that way.
#
# Ruled out by the same evidence, and asserted here so it stays ruled out: the
# push was NOT plan-only (it carried scripts/), so the pre-push plan-only fast
# lane is not the hole. That lane's negative control lives in the hook's own
# fixture; what this file protects is that closing the hole did not cost the
# ordinary green path (arms 1 and 4).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
REPO_ROOT="$PWD"
fail=0
ok()  { echo "ok: $1"; }
bad() { echo "FAIL: $1" >&2; fail=1; }

W="$(mktemp -d "${TMPDIR:-/tmp}/exec-bit-fixture.XXXXXX")"
trap 'rm -rf "$W"' EXIT

# ── 1. NEGATIVE CONTROL: a clean tree passes both checks. ────────────────────
# An assertion that only ever fires is indistinguishable from one that always
# fires; the green path is what proves the arms below mean something.
out="$(bash "$REPO_ROOT/scripts/check-script-exec-bits.sh" 2>/dev/null)"
case "$out" in
    ok:script-exec-bits:*) ok "clean tree -> $out" ;;
    *) bad "clean tree did not pass: $out" ;;
esac

# ── 2. gate-stamp must fingerprint st_mode (blind spot 2). ───────────────────
victim="$REPO_ROOT/scripts/check-credential-channel.sh"
[ -x "$victim" ] || { bad "precondition: $victim is not executable"; }
before="$(bash "$REPO_ROOT/scripts/gate-stamp.sh" compute 2>/dev/null)"
chmod -x "$victim"
during="$(bash "$REPO_ROOT/scripts/gate-stamp.sh" compute 2>/dev/null)"
chmod +x "$victim"
after="$(bash "$REPO_ROOT/scripts/gate-stamp.sh" compute 2>/dev/null)"
[ -n "$before" ] || bad "gate-stamp compute produced nothing"
if [ "$before" != "$during" ]; then
    ok "chmod -x moves the gate stamp (a stale stamp now refuses the push)"
else
    bad "REGRESSION: the gate stamp is blind to st_mode — the 887-bz88 hole is open"
fi
[ "$before" = "$after" ] && ok "restoring the bit restores the stamp (no spurious staleness)" \
    || bad "gate stamp is not stable across chmod -x/+x"

# ── 3. the exec-bit guard must read the WORKTREE, not just the index. ────────
# This is the pre-staging shape: index still 100755, worktree already broken.
chmod -x "$victim"
idx="$(git -C "$REPO_ROOT" ls-files -s -- scripts/check-credential-channel.sh | cut -d' ' -f1)"
out="$(bash "$REPO_ROOT/scripts/check-script-exec-bits.sh" 2>"$W/err")"; rc=$?
err="$(cat "$W/err")"
chmod +x "$victim"
[ "$idx" = "100755" ] || bad "precondition: index should still say 100755, said $idx"
case "$out" in
    violation:script-not-executable:*)
        ok "worktree-only chmod -x is REFUSED before staging (rc=$rc)" ;;
    *) bad "REGRESSION: a worktree-only mode regression passed the guard: $out" ;;
esac
[ "$rc" -ne 0 ] || bad "a violation must exit non-zero"
case "$err" in
    *"chmod +x"*) ok "the remedy names chmod +x, the fix that applies pre-staging" ;;
    *) bad "remedy must name chmod +x for a worktree-only regression" ;;
esac
case "$err" in
    *"update-index --chmod"*)
        bad "printed the index remedy for a worktree-only case — it would STAGE the broken mode" ;;
    *) ok "did not print the index remedy, which would stage the broken mode" ;;
esac

# ── 4. NEGATIVE CONTROL: a non-executable file with NO shebang is not a script. ─
# The guard must not start condemning ordinary data files under scripts/.
printf 'just data, no shebang\n' > "$REPO_ROOT/scripts/.887-fixture-data.tmp"
out="$(bash "$REPO_ROOT/scripts/check-script-exec-bits.sh" 2>/dev/null)"
rm -f "$REPO_ROOT/scripts/.887-fixture-data.tmp"
case "$out" in
    ok:script-exec-bits:*) ok "a shebang-less non-executable file is not condemned" ;;
    *) bad "the worktree arm over-fires on non-scripts: $out" ;;
esac

# ── 5. MUTATION CONTROL for arm 3: the index-only guard must MISS the incident. ─
# Reconstruct the pre-887 candidate selection (index mode only) and assert it
# passes the very tree arm 3 refuses — otherwise arm 3 could pass by luck.
PRE="$W/pre-887-execbits.sh"
awk '/^# ORDER 887-bz88 — READING ONLY THE INDEX/{skip=1}
     skip && /^candidates=\(\)/{skip=0}
     skip{next}
     {print}' "$REPO_ROOT/scripts/check-script-exec-bits.sh" \
  | sed 's/^    if \[ "\$mode" != "100644" \]; then/    if false; then/' > "$PRE"
# the reconstruction must still be the index-only test
sed -i 's/^    \[ -f "\$path" \] || continue$/    [ -f "$path" ] || continue\n    [ "$mode" = "100644" ] || continue/' "$PRE"
chmod -x "$victim"
out="$(bash "$PRE" 2>/dev/null)"
chmod +x "$victim"
case "$out" in
    ok:script-exec-bits:*)
        ok "MUTATION: the index-only guard passes the incident tree — arm 3 has teeth" ;;
    *) bad "mutation reconstruction unexpected: $out (arm 3 may pass for the wrong reason)" ;;
esac

# ── 6. the specific regression stays repaired on the tracked tree. ───────────
mode="$(git -C "$REPO_ROOT" ls-files -s -- scripts/check-credential-channel.sh | cut -d' ' -f1)"
[ "$mode" = "100755" ] \
    && ok "scripts/check-credential-channel.sh is 100755 in the index" \
    || bad "the 887-bz88 regression is back: mode=$mode"

if [ "$fail" -eq 0 ]; then
    echo "ok:mode-only-regression-fixture:all"
    exit 0
fi
echo "fail:mode-only-regression-fixture"
exit 1
