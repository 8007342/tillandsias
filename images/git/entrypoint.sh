#!/bin/bash
set -e
# @trace spec:git-mirror-service
# Entrypoint for the Tillandsias git service container.
# Runs git daemon in foreground, serving all repositories under /srv/git.
# Forge containers push here; pre-receive relays to configured upstreams.
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
# and mounts it at /run/secrets/vault-token. The relay helper calls
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
# Seed the project's bare repo + install the receive hooks.
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
        # pre-receive hook atomically forwards only the changed refs upstream
        # before this sparse mirror accepts the same transaction.
        git -C "$PROJECT_REPO" config receive.denyNonFastforwards false
        git -C "$PROJECT_REPO" config receive.denyDeletes false
    fi
    # Always ensure http.receivepack is enabled so we can push via HTTP
    git -C "$PROJECT_REPO" config http.receivepack true
    if [ -n "$TILLANDSIAS_PROJECT_REMOTE_URL" ]; then
        # Redact any embedded credentials in the URL we log (defense in depth;
        # the launcher should pass a clean URL).
        REDACTED_URL="$(echo "$TILLANDSIAS_PROJECT_REMOTE_URL" | sed -E 's#https://[^@/]+@#https://***@#')"
        echo "[git-service] setting $PROJECT_REPO origin to $REDACTED_URL"
        git -C "$PROJECT_REPO" remote remove origin 2>/dev/null || true
        git -C "$PROJECT_REPO" remote add origin "$TILLANDSIAS_PROJECT_REMOTE_URL"
        # @trace spec:git-mirror-service
        # Reconciliation fetches land in remote-tracking refs ONLY. The old
        # "+refs/*:refs/*" mapped upstream branches directly onto the mirror's
        # EXPORTED refs/heads/*, so a reconcile fetch run while upstream was
        # stale force-overwrote a just-received branch before the post-receive
        # hook relayed it — GitHub advanced, the mirror stayed behind, and only
        # an identical second push converged them (order 301). tagOpt=--no-tags
        # stops implicit tag writes during that reconcile fetch. Empty mirrors
        # are seeded with an explicit heads/tags refspec in the retry loop.
        git -C "$PROJECT_REPO" config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
        git -C "$PROJECT_REPO" config remote.origin.tagOpt "--no-tags"
    else
        echo "[git-service] no TILLANDSIAS_PROJECT_REMOTE_URL set; pushes remain durable in the local-only mirror"
    fi
    # Hooks are Tillandsias-owned runtime code. Refresh them on every start so
    # existing named volumes cannot retain obsolete ack semantics after an
    # image upgrade.
    cp /usr/local/share/git-service/post-receive-hook.sh "$PROJECT_REPO/hooks/post-receive"
    cp /usr/local/share/git-service/pre-receive-hook.sh "$PROJECT_REPO/hooks/pre-receive"
    cp /usr/local/share/git-service/relay-refs.sh "$PROJECT_REPO/hooks/tillandsias-relay-refs"
    chmod +x "$PROJECT_REPO/hooks/post-receive" \
        "$PROJECT_REPO/hooks/pre-receive" \
        "$PROJECT_REPO/hooks/tillandsias-relay-refs"
    echo "[git-service] refreshed relay-verified receive hooks at $PROJECT_REPO/hooks"
fi

# @trace spec:git-mirror-service
# Retry-on-startup: re-push refs that may have been stranded from a previous
# session created by an older image with post-receive relay semantics.
#
# CRITICAL: We push EACH LOCAL BRANCH and EACH LOCAL TAG by name, NOT with
# `git push --mirror`. The mirror is a sparse cache holding only refs the
# forge has touched — `--mirror` would delete every branch and tag upstream
# that this enclave doesn't have, which nearly destroyed the upstream repo
# before wave 24. Always use the explicit per-ref form here.
#
# Errors are logged but don't block the daemon; the next forge commit will
# trigger the pre-receive relay, which fails the client push if upstream is
# still unavailable.
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

    # Seed an empty mirror or skip if it has no upstream
    if ! git -C "$mirror" rev-parse --quiet --verify HEAD >/dev/null 2>&1 \
       && [ -z "$(git -C "$mirror" for-each-ref --format='%(refname)' refs/heads refs/tags 2>/dev/null)" ]; then
        retry_msg "[git-mirror] Startup: $mirror has no refs but has origin. Fetching upstream to seed mirror."
        # @trace spec:git-mirror-service
        # Seed the exported refs explicitly. The configured default refspec only
        # populates refs/remotes/origin/* (safe reconciliation), which would
        # leave a fresh mirror with no cloneable heads/tags. This one-time seed
        # writes local heads and tags directly so clones over the git daemon see
        # them; subsequent reconcile fetches use the safe tracking refspec.
        FETCH_OUTPUT="$(git -C "$mirror" fetch origin '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*' 2>&1)" || retry_msg "[git-mirror] Seed fetch failed: $FETCH_OUTPUT"
        continue
    fi

    # Build synthetic receive records so startup recovery uses the exact same
    # Vault-backed, atomic relay helper as live pushes.
    UPDATE_RECORDS=""
    REF_COUNT=0
    ZERO_SHA="0000000000000000000000000000000000000000"
    for ref in $(git -C "$mirror" for-each-ref --format='%(refname)' refs/heads refs/tags 2>/dev/null); do
        NEWSHA="$(git -C "$mirror" rev-parse "$ref")"
        UPDATE_RECORDS="${UPDATE_RECORDS}${ZERO_SHA} ${NEWSHA} ${ref}
"
        REF_COUNT=$((REF_COUNT + 1))
    done
    if [ "$REF_COUNT" -eq 0 ]; then
        continue
    fi

    # @trace spec:git-mirror-service
    # Fetch upstream state before the retry push so we don't get rejected for
    # non-fast-forward when the mirror was behind GitHub during the previous
    # session's post-receive relay. A fetch failure is non-fatal — the push
    # will fail visibly and the next forge commit will trigger a fresh relay.
    FETCH_OUTPUT="$(git -C "$mirror" fetch origin 2>&1)" || retry_msg "[git-mirror] Startup retry-push fetch failed (non-fatal): $FETCH_OUTPUT"
    if [ -n "$FETCH_OUTPUT" ]; then
        retry_msg "[git-mirror] Startup retry-push fetch output: $FETCH_OUTPUT"
    fi

    retry_msg "[git-mirror] Startup retry-push: $mirror -> $REMOTE (refs=$REF_COUNT)"
    if OUTPUT="$(printf '%s' "$UPDATE_RECORDS" | (cd "$mirror" && hooks/tillandsias-relay-refs) 2>&1)"; then
        retry_msg "[git-mirror] Startup retry-push OK"
    else
        retry_msg "[git-mirror] Startup retry-push FAILED: $OUTPUT"
    fi
done

echo "$(date -Is) [git-service] daemon ready" >> "$SLOG"

# Propagate shutdown signals (SIGTERM, SIGINT) to child processes
trap 'echo "[git-service] shutting down..."; kill -TERM "$LIGHTTPD_PID" "$GIT_DAEMON_PID" 2>/dev/null; exit 0' SIGTERM SIGINT

# Start lighttpd for git HTTP smart protocol support.
echo "[git-service] starting lighttpd on port 8080"
lighttpd -D -f /usr/local/share/git-service/lighttpd.conf &
LIGHTTPD_PID=$!

# Run git daemon on port 9418 in background.
git daemon \
    --reuseaddr \
    --export-all \
    --enable=receive-pack \
    --base-path=/srv/git \
    --listen=0.0.0.0 \
    --port=9418 \
    --verbose &
GIT_DAEMON_PID=$!

# Wait for background services to complete
wait "$LIGHTTPD_PID" "$GIT_DAEMON_PID"
