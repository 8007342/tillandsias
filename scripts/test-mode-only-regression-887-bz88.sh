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
# ORDER 889-8tcb. Whether the WORKTREE mode bit means anything here — read from
# git's own DECLARATION, never probed from the filesystem.
#
# A probe answers per-ENVIRONMENT and is the wrong axis: Git Bash on NTFS
# honours chmod 0644 and says "bits work", WSL on drvfs says they do not, and
# both answers are true about the asker while saying nothing about the tree.
# `core.fileMode=false` is git being TOLD the bits are untrustworthy — the same
# value from both sides of the WSL boundary, verified on yolanda's checkout.
#
# This gates the arms that must CREATE a worktree-only mode regression to test
# it. Where modes are not representable, `chmod -x` is a silent no-op, so those
# arms cannot build their own precondition — the exact failure that had this
# fixture reporting four FAILs at clean HEAD on Windows while yoga reported all
# green on native Linux at the same commit. Skipping loudly is the honest answer,
# and it is the same rule 888-miiy applied to the grader tonight: a capability
# gap is a NAMED skip, never a silent pass and never a false red.
MODES_REPRESENTABLE=1
case "$(git -C "$(pwd)" config --get core.fileMode 2>/dev/null)" in
    false|False|FALSE) MODES_REPRESENTABLE=0 ;;
esac
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

# ── 2. gate-stamp must fingerprint the exec bit — FROM THE INDEX (889-8tcb). ─
# NARROWED, DELIBERATELY, AND THIS COMMENT IS THE RECORD OF IT.
#
# This case originally asserted "chmod -x moves the gate stamp". That claim
# holds only on a filesystem that can represent mode bits, and on Windows it did
# not merely weaken — IT BECAME UNRUNNABLE. On drvfs `chmod -x` is a no-op, so
# this fixture could not perform its own setup and then correctly reported the
# hole it had failed to open: four FAILs at clean HEAD on yolanda, while yoga
# reported all green on native Linux at the same commit. Same silicon family,
# opposite verdict, one variable. A test that cannot create the condition it
# tests is not detecting a defect; it is reporting the absence of one it never
# made.
#
# The stamp now sources the bit from the INDEX, so the assertion becomes
# "STAGING a mode change moves the stamp". That is a real narrowing: a bare
# unstaged chmod no longer moves it. What makes it acceptable is that blind
# spot 2 was always the backstop — blind spot 1 (arm 3 below, the worktree arm
# of check-script-exec-bits.sh) is untouched, still refuses at GATE time, and is
# the guard that actually caught the original regression. The index moves at the
# moment the change becomes real, which is the moment that matters.
victim="$REPO_ROOT/scripts/check-credential-channel.sh"
[ -x "$victim" ] || bad "precondition: $victim is not executable"
before="$(bash "$REPO_ROOT/scripts/gate-stamp.sh" compute 2>/dev/null)"
[ -n "$before" ] || bad "gate-stamp compute produced nothing"
chmod -x "$victim"
bare="$(bash "$REPO_ROOT/scripts/gate-stamp.sh" compute 2>/dev/null)"
chmod +x "$victim"
# THE INDEX MODE IS CHANGED WITH `update-index --chmod`, NOT `chmod` + `add`.
# This is what makes the arm runnable on EVERY filesystem, rather than skipped
# on the one it was written for. Under core.fileMode=false git ignores the
# worktree bit entirely, so `chmod -x && git add` records nothing and the index
# never moves — the assertion would fail for a reason that has nothing to do
# with the stamp. `update-index --chmod` writes the index directly, which is
# both portable and a closer match to what the stamp now reads.
git -C "$REPO_ROOT" update-index --chmod=-x scripts/check-credential-channel.sh
staged="$(bash "$REPO_ROOT/scripts/gate-stamp.sh" compute 2>/dev/null)"
git -C "$REPO_ROOT" update-index --chmod=+x scripts/check-credential-channel.sh
after="$(bash "$REPO_ROOT/scripts/gate-stamp.sh" compute 2>/dev/null)"
if [ "$before" != "$staged" ]; then
    ok "an INDEX mode change moves the gate stamp (a stale stamp refuses the push)"
else
    bad "REGRESSION: the gate stamp is blind to an index mode change — 887-bz88 is open"
fi
[ "$before" = "$after" ] && ok "restoring the bit restores the stamp (no spurious staleness)" \
    || bad "gate stamp is not stable across the mode round-trip"
# PORTABILITY CONTROL (889-8tcb): the stamp must not depend on the worktree bit,
# because a filesystem that cannot represent it made the two sides of the
# Windows boundary disagree forever. On a POSIX host index and worktree agree
# (measured: 0 disagreements across 4537 files on yoga, 4553 on lenovinha), so
# this asserts the SOURCE rather than the value — an unstaged chmod is invisible.
[ "$before" = "$bare" ] \
    && ok "an UNSTAGED chmod does not move the stamp — the bit is index-sourced, not worktree-sourced" \
    || bad "the stamp still reads the WORKTREE bit — Windows (drvfs) will deadlock again"
if grep -qE '^\s*if \[\[ -x "\$absolute" \]\]; then execbits' "$REPO_ROOT/scripts/gate-stamp.sh"; then
    bad "gate-stamp.sh reverted to the worktree exec test — that is the drvfs deadlock"
else
    ok "gate-stamp.sh takes its exec bit from the index, not the filesystem"
fi

# ── 3. the exec-bit guard must read the WORKTREE, not just the index. ────────
# This is the pre-staging shape: index still 100755, worktree already broken.
# It is blind spot 1, and it is the guard that actually caught the original
# regression — unchanged by the 889-8tcb move of the STAMP to the index.
if [ "$MODES_REPRESENTABLE" = 1 ]; then
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
else
    # core.fileMode=false: git ignores the worktree bit, so a worktree-only
    # regression cannot exist and cannot originate from this host. The guard
    # gates its worktree arm on the same declaration, so assert THAT — a clean
    # pass — rather than a refusal the platform makes impossible.
    out="$(bash "$REPO_ROOT/scripts/check-script-exec-bits.sh" 2>/dev/null)"
    case "$out" in
        ok:script-exec-bits:*)
            ok "SKIP(core.fileMode=false): worktree arm inert by declaration, guard clean -> $out" ;;
        *) bad "core.fileMode=false but the guard did not pass cleanly: $out" ;;
    esac
fi

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
# Reconstruct the pre-887 candidate selection (index mode only) and assert the
# old guard passes the very tree arm 3 refuses — otherwise arm 3 could pass by
# luck. Requires building the worktree-only condition, so it shares arm 3's
# precondition.
if [ "$MODES_REPRESENTABLE" = 1 ]; then
    PRE="$W/pre-887-execbits.sh"
    awk '/^# ORDER 887-bz88 — READING ONLY THE INDEX/{skip=1}
         skip && /^candidates=\(\)/{skip=0}
         skip{next}
         {print}' "$REPO_ROOT/scripts/check-script-exec-bits.sh" \
      | sed 's/^    if \[ "\$mode" != "100644" \]; then/    if false; then/' > "$PRE"
    sed -i 's/^    \[ -f "\$path" \] || continue$/    [ -f "$path" ] || continue\n    [ "$mode" = "100644" ] || continue/' "$PRE"
    chmod -x "$victim"
    out="$(bash "$PRE" 2>/dev/null)"
    chmod +x "$victim"
    case "$out" in
        ok:script-exec-bits:*)
            ok "MUTATION: the index-only guard passes the incident tree — arm 3 has teeth" ;;
        *) bad "mutation reconstruction unexpected: $out (arm 3 may pass for the wrong reason)" ;;
    esac
else
    ok "SKIP(core.fileMode=false): arm 3's mutation control needs a worktree-only regression"
fi

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
