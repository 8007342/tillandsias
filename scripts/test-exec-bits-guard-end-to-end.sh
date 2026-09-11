#!/usr/bin/env bash
# freshness: added 2026-09-06 macneo-macos (order 1116-vps5)
# @trace order:731-d89b, order:1116-vps5
#
# END-TO-END arm for check-script-exec-bits.sh: drive the WHOLE guard against a
# real non-executable script in a scratch repo, not its regex in isolation.
#
# WHY THIS ARM EXISTS. Closing 1116-vps5 produced a patch that widened the
# guard's grep SWEEP and left its awk FILTER narrow, so the new hits were
# discarded and the guard's behaviour did not change at all. Three arms and a
# verified sabotage passed over it, because every one of them compared REGEXES
# rather than running the guard. A green that asserts a fix works while nothing
# downstream changed is the exact shape 1080-4deb is about, and it was built
# into the fix for a blind spot.
#
# THE HARNESS MUST COPY THE GUARD IN. It resolves REPO_ROOT from its own script
# path, so invoking the real checkout's copy from a scratch directory scans the
# REAL tree — macuahuitl measured that as "6111 files" and a positive control
# that passed when it had to fail. A harness whose control cannot fail is worth
# less than no harness.
set -uo pipefail
_fail=0; _n=0
ok()  { _n=$((_n+1)); echo "ok: $1"; }
bad() { echo "FAIL: $1"; _fail=1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/scripts/check-script-exec-bits.sh"
FILTER="$ROOT/scripts/lib/exec-bits-filter.awk"
[ -r "$GUARD" ] && [ -r "$FILTER" ] || { echo "refused:missing-guard-or-filter"; exit 2; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/scripts/lib"
cp "$GUARD" "$WORK/scripts/"; cp "$FILTER" "$WORK/scripts/lib/"
git -C "$WORK" init -q 2>/dev/null || { echo "refused:no-git"; exit 2; }
git -C "$WORK" config user.email t@e; git -C "$WORK" config user.name t

# A script invoked in a form the guard SEES (bare, at line start), left
# NON-EXECUTABLE. This is the condition the guard exists to refuse.
printf '#!/usr/bin/env bash\necho hi\n' > "$WORK/scripts/victim.sh"
printf '#!/usr/bin/env bash\nscripts/victim.sh\n' > "$WORK/scripts/caller.sh"
chmod +x "$WORK/scripts/caller.sh"
git -C "$WORK" add -A >/dev/null 2>&1
git -C "$WORK" update-index --chmod=-x scripts/victim.sh 2>/dev/null || true
git -C "$WORK" commit -qm init >/dev/null 2>&1

mode="$(git -C "$WORK" ls-files -s scripts/victim.sh | awk '{print $1}')"
if [ "$mode" != 100644 ]; then
    bad "harness invalid: victim.sh is $mode, not 100644 — the arm cannot test what it claims"
    exit 1
fi
ok "harness: victim.sh is tracked NON-executable (100644)"

# ARM 1. The guard must REFUSE. Pre-fix of 731-d89b this was the live breach.
out="$(cd "$WORK" && bash scripts/check-script-exec-bits.sh 2>&1)"; rc=$?
if [ "$rc" = 0 ]; then
    bad "arm1: the guard PASSED a non-executable script invoked by path — verdict: $(printf '%s' "$out" | tail -1)"
else
    ok "arm1: the guard refuses a non-executable script invoked by path (rc=$rc)"
fi

# ARM 2, POSITIVE CONTROL FOR THE HARNESS. Same tree, bit restored: the guard
# must PASS. Without this, arm 1 is satisfied by a guard that refuses
# everything, and a harness that always fails proves as little as one that
# always passes.
# BOTH the index bit and the on-disk bit. `git update-index --chmod=+x` moves
# the INDEX only, and the guard also tests the working file, so the control
# failed on the first run with the index already at 100755 — the control
# catching a defect in its own harness, which is what it is for.
git -C "$WORK" update-index --chmod=+x scripts/victim.sh
chmod +x "$WORK/scripts/victim.sh"
out2="$(cd "$WORK" && bash scripts/check-script-exec-bits.sh 2>&1)"; rc2=$?
if [ "$rc2" != 0 ]; then
    bad "arm2 (control): the guard still refuses after chmod +x — it is not testing the bit: $(printf '%s' "$out2" | tail -1)"
else
    ok "arm2 (control): the guard passes once the bit is restored"
fi

# ARM 3. THE CONTRACT, asserted as the documented NON-GOAL rather than as a
# defect. A backticked mention is prose and is deliberately unprotected. This
# arm exists so the next reader sees the boundary is INTENDED and priced —
# bare backtick widening was measured at +25 flagged paths against zero live
# exposure — rather than rediscovering it as a bug and "completing the set".
git -C "$WORK" update-index --chmod=-x scripts/victim.sh
chmod -x "$WORK/scripts/victim.sh"
printf '# see `scripts/victim.sh` for details\n' > "$WORK/scripts/doc-caller.sh"
rm -f "$WORK/scripts/caller.sh"
git -C "$WORK" add -A >/dev/null 2>&1; git -C "$WORK" commit -qm doc >/dev/null 2>&1
out3="$(cd "$WORK" && bash scripts/check-script-exec-bits.sh 2>&1)"; rc3=$?
if [ "$rc3" = 0 ]; then
    ok "arm3 (contract): a backticked mention does not make a script a caller — documented non-goal, priced"
else
    bad "arm3: a backticked mention was treated as a caller, reversing the measured non-goal: $(printf '%s' "$out3" | tail -1)"
fi

echo "ok:exec-bits-guard-end-to-end:$_n assertion(s)"
[ "$_fail" = 0 ] || exit 1
