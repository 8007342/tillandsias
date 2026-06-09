#!/bin/bash
set -e
# @trace spec:git-mirror-service
# Entrypoint for the Tillandsias git service container.
# Runs git daemon in foreground, serving all repositories under /srv/git.
# Forge containers push here; post-receive hooks mirror to configured remotes.
# DISTRO: Alpine 3.20 — bash installed explicitly via apk add bash.
#         Uses POSIX-compatible constructs only (no [[ ]], no arrays).

# @trace spec:runtime-diagnostics
# Try the canonical strategic log path first, fall back to /dev/null when the
# container is launched with --read-only and /strategic isn't a tmpfs.
SLOG=/strategic/service.log
{ echo "$(date -Is) [git-service] starting git daemon on port 9418" >> "$SLOG"; } 2>/dev/null || SLOG=/dev/null

echo "========================================"
echo "  tillandsias git service"
echo "  listening on :9418"
echo "  base-path: /srv/git"
echo "========================================"

# GitHub token credential discovery.
# @trace spec:tillandsias-vault, spec:podman-secrets-integration, spec:git-mirror-service
# The launcher mints a short-lived AppRole token scoped to `git-mirror-policy`
# and mounts it at /run/secrets/vault-token. The post-receive hook calls
# `vault-cli read -field=token secret/github/token` at push time to fetch the
# real GitHub token. The token never lives on disk; it is read into a
# process-scoped variable, consumed by `git push`, and unset.
if [ -r /run/secrets/vault-token ]; then
    echo "Vault AppRole token loaded; GitHub token will be read at push time via vault-cli."
else
    echo "No credential source available; authenticated git operations will fail."
fi

# CA certificate from podman secret.
# @trace spec:podman-secrets-integration, spec:git-mirror-service
# Git CLI uses GIT_SSL_CAINFO to trust custom CA certificates.
# This allows explicit-refspec git pushes to work through the enclave proxy.
if [ -f /run/secrets/tillandsias-ca-cert ]; then
    export GIT_SSL_CAINFO
    GIT_SSL_CAINFO=/run/secrets/tillandsias-ca-cert
    echo "CA certificate loaded from podman secret."
fi

# @trace spec:git-mirror-service
# Seed the project's bare repo + install the post-receive hook.
#
# The forge pushes via `git://git-service/<project>` (see
# `rewrite_origin_for_enclave_push` in images/default/lib-common.sh). The bare
# repo at /srv/git/<project> is what `git daemon --base-path=/srv/git` serves
# for the path `/<project>`. Without this block the daemon would respond with
# "fatal: '/<project>' does not appear to be a git repository" on the very
# first push.
#
# Idempotent: re-running on each container start only re-creates files that
# don't exist yet. The bare repo lives on a named podman volume mounted at
# /srv/git so committed objects survive container restarts.
if [ -n "$PROJECT" ]; then
    PROJECT_REPO=/srv/git/"$PROJECT"
    if [ ! -d "$PROJECT_REPO" ]; then
        echo "[git-service] initializing bare repo at $PROJECT_REPO"
        git init --bare "$PROJECT_REPO"
        # Accept whatever the forge pushes — initial syncs from a host clone
        # often look like force-pushes from the bare repo's perspective. The
        # post-receive hook forwards only the changed refs upstream; locally we
        # just accept the forge's update into the sparse mirror.
        git -C "$PROJECT_REPO" config receive.denyNonFastforwards false
        git -C "$PROJECT_REPO" config receive.denyDeletes false
    fi
    if [ -n "$TILLANDSIAS_PROJECT_REMOTE_URL" ]; then
        # Redact any embedded credentials in the URL we log (defense in depth;
        # the launcher should pass a clean URL).
        REDACTED_URL="$(echo "$TILLANDSIAS_PROJECT_REMOTE_URL" | sed -E 's#https://[^@/]+@#https://***@#')"
        echo "[git-service] setting $PROJECT_REPO origin to $REDACTED_URL"
        git -C "$PROJECT_REPO" remote remove origin 2>/dev/null || true
        git -C "$PROJECT_REPO" remote add origin "$TILLANDSIAS_PROJECT_REMOTE_URL"
    else
        echo "[git-service] no TILLANDSIAS_PROJECT_REMOTE_URL set; post-receive hook will log and skip"
    fi
    if [ ! -e "$PROJECT_REPO/hooks/post-receive" ]; then
        cp /usr/local/share/git-service/post-receive-hook.sh "$PROJECT_REPO/hooks/post-receive"
        chmod +x "$PROJECT_REPO/hooks/post-receive"
        echo "[git-service] installed post-receive hook at $PROJECT_REPO/hooks/post-receive"
    fi
fi

# @trace spec:git-mirror-service
# Retry-on-startup: re-push refs that may have been stranded from a previous
# session (e.g. GitHub was transiently down when the post-receive hook ran).
#
# CRITICAL: We push EACH LOCAL BRANCH and EACH LOCAL TAG by name, NOT with
# `git push --mirror`. The mirror is a sparse cache holding only refs the
# forge has touched — `--mirror` would delete every branch and tag upstream
# that this enclave doesn't have, which nearly destroyed the upstream repo
# before wave 24. Always use the explicit per-ref form here.
#
# Errors are logged but don't block the daemon; the next forge commit will
# trigger the post-receive hook which re-attempts the upstream push.
# Pick a writable log path. Under --read-only the bind-mounted /var/log/...
# isn't always available; fall through to /tmp (the image's tmpfs) or skip.
GIT_RETRY_LOG=""
for candidate in /var/log/tillandsias/git-push.log /tmp/git-push.log; do
    dir="$(dirname "$candidate")"
    if [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null; then
        if { : >> "$candidate"; } 2>/dev/null; then
            GIT_RETRY_LOG="$candidate"
            break
        fi
    fi
done
retry_msg() {
    local timestamp
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo '?')"
    if [ -n "$GIT_RETRY_LOG" ]; then
        { echo "$timestamp $1" >> "$GIT_RETRY_LOG"; } 2>/dev/null || true
    fi
    echo "$1"
}
# Only do this on a real mirror tree (skip empty/init'ing service).
#
# Safety: build an explicit refspec list from this mirror's local refs.
# Anything not in /srv/git/<project>/refs/ is NOT touched upstream. We never
# pass `--mirror` or `--all` here because the mirror is sparse by design.
for mirror in /srv/git/*; do
    [ -d "$mirror" ] || continue
    REMOTE="$(git -C "$mirror" remote get-url origin 2>/dev/null || true)"
    [ -n "$REMOTE" ] || continue

    # Skip mirrors that have no refs yet (freshly seeded, nothing to push).
    if ! git -C "$mirror" rev-parse --quiet --verify HEAD >/dev/null 2>&1 \
       && [ -z "$(git -C "$mirror" for-each-ref --format='%(refname)' refs/heads refs/tags 2>/dev/null)" ]; then
        retry_msg "[git-mirror] Startup retry-push: $mirror has no refs yet, skipping"
        continue
    fi

    # Build refspecs: "refs/heads/<name>:refs/heads/<name>" for each branch,
    # "refs/tags/<name>:refs/tags/<name>" for each tag.
    REFSPECS=""
    for ref in $(git -C "$mirror" for-each-ref --format='%(refname)' refs/heads refs/tags 2>/dev/null); do
        REFSPECS="$REFSPECS $ref:$ref"
    done
    if [ -z "$REFSPECS" ]; then
        continue
    fi
    retry_msg "[git-mirror] Startup retry-push: $mirror -> $REMOTE (refspecs=$(echo "$REFSPECS" | wc -w))"
    # shellcheck disable=SC2086
    if OUTPUT="$(git -C "$mirror" push origin $REFSPECS 2>&1)"; then
        retry_msg "[git-mirror] Startup retry-push OK"
    else
        retry_msg "[git-mirror] Startup retry-push FAILED: $OUTPUT"
    fi
done

echo "$(date -Is) [git-service] daemon ready" >> "$SLOG"

# Run git daemon as PID 1 so it receives signals properly.
exec git daemon \
    --reuseaddr \
    --export-all \
    --enable=receive-pack \
    --base-path=/srv/git \
    --listen=0.0.0.0 \
    --port=9418 \
    --verbose
