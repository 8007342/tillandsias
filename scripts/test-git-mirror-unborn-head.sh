#!/usr/bin/env bash
# @trace spec:git-mirror-service
# Regression pin for the unborn-HEAD mirror defect (2026-07-20):
# `git init --bare` leaves HEAD -> refs/heads/master; the seed fetch writes
# refs/heads/main + work branches but nothing repointed HEAD, and upstream has
# no master — so a clone of the seeded mirror exits 0 with "remote HEAD refers
# to nonexistent ref" and an EMPTY working tree. Post order-452 the guest
# assert turned that silent empty checkout into a deterministic crash of every
# clone-only forge launch.
# plan/issues/mirror-bare-repo-unborn-head-breaks-all-clones-2026-07-20.md
#
# Runs OFFLINE against the PRODUCTION repair helper
# (images/git/ensure-mirror-head.sh — the file the git image installs and the
# entrypoint runs at init/seed/fast-forward):
#   1. reproduces the break: seeded mirror w/ unborn HEAD clones to empty;
#   2. repair with a preferred branch -> HEAD names it, clone checks it out;
#   3. repair with no preference -> falls back to upstream's default (symref);
#   4. unseeded mirror -> exit 3 (still seeding; caller treats non-fatal).
#
# Run: scripts/test-git-mirror-unborn-head.sh   (exit 0 = pass)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENSURE="$ROOT/images/git/ensure-mirror-head.sh"
ENTRY="$(mktemp -d)"
trap 'rm -rf "$ENTRY"' EXIT

export GIT_AUTHOR_NAME=f GIT_COMMITTER_NAME=f GIT_CONFIG_NOSYSTEM=1 HOME="$ENTRY"

fail() { echo "FAIL: $1" >&2; exit 1; }

UP="$ENTRY/up.git"
WORK="$ENTRY/work"

# Upstream: main (default/HEAD) + linux-next; NO master — same shape as the
# live break (github upstream had only main and linux-next).
git init -q --bare "$UP"
git -C "$UP" symbolic-ref HEAD refs/heads/main
git init -q -b main "$WORK"
echo one > "$WORK/f"
git -C "$WORK" add f
git -C "$WORK" commit -q -m base
git -C "$WORK" push -q "$UP" HEAD:refs/heads/main
git -C "$WORK" commit -q --allow-empty -m work
git -C "$WORK" push -q "$UP" HEAD:refs/heads/linux-next
rm -rf "$WORK"

seed_mirror() {
    # Reproduces the container's exact init + seed shape: Alpine's git
    # defaults init to master (pin it explicitly so the fixture is
    # deterministic on hosts with init.defaultBranch=main), then the
    # entrypoint's one-time seed refspec.
    local m="$1"
    git -c init.defaultBranch=master init -q --bare "$m"
    git -C "$m" remote add origin "$UP"
    git -C "$m" fetch -q origin '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*'
}

# ── 1. Reproduce the break ─────────────────────────────────────────────
MIRROR="$ENTRY/mirror.git"
seed_mirror "$MIRROR"
CLONE1="$ENTRY/clone1"
git clone -q --no-local "file://$MIRROR" "$CLONE1" 2>/dev/null
git -C "$CLONE1" rev-parse --quiet --verify HEAD >/dev/null 2>&1 \
    && fail "expected the unborn-HEAD mirror to clone to an EMPTY tree (defect not reproduced — did git change remote-HEAD fallback?)"

# ── 2. Repair with preferred branch ────────────────────────────────────
"$ENSURE" "$MIRROR" linux-next >/dev/null || fail "ensure-mirror-head (preferred) exited $?"
[ "$(git -C "$MIRROR" symbolic-ref HEAD)" = "refs/heads/linux-next" ] \
    || fail "HEAD not repointed to preferred branch linux-next"
CLONE2="$ENTRY/clone2"
git clone -q --no-local "file://$MIRROR" "$CLONE2"
git -C "$CLONE2" rev-parse --quiet --verify HEAD >/dev/null 2>&1 \
    || fail "repaired mirror still clones to an empty tree"
[ "$(git -C "$CLONE2" symbolic-ref --short HEAD)" = "linux-next" ] \
    || fail "clone did not land on the preferred branch"
[ -f "$CLONE2/f" ] || fail "clone has no working-tree content"

# Idempotent: a second run on a healthy mirror is a no-op success.
"$ENSURE" "$MIRROR" linux-next >/dev/null || fail "ensure-mirror-head not idempotent on a healthy mirror"

# ── 3. No preference -> upstream default via symref ────────────────────
MIRROR2="$ENTRY/mirror2.git"
seed_mirror "$MIRROR2"
TILLANDSIAS_PROJECT_DEFAULT_BRANCH= "$ENSURE" "$MIRROR2" >/dev/null || fail "ensure-mirror-head (fallback) exited $?"
[ "$(git -C "$MIRROR2" symbolic-ref HEAD)" = "refs/heads/main" ] \
    || fail "fallback did not adopt upstream's default branch (main)"

# ── 4. Unseeded mirror -> exit 3, HEAD untouched ───────────────────────
MIRROR3="$ENTRY/mirror3.git"
git -c init.defaultBranch=master init -q --bare "$MIRROR3"
git -C "$MIRROR3" remote add origin "$UP"
"$ENSURE" "$MIRROR3" 2>/dev/null
rc=$?
[ "$rc" -eq 3 ] || fail "expected exit 3 on an unseeded mirror, got $rc"
[ "$(git -C "$MIRROR3" symbolic-ref HEAD)" = "refs/heads/master" ] \
    || fail "unseeded mirror HEAD should be left as-is"

echo "PASS: unborn-HEAD reproduced, repaired (preferred + fallback), unseeded left alone"
exit 0
