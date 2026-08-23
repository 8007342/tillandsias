#!/usr/bin/env bash
# @trace order:851-gpb5
#
# Hermetic fixture for scripts/hooks/pre-push-linux-next-merged.sh — the
# executable half of methodology's pull_merge_cadence.pre_push_gate, which
# from 2026-07-02 to 851-gpb5 was stated in four documents and enforced by no
# code anywhere. The rule's failure mode is silent (an unmerged platform push
# looks like any other push until the coordinator merges it back), so the
# fixture's weight is on the REFUSAL case plus a mutation-control arm proving
# the refusal is non-vacuous: a neutered guard must turn exactly the refusal
# scenario red while every allow scenario stays green.
#
# Topology: a real bare "origin" remote, because the guard reads
# refs/remotes/origin/linux-next — the branch-named-"origin/linux-next" trick
# the VERSION-guard fixture uses would not exercise the tracking-ref lookup.
#
# Runs under macOS bash 3.2 and Linux bash 5 alike.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/scripts/hooks/pre-push-linux-next-merged.sh"
SKILL="$ROOT/skills/meta-orchestration/SKILL.md"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/linux-next-merge-gate.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail=0
check() { # <name> <rc>
    if [ "$2" = "0" ]; then echo "PASS  $1"; else echo "FAIL  $1"; fail=1; fi
}

[ -f "$GUARD" ] || { echo "FAIL: guard not found: $GUARD"; exit 1; }
bash -n "$GUARD"; check "guard-parses" "$?"

# ── Build the two-repo topology ──────────────────────────────────────────────
git init -q --bare "$WORK/origin.git"
git -C "$WORK" clone -q "$WORK/origin.git" clone 2>/dev/null
REPO="$WORK/clone"
git -C "$REPO" config user.email fixture@example.invalid
git -C "$REPO" config user.name Fixture
git -C "$REPO" checkout -q -b linux-next
echo base > "$REPO/base.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "linux-next base"
git -C "$REPO" push -q origin linux-next
BASE_SHA="$(git -C "$REPO" rev-parse HEAD)"

# linux-next advances on origin; the platform branch forks from the OLD base.
echo advance > "$REPO/advance.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "linux-next advances"
git -C "$REPO" push -q origin linux-next
git -C "$REPO" checkout -q -b osx-next "$BASE_SHA"
echo platform > "$REPO/platform.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "platform work without the merge"
UNMERGED_SHA="$(git -C "$REPO" rev-parse HEAD)"

run_guard() { # <guard-path> <lref> <lsha> <rref> <rsha> -> stdout; rc in $?
    printf '%s %s %s %s\n' "$2" "$3" "$4" "$5" \
        | ( cd "$REPO" && bash "$1" origin "$WORK/origin.git" 2>/dev/null )
}

ZERO="0000000000000000000000000000000000000000"

# ── S1 (the seeded defect): unmerged osx-next push is REFUSED ────────────────
out="$(run_guard "$GUARD" refs/heads/osx-next "$UNMERGED_SHA" refs/heads/osx-next "$ZERO")"
rc=$?
[ "$rc" -ne 0 ] && [ "$out" = "blocked:linux-next-not-merged:osx-next" ]
check "S1-unmerged-platform-push-refused" "$?"

# ── S2 (negative-control twin: one variable changed — the merge happened) ────
git -C "$REPO" merge -q --no-edit origin/linux-next
MERGED_SHA="$(git -C "$REPO" rev-parse HEAD)"
out="$(run_guard "$GUARD" refs/heads/osx-next "$MERGED_SHA" refs/heads/osx-next "$ZERO")"
rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "ok:linux-next-merged:1" ]
check "S2-merged-platform-push-allowed" "$?"

# ── S3: linux-next itself is not gated ───────────────────────────────────────
out="$(run_guard "$GUARD" refs/heads/linux-next "$UNMERGED_SHA" refs/heads/linux-next "$ZERO")"
rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "ok:linux-next-merged:0" ]
check "S3-linux-next-not-gated" "$?"

# ── S4: deleting a platform branch is not gated (no tree to contain) ─────────
out="$(run_guard "$GUARD" "(delete)" "$ZERO" refs/heads/osx-next "$UNMERGED_SHA")"
rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "ok:linux-next-merged:0" ]
check "S4-branch-deletion-not-gated" "$?"

# ── S5: windows-next is gated too ────────────────────────────────────────────
out="$(run_guard "$GUARD" refs/heads/windows-next "$UNMERGED_SHA" refs/heads/windows-next "$ZERO")"
rc=$?
[ "$rc" -ne 0 ] && [ "$out" = "blocked:linux-next-not-merged:windows-next" ]
check "S5-windows-next-gated" "$?"

# ── S6: a repo with no origin/linux-next ref is out of scope ─────────────────
git init -q "$WORK/plain"
git -C "$WORK/plain" config user.email fixture@example.invalid
git -C "$WORK/plain" config user.name Fixture
echo x > "$WORK/plain/x.txt"
git -C "$WORK/plain" add -A
git -C "$WORK/plain" commit -qm x
PLAIN_SHA="$(git -C "$WORK/plain" rev-parse HEAD)"
out="$(printf '%s %s %s %s\n' refs/heads/osx-next "$PLAIN_SHA" refs/heads/osx-next "$ZERO" \
    | ( cd "$WORK/plain" && bash "$GUARD" origin https://example.invalid/r.git 2>/dev/null ))"
rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "ok:no-linux-next-ref" ]
check "S6-no-linux-next-ref-out-of-scope" "$?"

# ── MUTATION CONTROL: a neutered guard must fail exactly S1's assertion ──────
# Replace the ancestry test with `true` — the mutant of a guard that checks
# nothing. cmp-verify the mutation actually changed bytes (a sed that matched
# nothing removes nothing and certifies everything), then require the REFUSAL
# scenario to detect the mutant while an allow scenario still passes it.
MUTANT="$WORK/mutant-guard.sh"
sed 's/git merge-base --is-ancestor "$LINUX_NEXT" "$lsha" 2>\/dev\/null/true/' \
    "$GUARD" > "$MUTANT"
if cmp -s "$GUARD" "$MUTANT"; then
    echo "FAIL  mutation-applied: sed changed nothing — the control proves nothing"
    fail=1
else
    echo "PASS  mutation-applied"
fi
out="$(run_guard "$MUTANT" refs/heads/osx-next "$UNMERGED_SHA" refs/heads/osx-next "$ZERO")"
rc=$?
# The mutant ALLOWS the unmerged push — S1's assertion goes red against it.
[ "$rc" -eq 0 ] && [ "$out" = "ok:linux-next-merged:1" ]
check "mutation-control-neutered-guard-passes-the-breach" "$?"
out="$(run_guard "$MUTANT" refs/heads/osx-next "$MERGED_SHA" refs/heads/osx-next "$ZERO")"
rc=$?
[ "$rc" -eq 0 ]
check "mutation-control-allow-path-unchanged" "$?"

# ── Docs pin (851-gpb5): the skill must STATE the rule it now enforces ───────
# Defect 2 was that meta-orchestration never named the obligation; defect 3 was
# that "pre-push gate" in the skill meant ./build.sh --check, concealing it.
# Pin both: the methodology key is named in the skill's Finalization, and the
# colliding phrase "local pre-push gate" does not come back.
if [ -f "$SKILL" ]; then
    grep -q 'pull_merge_cadence.pre_push_gate' "$SKILL"
    check "skill-states-the-methodology-gate" "$?"
    ! grep -q 'local pre-push gate' "$SKILL"
    check "skill-no-longer-collides-the-name" "$?"
else
    echo "PASS  skill-pins-skipped (no skills/meta-orchestration/SKILL.md here)"
fi

if [ "$fail" -eq 0 ]; then
    echo "ok:pre-push-linux-next-merged-fixture:12"
    exit 0
fi
echo "FAIL: pre-push-linux-next-merged fixture had failures"
exit 1
