#!/usr/bin/env bash
# @trace spec:git-mirror-service
# Offline order-318 fixture: a configured upstream failure rejects the forge
# push, while successful and multi-ref transactions converge atomically.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
export HOME="$WORK/home"
mkdir -p "$HOME"

# Hermetic git config: the forge exports GIT_CONFIG_GLOBAL with a global
# core.hooksPath redirection, which silently disables every fixture repo's
# own hooks (the upstream reject hook in case 3 never fired in-forge).
# Point both non-local scopes at fixture-owned empty files so hook
# resolution, insteadOf rewrites, and credential helpers cannot leak in.
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$WORK/gitconfig"
: > "$WORK/gitconfig"

fail() { echo "FAIL: $*" >&2; exit 1; }

UPSTREAM="$WORK/upstream.git"
MIRROR="$WORK/mirror.git"
CLIENT="$WORK/client"
git init -q --bare "$UPSTREAM"
git init -q --bare "$MIRROR"
git init -q "$CLIENT"
git -C "$CLIENT" config core.hooksPath ""
git -C "$CLIENT" remote add mirror "$MIRROR"
git -C "$MIRROR" config core.hooksPath "$MIRROR/hooks"

cp "$ROOT/images/git/pre-receive-hook.sh" "$MIRROR/hooks/pre-receive"
cp "$ROOT/images/git/post-receive-hook.sh" "$MIRROR/hooks/post-receive"
cp "$ROOT/images/git/relay-refs.sh" "$MIRROR/hooks/tillandsias-relay-refs"
chmod +x "$MIRROR/hooks/pre-receive" "$MIRROR/hooks/post-receive" \
    "$MIRROR/hooks/tillandsias-relay-refs"

echo base > "$CLIENT/file"
git -C "$CLIENT" add file
git -C "$CLIENT" commit -qm base

# Case 1: no Vault credential. The relay's HTTPS push fails and receive-pack
# must reject the local ref transaction instead of returning false success.
git -C "$MIRROR" remote add origin https://github.example.invalid/org/repo.git
if git -C "$CLIENT" push mirror HEAD:refs/heads/main >"$WORK/missing-token.log" 2>&1; then
    fail "credential-less upstream failure returned success"
fi
grep -Fq "configured upstream did not durably accept" "$WORK/missing-token.log" \
    || fail "credential failure did not name the durable-relay rejection"
git -C "$MIRROR" rev-parse --verify --quiet refs/heads/main >/dev/null 2>&1 \
    && fail "rejected credential-less push changed the mirror ref"
echo "case 1 ok: missing upstream credential rejects the forge push"

# Local transports inherit receive-pack's quarantine variables. Use Git's ext
# transport to sanitize only the upstream receiver, matching the isolation an
# HTTPS/SSH process boundary provides while keeping the fixture offline.
UPSTREAM_EXT="ext::env -u GIT_QUARANTINE_PATH -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES %S $UPSTREAM"
git -C "$MIRROR" remote set-url origin "$UPSTREAM_EXT"
export GIT_ALLOW_PROTOCOL=ext:file

git -C "$CLIENT" push mirror HEAD:refs/heads/main >"$WORK/success.log" 2>&1 \
    || { cat "$WORK/success.log" >&2; fail "relayable push was rejected"; }
grep -Fq "Relay verified" "$WORK/success.log" \
    || fail "successful push did not report verified relay"
MIRROR_MAIN="$(git -C "$MIRROR" rev-parse refs/heads/main)"
UPSTREAM_MAIN="$(git -C "$UPSTREAM" rev-parse refs/heads/main)"
[ "$MIRROR_MAIN" = "$UPSTREAM_MAIN" ] || fail "mirror/upstream did not converge"
git -C "$UPSTREAM" fsck --full --strict >/dev/null
echo "case 2 ok: verified relay converges mirror and upstream"

# Case 3: one rejected member must make the atomic upstream transaction and
# the local receive transaction both all-or-nothing.
cat > "$UPSTREAM/hooks/pre-receive" <<'HOOK'
#!/bin/sh
while read -r old new ref; do
    [ "$ref" != "refs/heads/rejected" ] || exit 1
done
exit 0
HOOK
chmod +x "$UPSTREAM/hooks/pre-receive"
git -C "$CLIENT" branch accepted
git -C "$CLIENT" branch rejected
if git -C "$CLIENT" push mirror accepted rejected >"$WORK/atomic.log" 2>&1; then
    fail "multi-ref relay succeeded despite upstream rejecting one member"
fi
for ref in accepted rejected; do
    git -C "$UPSTREAM" rev-parse --verify --quiet "refs/heads/$ref" >/dev/null 2>&1 \
        && fail "atomic upstream transaction partially created $ref"
    git -C "$MIRROR" rev-parse --verify --quiet "refs/heads/$ref" >/dev/null 2>&1 \
        && fail "rejected local transaction partially created $ref"
done
grep -Fq 'git push --atomic "$PUSH_URL" $REFSPECS' "$ROOT/images/git/relay-refs.sh" \
    || fail "relay source does not invoke git push --atomic with explicit refspecs"
! grep -Eq 'git push (--mirror|--all)' "$ROOT/images/git/relay-refs.sh" \
    || fail "relay invoked an unsafe broad push"
echo "case 3 ok: rejected multi-ref relay is atomic on both repositories"

# Case 4: order-369 auto-reconcile. When upstream advanced independently and
# the relay rejects a stale push, the failure path must fast-forward the
# mirror's exported heads from upstream — so the client's ordinary
# fetch/rebase/retry loop converges through the mirror alone — while a
# locally stranded same-named head survives the non-forced fetch untouched.
rm -f "$UPSTREAM/hooks/pre-receive"

SCOUT="$WORK/scout"
git clone -q -b main "$UPSTREAM" "$SCOUT"
git -C "$SCOUT" config core.hooksPath ""
echo upstream-advance > "$SCOUT/file"
git -C "$SCOUT" commit -qam upstream-advance
git -C "$SCOUT" push -q origin HEAD:refs/heads/main
UPSTREAM_NEW="$(git -C "$UPSTREAM" rev-parse refs/heads/main)"
MIRROR_STALE="$(git -C "$MIRROR" rev-parse refs/heads/main)"
[ "$UPSTREAM_NEW" != "$MIRROR_STALE" ] || fail "case4 setup: upstream did not advance beyond the mirror"

git -C "$CLIENT" push -q mirror accepted
BASE_ACCEPTED="$(git -C "$MIRROR" rev-parse refs/heads/accepted)"
STRANDED="$(git -C "$MIRROR" commit-tree "refs/heads/accepted^{tree}" -p "$BASE_ACCEPTED" -m stranded </dev/null)"
git -C "$MIRROR" update-ref refs/heads/accepted "$STRANDED"

echo stale-work > "$CLIENT/file2"
git -C "$CLIENT" add file2
git -C "$CLIENT" commit -qm stale-work
if git -C "$CLIENT" push mirror HEAD:refs/heads/main >"$WORK/stale.log" 2>&1; then
    fail "case4: stale push succeeded despite upstream divergence"
fi
grep -Fq "Reconcile fetch" "$WORK/stale.log" \
    || fail "case4: rejected relay did not attempt the reconcile fetch"
RECONCILED="$(git -C "$MIRROR" rev-parse refs/heads/main)"
[ "$RECONCILED" = "$UPSTREAM_NEW" ] \
    || fail "case4: mirror main $RECONCILED did not fast-forward to upstream $UPSTREAM_NEW"
KEPT="$(git -C "$MIRROR" rev-parse refs/heads/accepted)"
[ "$KEPT" = "$STRANDED" ] || fail "case4: reconcile clobbered the stranded mirror head"

git -C "$CLIENT" fetch -q mirror main
git -C "$CLIENT" rebase -q "$(git -C "$CLIENT" rev-parse FETCH_HEAD)" >/dev/null 2>&1 \
    || fail "case4: client rebase onto the reconciled mirror head failed"
git -C "$CLIENT" push mirror HEAD:refs/heads/main >"$WORK/retry.log" 2>&1 \
    || { cat "$WORK/retry.log" >&2; fail "case4: rebased retry push was rejected"; }
[ "$(git -C "$MIRROR" rev-parse refs/heads/main)" = "$(git -C "$UPSTREAM" rev-parse refs/heads/main)" ] \
    || fail "case4: retry did not converge mirror and upstream"
echo "case 4 ok: rejected stale push auto-reconciles the mirror and the retry loop converges"

echo "PASS: git mirror relay-verified acknowledgement fixture (orders 318+369)"
