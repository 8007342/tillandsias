#!/usr/bin/env bash
# @trace spec:git-mirror-service, spec:forge-hot-cold-split, spec:litmus-framework
#
# Fixture for the packed-refs split-brain (order 432).
#
# The forge gitdir facade bind-mounts objects/ and refs/ (live, shared) but used
# to COPY packed-refs (point-in-time). A host-side `git gc` — which auto-gc
# triggers routinely and silently — packs every loose ref into the host's
# packed-refs and DELETES the loose ref files. refs/ is shared so the
# container's view empties, and its stale packed-refs copy predates the gc, so
# the refs exist in neither place.
#
# The consequence is worse than "lost refs": with HEAD pointing at an
# unresolvable branch the container sees tracked files as UNTRACKED, and a
# commit creates an ORPHANED ROOT COMMIT. The agent's work silently detaches
# from all history.
#
# Case 1 REPRODUCES the hazard with a copied packed-refs; case 2 proves a shared
# one prevents it. If case 1 stops reproducing, git's repack behaviour changed —
# verify that directly before weakening anything here.

set -uo pipefail
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }

build() {  # build <dir> <copy|share>
    local d="$1" mode="$2"
    mkdir -p "$d/host" "$d/facade"
    git -C "$d/host" init -q .
    echo a > "$d/host/f.txt"
    git -C "$d/host" add . >/dev/null
    git -C "$d/host" -c user.email=t@t -c user.name=t commit -qm init
    git -C "$d/host" branch feature-x
    git -C "$d/host" pack-refs --all
    cp "$d/host/.git/HEAD" "$d/facade/HEAD"
    ln -s ../host/.git/objects "$d/facade/objects"
    ln -s ../host/.git/refs    "$d/facade/refs"
    if [ "$mode" = "share" ]; then
        ln -s ../host/.git/packed-refs "$d/facade/packed-refs"
    else
        cp "$d/host/.git/packed-refs" "$d/facade/packed-refs"
    fi
}

# --- case 1: NEGATIVE CONTROL — copied packed-refs loses refs on host gc -----
build "$WORK/copy" copy
GIT_DIR="$WORK/copy/facade" git rev-parse --verify feature-x >/dev/null 2>&1 \
    || fail "case1 setup: container must resolve feature-x before gc"
# A new loose ref created after the facade copy is exactly what a session does.
git -C "$WORK/copy/host" branch feature-y
git -C "$WORK/copy/host" gc --quiet --prune=now
if GIT_DIR="$WORK/copy/facade" git rev-parse --verify feature-y >/dev/null 2>&1; then
    fail "case1: expected the COPIED packed-refs to lose the post-copy ref (hazard not reproduced)"
fi
echo "case 1 ok: copied packed-refs LOSES refs after a host gc (hazard reproduced)"

# --- case 2: shared packed-refs survives the same sequence ------------------
build "$WORK/share" share
git -C "$WORK/share/host" branch feature-y
git -C "$WORK/share/host" gc --quiet --prune=now
GIT_DIR="$WORK/share/facade" git rev-parse --verify feature-x >/dev/null 2>&1 \
    || fail "case2: shared packed-refs must still resolve feature-x after gc"
GIT_DIR="$WORK/share/facade" git rev-parse --verify feature-y >/dev/null 2>&1 \
    || fail "case2: shared packed-refs must see the post-facade ref after gc"
echo "case 2 ok: shared packed-refs survives a host gc"

# --- case 3: ancestry is preserved, not orphaned ----------------------------
echo b >> "$WORK/share/host/f.txt"
GIT_DIR="$WORK/share/facade" GIT_WORK_TREE="$WORK/share/host" git add f.txt >/dev/null 2>&1
GIT_DIR="$WORK/share/facade" GIT_WORK_TREE="$WORK/share/host" \
    git -c user.email=t@t -c user.name=t commit -qm post-gc >/dev/null 2>&1
DEPTH="$(GIT_DIR="$WORK/share/facade" GIT_WORK_TREE="$WORK/share/host" git rev-list --count HEAD 2>/dev/null)"
[ "${DEPTH:-0}" -ge 2 ] \
    || fail "case3: commit after gc orphaned history (depth ${DEPTH:-?}, expected >=2)"
echo "case 3 ok: commit after a host gc keeps its ancestry (depth $DEPTH)"

echo "PASS: forge packed-refs split-brain fixture (order 432)"
