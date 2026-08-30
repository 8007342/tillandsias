#!/usr/bin/env bash
# @trace spec:methodology-accountability
#
# Hermetic fixture for scripts/gate-stamp.sh (order 695-nvnd).
#
# The stamp is what lets the pre-push hook cost a hash instead of a multi-minute
# gate, so it has exactly two ways to fail and both are expensive:
#
#   too strict — it refused any tree containing a DELETED tracked entry, which is
#     every cycle that compacts the ledger (compaction deletes the fragments it
#     folded). The gate then ran twice: green-but-unstamped, then green-and-
#     stamped. On this host `./build.sh --check` is the slowest step in the
#     cycle, so the dominant cost roughly doubled whenever GC was due.
#
#   too loose — it stamps a tree it did not measure, which silently converts the
#     only remaining trunk protection into a rubber stamp.
#
# Cases 2 and 5 are therefore the load-bearing ones: accepting deletions must not
# become accepting anything.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAMP="$ROOT/scripts/gate-stamp.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
[ -f "$STAMP" ] || fail "gate-stamp not found: $STAMP"

git init -q -b main "$WORK"
cd "$WORK"
git config user.email fixture@example.invalid
git config user.name Fixture
# The stamp hashes worktree BYTES. On a host with core.autocrlf=true a
# `git checkout --` restore rewrites line endings, which would make case 3 fail
# for a reason that has nothing to do with the stamp.
git config core.autocrlf false
mkdir -p plan/index.d
echo seed > f.txt
printf 'packets: []\n' > plan/index.d/folded-a.yaml
printf 'packets: []\n' > plan/index.d/folded-b.yaml
git add -A
git commit -qm base

# ORDER 940-f77j — a stamp is now EARNED, not merely written: `write` requires a
# one-shot pass token that a GREEN gate issues, naming the tree it validated.
# This fixture stands in for the gate, so it issues the token the same way
# build.sh does before each write it expects to succeed.
#
# NOTE FOR THE READER: this changes nothing about the compaction allowance these
# cases exist for. That allowance lives in `compute()` — a deleted tracked entry
# is DROPPED from the hashed list so a compacted tree can be hashed at all — and
# it never meant "a compacted tree stamps without re-gating". A deletion still
# changes the digest exactly as an edit does. The token requirement sits one
# layer above and is orthogonal: issue it, and every case below asserts exactly
# what it asserted before.
issue_pass_token() {
    local _d
    _d="$(bash "$STAMP" compute)" || return 1
    {
        echo 'version 1'
        echo "digest $_d"
        echo 'dispatch check'
        echo 'issued now'
    } > "$(git rev-parse --absolute-git-dir)/tillandsias-gate-pass-token"
}

BASE_STAMP="$(bash "$STAMP" compute)" || fail "case 0: compute failed on a clean tree"
[ -n "$BASE_STAMP" ] || fail "case 0: empty stamp on a clean tree"
echo "ok: case 0 — clean tree hashes"

# --- case 1: a compaction-shaped tree stamps and verifies --------------------
# Only dirt is deleted tracked files, exactly what `tillandsias-plan compact`
# leaves behind after folding fragments into the base.
rm plan/index.d/folded-a.yaml plan/index.d/folded-b.yaml
issue_pass_token || fail "could not issue a pass token"
out="$(bash "$STAMP" write)"
[ "$out" = "ok:gate-stamped" ] || fail "case 1: write on a deletion-only tree said '$out'"
out="$(bash "$STAMP" verify)"
[ "$out" = "ok:gate-fresh" ] || fail "case 1: verify after write said '$out'"
echo "ok: case 1 — deletion-only worktree stamps and verifies"

# --- case 2 (NEGATIVE CONTROL): a modification is still stale ----------------
# Without this, "accept deletions" could degrade into "accept anything", which
# is strictly worse than the double-gate it was fixing.
echo changed >> f.txt
out="$(bash "$STAMP" verify)"
[ "$out" = "stale:tree-changed-since-gate" ] \
    || fail "case 2: modified tracked file must be refused, got '$out'"
git checkout -q -- f.txt
echo "ok: case 2 — modified tracked file still refused"

# --- case 3: deletions are MEASURED, not skipped -----------------------------
# The deleted path is folded into the hash, so the stamp must move when a file
# disappears and come back when it returns. A skipped entry would leave the
# stamp unchanged and let a deletion ride an old stamp to the trunk.
DELETED_STAMP="$(bash "$STAMP" compute)"
[ "$DELETED_STAMP" != "$BASE_STAMP" ] \
    || fail "case 3: deleting two tracked files did not change the stamp"
git checkout -q -- plan/index.d/folded-a.yaml plan/index.d/folded-b.yaml
RESTORED_STAMP="$(bash "$STAMP" compute)"
[ "$RESTORED_STAMP" = "$BASE_STAMP" ] \
    || fail "case 3: restoring the files did not restore the stamp"
echo "ok: case 3 — a deletion changes the stamp; restoring it restores the stamp"

# --- case 4: verify goes stale once the deletion is undone -------------------
# The stamp written in case 1 covered the deletion-only tree; the restored tree
# is a different tree and must not inherit it.
out="$(bash "$STAMP" verify)"
[ "$out" = "stale:tree-changed-since-gate" ] \
    || fail "case 4: restored tree must not reuse the deletion-era stamp, got '$out'"
echo "ok: case 4 — restored tree does not inherit the deletion-era stamp"

# --- case 5 (NEGATIVE CONTROL): unmeasurable is not the same as absent -------
# An entry that EXISTS but is neither a regular file nor a symlink was never
# measured, so it must still refuse rather than be waved through as deleted.
# Issue the token BEFORE breaking the tree (940-f77j). Without this the write
# refuses at the token check and never reaches the unmeasurable-entry path, so
# the control would still "refuse" while proving nothing about the thing it was
# written to prove — a negative control passing for the wrong reason is the same
# defect it exists to catch.
issue_pass_token || fail "case 5: could not issue a pass token"
rm f.txt
mkdir f.txt
out="$(bash "$STAMP" write 2>/dev/null)"
rc=$?
rmdir f.txt
git checkout -q -- f.txt
[ "$rc" -ne 0 ] || fail "case 5: a tracked path replaced by a directory must refuse"
[ "$out" = "stale:cannot-write-stamp" ] \
    || fail "case 5: expected stale:cannot-write-stamp, got '$out'"
echo "ok: case 5 — non-file, non-symlink entry still refused"

# --- case 6: the compacting cycle pays the gate ONCE -------------------------
# The full sequence a ledger-GC cycle actually runs: fold (delete the folded
# fragments) -> gate -> stamp -> commit -> push. The stamp must survive the
# commit, because the hook checks it AFTER the commit. Content, not HEAD, is
# what the stamp covers — so no second gate run is needed anywhere in here.
rm plan/index.d/folded-a.yaml plan/index.d/folded-b.yaml
issue_pass_token || fail "case 6: could not issue a pass token"   # <- the gate
out="$(bash "$STAMP" write)"                      # <- the ONLY gate+stamp
[ "$out" = "ok:gate-stamped" ] || fail "case 6: write said '$out'"
git add -A
git commit -qm "chore(plan): compact folded fragments"
out="$(bash "$STAMP" verify)"                     # <- what the pre-push hook runs
[ "$out" = "ok:gate-fresh" ] \
    || fail "case 6: stamp must survive the commit of the deletions, got '$out'"
echo "ok: case 6 — compact, gate once, commit, and the push-time check still passes"

echo "PASS: gate-stamp (7/7)"
