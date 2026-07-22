#!/usr/bin/env bash
# @trace spec:git-mirror-service
# Regression pin for order 449: a host coordinator pushing DIRECT to origin
# must not strand forge agents on a stale mirror. Reproduces the stranding
# (host pushes direct -> mirror's exported heads go stale -> an agent clone
# diverges from upstream), then proves the bounded-window reconcile pass
# (images/git/reconcile-exported-heads.sh — the SAME file the entrypoint's
# periodic loop runs) resolves it, WITHOUT clobbering a mirror head that
# carries un-relayed agent commits (non-forced invariant).
#
# Runs OFFLINE: file:// transports only, no Podman / network.
# Run: scripts/test-git-mirror-stale-reconcile.sh   (exit 0 = pass)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RECONCILE="$ROOT/images/git/reconcile-exported-heads.sh"
ENTRY="$(mktemp -d)"
trap 'rm -rf "$ENTRY"' EXIT

export GIT_AUTHOR_NAME=f GIT_COMMITTER_NAME=f GIT_CONFIG_NOSYSTEM=1 HOME="$ENTRY"
export ENSURE_HEAD="$ROOT/images/git/ensure-mirror-head.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

UP="$ENTRY/up.git"
MIRROR="$ENTRY/mirror.git"
HOSTWORK="$ENTRY/hostwork"

# Upstream with linux-next; mirror seeded current (entrypoint seed shape).
git init -q --bare "$UP"
git -C "$UP" symbolic-ref HEAD refs/heads/linux-next
git init -q -b linux-next "$HOSTWORK"
echo base > "$HOSTWORK/f"
git -C "$HOSTWORK" add f
git -C "$HOSTWORK" commit -q -m base
git -C "$HOSTWORK" push -q "$UP" HEAD:refs/heads/linux-next
git -c init.defaultBranch=master init -q --bare "$MIRROR"
git -C "$MIRROR" remote add origin "$UP"
git -C "$MIRROR" fetch -q origin '+refs/heads/*:refs/heads/*'
"$ENSURE_HEAD" "$MIRROR" linux-next >/dev/null || fail "seed HEAD repair failed"
BASE="$(git -C "$UP" rev-parse refs/heads/linux-next)"

# ── 1. Reproduce the stranding ─────────────────────────────────────────
# Host pushes DIRECT to origin, bypassing the mirror.
echo hostwork >> "$HOSTWORK/f"
git -C "$HOSTWORK" commit -q -am "host direct push"
git -C "$HOSTWORK" push -q "$UP" HEAD:refs/heads/linux-next
NEWUP="$(git -C "$UP" rev-parse refs/heads/linux-next)"
[ "$(git -C "$MIRROR" rev-parse refs/heads/linux-next)" = "$BASE" ] \
    || fail "expected the mirror to be STALE after a host direct push (stranding not reproduced)"
[ "$NEWUP" != "$BASE" ] || fail "upstream did not advance"
# An agent cloning now lands on the stale base — the Hy3 stranding.
git clone -q --no-local "file://$MIRROR" "$ENTRY/agent1"
[ "$(git -C "$ENTRY/agent1" rev-parse HEAD)" = "$BASE" ] \
    || fail "agent clone should land on the stale base (repro sanity)"

# ── 2. Bounded-window reconcile resolves it ────────────────────────────
"$RECONCILE" "$MIRROR" >/dev/null || fail "reconcile pass exited $?"
[ "$(git -C "$MIRROR" rev-parse refs/heads/linux-next)" = "$NEWUP" ] \
    || fail "reconcile did not fast-forward the exported head to upstream"
git clone -q --no-local "file://$MIRROR" "$ENTRY/agent2"
[ "$(git -C "$ENTRY/agent2" rev-parse HEAD)" = "$NEWUP" ] \
    || fail "post-reconcile agent clone is not current"

# ── 3. Non-forced invariant: un-relayed agent commits survive ──────────
# Simulate an agent push accepted by the mirror but not yet relayed, which
# DIVERGES from upstream: mirror branch gets commit X while upstream gets Y.
git -C "$ENTRY/agent2" checkout -qb feature
echo agentwork > "$ENTRY/agent2/agent.txt"
git -C "$ENTRY/agent2" add agent.txt
git -C "$ENTRY/agent2" commit -q -m "agent un-relayed work"
git -C "$ENTRY/agent2" push -q "file://$MIRROR" HEAD:refs/heads/feature
echo upstream-divergence > "$HOSTWORK/g"
git -C "$HOSTWORK" checkout -qb feature
git -C "$HOSTWORK" add g
git -C "$HOSTWORK" commit -q -m "conflicting upstream feature"
git -C "$HOSTWORK" push -q "$UP" HEAD:refs/heads/feature
AGENT_SHA="$(git -C "$MIRROR" rev-parse refs/heads/feature)"
"$RECONCILE" "$MIRROR" >/dev/null 2>&1
[ "$(git -C "$MIRROR" rev-parse refs/heads/feature)" = "$AGENT_SHA" ] \
    || fail "NON-forced invariant violated: reconcile clobbered an un-relayed agent head"
# And the non-diverged head still fast-forwards in the same pass.
[ "$(git -C "$MIRROR" rev-parse refs/heads/linux-next)" = "$NEWUP" ] \
    || fail "linux-next regressed during the divergence pass"

echo "PASS: stranding reproduced, bounded-window reconcile heals it, un-relayed agent heads survive"
exit 0
