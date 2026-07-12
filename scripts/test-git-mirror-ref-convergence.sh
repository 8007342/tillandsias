#!/usr/bin/env bash
# @trace spec:git-mirror-service
# Offline reproduction + regression pin for order 301: the git mirror's
# reconciliation fetch must NOT clobber a just-received exported ref.
#
# Three bare-repo cases (no network, no Podman), each run in BOTH the unsafe
# legacy refspec ("+refs/*:refs/*") and the safe refspec now configured by
# images/git/entrypoint.sh ("+refs/heads/*:refs/remotes/origin/*"). The unsafe
# runs must reproduce the divergence; the safe runs must converge. The
# post-receive case exercises the real images/git/post-receive-hook.sh.
#
# Run: scripts/test-git-mirror-ref-convergence.sh   (exit 0 = all cases pass)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/images/git/post-receive-hook.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Deterministic identity + isolated HOME so the hook's log-path probing writes
# under the fixture temp dir, never the real host.
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@t
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@t
export HOME="$WORK/home"; mkdir -p "$HOME"

fail() { echo "FAIL: $*" >&2; exit 1; }

SAFE_FETCH="+refs/heads/*:refs/remotes/origin/*"
UNSAFE_FETCH="+refs/*:refs/*"

# Apply the mirror's origin refspec the way entrypoint.sh does, for the given
# safety mode. $1=mirror-dir $2=upstream-path $3=safe|unsafe
configure_mirror() {
    git -C "$1" config receive.denyNonFastforwards false
    git -C "$1" config receive.denyDeletes false
    # Neutralize any inherited global core.hooksPath (forge dev hosts set one)
    # so this bare repo's own hooks/post-receive runs, as it does in the
    # mirror container which has no such global override.
    git -C "$1" config core.hooksPath "$1/hooks"
    git -C "$1" remote remove origin 2>/dev/null || true
    git -C "$1" remote add origin "$2"
    if [ "$3" = safe ]; then
        git -C "$1" config remote.origin.fetch "$SAFE_FETCH"
        git -C "$1" config remote.origin.tagOpt "--no-tags"
    else
        git -C "$1" config remote.origin.fetch "$UNSAFE_FETCH"
    fi
}

# ---------------------------------------------------------------------------
# Case 1: post-receive relay. Mirror and upstream both start at BASE; the forge
# pushes PROBE to the mirror while upstream is still BASE. The real hook fires,
# reconcile-fetches, and relays PROBE. Safe => mirror and upstream both PROBE.
# Unsafe => reconcile fetch clobbers the mirror back to BASE while the relay
# advances upstream to PROBE (the observed order-301 divergence).
# Echoes "<mirror_sha> <upstream_sha>".
push_case() {
    local mode="$1" d="$WORK/push-$1"
    rm -rf "$d"; mkdir -p "$d"
    git init -q --bare "$d/upstream"
    git clone -q "$d/upstream" "$d/work" 2>/dev/null
    ( cd "$d/work"
      echo base > f; git add f; git commit -qm base
      git branch -M main
      git push -q origin HEAD:refs/heads/main )
    git init -q --bare "$d/mirror"
    configure_mirror "$d/mirror" "$d/upstream" "$mode"
    cp "$HOOK" "$d/mirror/hooks/post-receive"; chmod +x "$d/mirror/hooks/post-receive"
    # Seed the mirror at BASE (relay is a no-op; upstream already has BASE).
    git -C "$d/work" push -q "$d/mirror" main >/dev/null 2>&1
    # The divergence-inducing push: a new commit while upstream is stale.
    ( cd "$d/work"; echo probe >> f; git commit -qam probe )
    git -C "$d/work" push -q "$d/mirror" main >/dev/null 2>&1
    echo "$(git -C "$d/mirror" rev-parse refs/heads/main) $(git -C "$d/upstream" rev-parse refs/heads/main)"
}

read -r M_SAFE U_SAFE <<<"$(push_case safe)"
[ "$M_SAFE" = "$U_SAFE" ] || fail "case1 safe: mirror $M_SAFE != upstream $U_SAFE (relay must converge in one push)"
echo "case 1 ok (safe): one push converges mirror and upstream at ${M_SAFE:0:8}"

read -r M_UNSAFE U_UNSAFE <<<"$(push_case unsafe)"
[ "$M_UNSAFE" != "$U_UNSAFE" ] || fail "case1 control: unsafe refspec unexpectedly converged — fixture no longer reproduces the bug"
echo "case 1 control (unsafe): reproduces divergence mirror ${M_UNSAFE:0:8} != upstream ${U_UNSAFE:0:8}"

# ---------------------------------------------------------------------------
# Case 2: startup retry-push of a locally stranded commit. A prior session left
# STRANDED in the mirror but never reached upstream (still BASE). The retry loop
# reconcile-fetches then pushes each local head. Safe => STRANDED survives the
# fetch and is forwarded. Unsafe => the fetch resets the mirror head to BASE,
# stranding the commit and forwarding nothing new.
# Echoes "<mirror_sha> <upstream_sha> <stranded_sha>".
retry_case() {
    local mode="$1" d="$WORK/retry-$1"
    rm -rf "$d"; mkdir -p "$d"
    git init -q --bare "$d/upstream"
    git clone -q "$d/upstream" "$d/work" 2>/dev/null
    ( cd "$d/work"
      echo base > f; git add f; git commit -qm base
      git branch -M main
      git push -q origin HEAD:refs/heads/main )
    git init -q --bare "$d/mirror"
    configure_mirror "$d/mirror" "$d/upstream" "$mode"
    # NO hook here — this case exercises the entrypoint startup retry loop.
    # Seed the mirror at BASE, then strand a child commit only in the mirror.
    git -C "$d/mirror" fetch origin '+refs/heads/*:refs/heads/*' >/dev/null 2>&1
    ( cd "$d/work"; echo stranded >> f; git commit -qam stranded )
    local stranded; stranded="$(git -C "$d/work" rev-parse HEAD)"
    git -C "$d/work" push -q "$d/mirror" main >/dev/null 2>&1   # no relay (no hook)
    # Replicate the entrypoint retry sequence: reconcile fetch, then push each
    # local head/tag by explicit refspec.
    git -C "$d/mirror" fetch origin >/dev/null 2>&1 || true
    local refspecs="" ref
    for ref in $(git -C "$d/mirror" for-each-ref --format='%(refname)' refs/heads refs/tags 2>/dev/null); do
        refspecs="$refspecs $ref:$ref"
    done
    # shellcheck disable=SC2086
    git -C "$d/mirror" push origin $refspecs >/dev/null 2>&1 || true
    echo "$(git -C "$d/mirror" rev-parse refs/heads/main) $(git -C "$d/upstream" rev-parse refs/heads/main) $stranded"
}

read -r RM_S RU_S RS_S <<<"$(retry_case safe)"
[ "$RM_S" = "$RS_S" ] || fail "case2 safe: mirror head $RM_S lost the stranded commit $RS_S after reconcile fetch"
[ "$RU_S" = "$RS_S" ] || fail "case2 safe: upstream $RU_S did not receive stranded commit $RS_S"
echo "case 2 ok (safe): startup retry preserves and forwards stranded ${RS_S:0:8}"

read -r RM_U RU_U RS_U <<<"$(retry_case unsafe)"
[ "$RM_U" != "$RS_U" ] || fail "case2 control: unsafe refspec unexpectedly preserved the stranded commit"
echo "case 2 control (unsafe): reconcile fetch strands ${RS_U:0:8} (mirror ${RM_U:0:8}, upstream ${RU_U:0:8})"

# ---------------------------------------------------------------------------
# Case 3: empty-mirror seeding still yields cloneable heads and tags, AND the
# safe default refspec alone would NOT (justifying the explicit seed refspec).
seed_case() {
    local d="$WORK/seed"
    rm -rf "$d"; mkdir -p "$d"
    git init -q --bare "$d/upstream"
    git clone -q "$d/upstream" "$d/work" 2>/dev/null
    ( cd "$d/work"
      echo base > f; git add f; git commit -qm base
      git branch -M main
      git tag v1
      git push -q origin HEAD:refs/heads/main
      git push -q origin v1 )
    local base; base="$(git -C "$d/work" rev-parse HEAD)"

    # 3a. A plain fetch under the safe DEFAULT refspec must NOT create exported
    #     heads — this is exactly why entrypoint seeds with an explicit refspec.
    git init -q --bare "$d/plain"
    configure_mirror "$d/plain" "$d/upstream" safe
    git -C "$d/plain" fetch origin >/dev/null 2>&1 || true
    git -C "$d/plain" rev-parse --verify --quiet refs/heads/main >/dev/null 2>&1 \
        && fail "case3: default safe refspec should not populate refs/heads/main (explicit seed required)"
    git -C "$d/plain" rev-parse --verify --quiet refs/remotes/origin/main >/dev/null 2>&1 \
        || fail "case3: default safe refspec should populate refs/remotes/origin/main"

    # 3b. The explicit entrypoint seed refspec populates cloneable heads + tags.
    git init -q --bare "$d/mirror"
    configure_mirror "$d/mirror" "$d/upstream" safe
    git -C "$d/mirror" fetch origin '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*' >/dev/null 2>&1 \
        || fail "case3: explicit seed fetch failed"
    git -C "$d/mirror" symbolic-ref HEAD refs/heads/main   # serve main as default
    [ "$(git -C "$d/mirror" rev-parse refs/heads/main)" = "$base" ] || fail "case3: seeded head mismatch"
    [ "$(git -C "$d/mirror" rev-parse refs/tags/v1)" = "$base" ] || fail "case3: seeded tag missing"
    git clone -q "$d/mirror" "$d/clone" 2>/dev/null || fail "case3: seeded mirror not cloneable"
    [ -f "$d/clone/f" ] || fail "case3: clone missing seeded content"
    git -C "$d/clone" rev-parse --verify --quiet refs/tags/v1 >/dev/null 2>&1 || fail "case3: clone missing seeded tag"
}
seed_case
echo "case 3 ok: empty-mirror explicit seed yields cloneable heads and tags; default refspec alone does not"

echo "PASS: git mirror ref-convergence fixtures (order 301)"
