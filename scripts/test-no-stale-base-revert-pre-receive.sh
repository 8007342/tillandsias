#!/usr/bin/env bash
# @trace spec:git-mirror-service, spec:meta-orchestration
# @trace order:1001-i5ux
#
# Fixture for the RECEIVING half of the stale-base revert guard.
#
# The sibling fixture (scripts/test-no-stale-base-revert.sh) drives the
# client-side pre-push hook. This one drives images/git/pre-receive-hook.sh
# against a real bare remote, and every arm pushes with --no-verify — the
# invocation the client half structurally cannot reach, which is the packet's
# entire reason to exist.
#
# WHAT MEASURING FIRST CHANGED ABOUT THIS PACKET, recorded here because the
# arms below are shaped by it and would otherwise look arbitrary.
#
# 1001-i5ux was filed expecting the mirror to be blind to the case esme hit:
# a stale branch force-pushed over an advanced trunk. It is not. Measured
# 2026-09-04 against this very hook, `git push --force --no-verify` is already
# refused — "REJECT: non-fast-forward branch update is disabled" — by the
# receive-hardening pass that predates this work. For the FORCE shape, the
# packet's first and third exit criteria were already met by a different rule.
#
# THE GAP IS THE FAST-FORWARD ONE, and it is worse. A merge commit whose
# resolution DROPS the trunk's files deletes them relative to the remote tip
# while remaining a clean fast-forward, so no force is needed and no existing
# rule looks at it. Measured on the unpatched hook: pushed, accepted, relay
# verified, two files silently reverted.
#
# It is also the shape this fleet is most exposed to. Every non-linux-next host
# merges origin/linux-next before every push by standing policy, so a bad
# resolution in exactly that merge is the routine operation — not an
# exceptional one — and `git log --name-only` does not show a merge commit's
# own changes, which is precisely why the deleted files never appear in the
# touched set.
#
# ARM 1 is therefore a REGRESSION arm (the force shape, already covered, pinned
# so a later relaxation of the non-FF rule cannot silently reopen it) and ARM 2
# is the NEW one.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/images/git/pre-receive-hook.sh"
[ -r "$HOOK" ] || { echo "blocked:no-hook:$HOOK"; exit 2; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/stale-base-recv.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
check() {
    if [ "$1" = ok ]; then pass=$((pass + 1)); printf 'ok   %s\n' "$2"
    else fail=$((fail + 1)); printf 'FAIL %s\n' "$2"; [ -n "${3:-}" ] && printf '     %s\n' "$3"; fi
}

# ── a mirror-shaped bare remote ────────────────────────────────────────────
git init -q --bare "$tmp/origin.git"
mkdir -p "$tmp/origin.git/hooks"
cp "$HOOK" "$tmp/origin.git/hooks/pre-receive"
chmod +x "$tmp/origin.git/hooks/pre-receive"
# The hook refuses outright without an executable relay helper beside it. A
# stub keeps this fixture about the guard rather than about the relay, and it
# consumes stdin because the real helper does.
printf '#!/bin/sh\ncat >/dev/null\nexit 0\n' > "$tmp/origin.git/hooks/tillandsias-relay-refs"
chmod +x "$tmp/origin.git/hooks/tillandsias-relay-refs"

git init -q -b main "$tmp/work"
cd "$tmp/work" || exit 2
git config user.email f@f; git config user.name f
git remote add origin "$tmp/origin.git"

for f in trunk_a trunk_b trunk_c; do echo "$f" > "$f"; done
echo mine > mine.txt
git add -A && git commit -qm base
git push -q --no-verify origin main 2>/dev/null
base="$(git rev-parse HEAD)"

# the stale branch: one innocent commit on the old base
git checkout -q -b stale "$base"
echo "my session's work" >> mine.txt
git commit -qam "innocent: only touches mine.txt"

# the trunk advances beneath it, as other hosts' work
git checkout -q main
for f in trunk_d trunk_e; do echo "$f" > "$f"; done
git add -A && git commit -qm "another host's work"
git push -q --no-verify origin main 2>/dev/null

# ── ARM 1 (regression): the force shape is refused at the receiving end ─────
git checkout -q stale
out="$(git push --force --no-verify origin stale:main 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
    check ok "a forced stale-base push is refused by the RECEIVING end under --no-verify"
else
    check FAIL "a forced stale-base push is refused" "rc=$rc out=[$(printf '%s' "$out" | tail -3)]"
fi

# ── ARM 2 (the packet): a FAST-FORWARD merge that discards the trunk ────────
# No force. A clean fast-forward. The merge commit's own deletions do not
# appear in `git log --name-only`, so nothing before this guard looked at them.
git merge -q --no-commit --no-ff origin/main 2>/dev/null || true
git rm -q --cached trunk_d trunk_e 2>/dev/null || true
rm -f trunk_d trunk_e
git commit -qm "merge origin/main (resolution drops the trunk's files)"
git merge-base --is-ancestor origin/main HEAD \
    || { echo "blocked:fixture:arm2-is-not-a-fast-forward"; exit 2; }
out="$(git push --no-verify origin stale:main 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'blocked:stale-base-revert:'; then
    check ok "a FAST-FORWARD push whose merge discards the trunk is refused"
else
    check FAIL "a fast-forward discard is refused" "rc=$rc out=[$(printf '%s' "$out" | tail -4)]"
fi
if printf '%s' "$out" | grep -q 'trunk_d' && printf '%s' "$out" | grep -q 'trunk_e'; then
    check ok "the refusal NAMES the reverted files, as the client hook does"
else
    check FAIL "the refusal names the reverted files" "out=[$(printf '%s' "$out" | tail -6)]"
fi

# ── ARM 3: without this, arms 1-2 are satisfied by a hook that refuses all ──
git reset -q --hard origin/main
echo "clean work" >> mine.txt
git commit -qam "ordinary commit on a current base"
out="$(git push --no-verify origin stale:main 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
    check ok "an ordinary push on a current base is accepted"
else
    check FAIL "an ordinary push on a current base is accepted" "rc=$rc out=[$(printf '%s' "$out" | tail -4)]"
fi

# ── ARM 4: a deliberate deletion is not a revert ────────────────────────────
git rm -q trunk_a && git commit -qm "delete a file on purpose"
out="$(git push --no-verify origin stale:main 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
    check ok "a deletion the commit itself made is accepted"
else
    check FAIL "a deletion the commit itself made is accepted" "rc=$rc out=[$(printf '%s' "$out" | tail -4)]"
fi

# ── ARM 5: a brand-new ref is never blocked — that is the salvage path ──────
git checkout -q -b salvage/test
echo salvaged > salvaged.txt && git add -A && git commit -qm "salvage copy"
out="$(git push --no-verify origin salvage/test 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
    check ok "a new remote ref (the salvage path) is never blocked"
else
    check FAIL "a new remote ref is never blocked" "rc=$rc out=[$(printf '%s' "$out" | tail -4)]"
fi

total=$((pass + fail))
if [ "$fail" -eq 0 ]; then
    echo "PASS: pre-receive stale-base revert guard ${pass}/${total} (1001-i5ux)"
    exit 0
fi
echo "FAIL: pre-receive stale-base revert guard ${fail}/${total} red (1001-i5ux)"
exit 1
