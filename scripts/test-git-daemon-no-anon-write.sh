#!/usr/bin/env bash
# @trace spec:git-mirror-service
# Regression pin for order 423 (Decision 4 path 1): the git mirror daemon MUST
# NOT accept anonymous pushes. All legitimate mirror writes flow through the
# pre-receive relay hook to GitHub over git:// read clones/fetches only; the
# daemon must never serve receive-pack to an unauthenticated client.
#
# This runs OFFLINE (no Podman, no network): it starts `git daemon` with the
# exact production flags (minus --enable=receive-pack) against a throwaway bare
# repo and asserts that an anonymous `git push` over git:// is REFUSED.
#
# Run: scripts/test-git-daemon-no-anon-write.sh   (exit 0 = pass)
set -uo pipefail

WORK="$(mktemp -d)"
trap 'kill "$DAEMON_PID" 2>/dev/null; rm -rf "$WORK"' EXIT

export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@t
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@t
export GIT_CONFIG_NOSYSTEM=1
export GIT_ALLOW_PROTOCOL=git:file

BARE="$WORK/mirror.git"
SRC="$WORK/src"
CLONE="$WORK/clone"

# Bare repo the daemon serves, with one commit so clones are non-empty.
git init -q --bare "$BARE"
git -C "$BARE" config receive.denyCurrentBranch warn
git init -q "$SRC"
git -C "$SRC" commit -q --allow-empty -m base
git -C "$SRC" push -q "$BARE" HEAD:refs/heads/main

# Client clone (read path — must work).
git clone -q "file://$BARE" "$CLONE" 2>/dev/null || git clone -q "$BARE" "$CLONE"
cd "$CLONE"
git commit -q --allow-empty -m "attacker commit"

# Start the daemon with the production flags (no --enable=receive-pack).
git daemon \
    --reuseaddr \
    --export-all \
    --base-path="$WORK" \
    --listen=127.0.0.1 \
    --port=9418 \
    --verbose >"$WORK/daemon.log" 2>&1 &
DAEMON_PID=$!

# Give the daemon a moment to bind.
for _ in $(seq 1 20); do
    if git ls-remote "git://127.0.0.1:9418/mirror.git" >/dev/null 2>&1; then
        break
    fi
    sleep 0.1
done

# The anonymous push MUST be refused.
if git push "git://127.0.0.1:9418/mirror.git" HEAD:refs/heads/attacker 2>"$WORK/push.log"; then
    echo "FAIL: anonymous push to git daemon was ACCEPTED (order 423 regression)" >&2
    cat "$WORK/push.log" >&2
    exit 1
fi

# Sanity: the daemon IS serving read over git:// (so the refusal above is a
# receive-pack denial, not a "daemon not listening" artifact).
if ! git ls-remote "git://127.0.0.1:9418/mirror.git" >/dev/null 2>&1; then
    echo "FAIL: daemon is not serving git:// reads — fixture harness broken" >&2
    exit 1
fi

# Sanity: the refused push must be due to the service being disabled, not some
# unrelated error. The daemon log should show no receive-pack being served.
if grep -q "receive-pack" "$WORK/daemon.log"; then
    echo "FAIL: daemon log mentions receive-pack — anon write path may be open" >&2
    exit 1
fi

echo "PASS: git daemon refuses anonymous receive-pack (order 423)"
exit 0
