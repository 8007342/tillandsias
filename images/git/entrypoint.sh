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

# @trace spec:tillandsias-vault, spec:git-mirror-service
# Background token-renewer (order 414). The launcher mints the git-mirror's
# AppRole token with a 1h default TTL (APPROLE_TOKEN_TTL_SECS=3600) and a 24h
# max TTL. The mirror container outlives 1h, but nothing renewed the token, so
# every forge session past the first hour lost push capability: the relay's
# `vault-cli read secret/github/token` 403'd, the failure was swallowed, and
# the push was rejected as "run GitHub Login" — a FALSE error, since the GitHub
# token in Vault was fine (blocker-git-mirror-relay-token-expiry-2026-07-18).
#
# This heartbeat renews the token well inside its TTL so it stays valid up to
# the 24h ceiling. Renewal MUST happen while the token is still live — once it
# has expired, renew-self 403s and only a re-mint (relaunch the forge, which
# uses `--replace`) recovers. Interval defaults to 30 min (< the 1h TTL);
# override with VAULT_TOKEN_RENEW_INTERVAL for tests.
VAULT_TOKEN_RENEW_INTERVAL="${VAULT_TOKEN_RENEW_INTERVAL:-1800}"
start_vault_token_renewer() {
    if [ ! -r /run/secrets/vault-token ] || ! command -v vault-cli >/dev/null 2>&1; then
        return 0
    fi
    (
        while true; do
            sleep "$VAULT_TOKEN_RENEW_INTERVAL"
            if lease="$(vault-cli renew-self "$VAULT_TOKEN_RENEW_INTERVAL" 2>/dev/null)"; then
                echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') [vault-renewer] git-mirror token renewed (lease_duration=${lease:-?}s)"
            else
                # renew-self failed: the token hit its 24h max TTL or already
                # expired. It can no longer be kept alive from inside the
                # container — surface the honest remedy loudly; the next push
                # will reject with the same expired-token diagnosis.
                echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') [vault-renewer] WARNING: git-mirror Vault token can no longer be renewed (max TTL reached or expired). Relaunch the forge to re-mint (build_git_run_args --replace)." >&2
            fi
        done
    ) &
    VAULT_RENEWER_PID=$!
    echo "[git-service] vault token-renewer started (pid=$VAULT_RENEWER_PID, every ${VAULT_TOKEN_RENEW_INTERVAL}s)"
}

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
        # @trace spec:git-mirror-service
        # Unborn-HEAD fix (2026-07-20): `git init --bare` points HEAD at
        # refs/heads/master (Alpine default). Upstream may have NO master, so
        # a clone of the seeded mirror exits 0 with "remote HEAD refers to
        # nonexistent ref" and an EMPTY working tree — which the order-452
        # guest assert then escalates to a deterministic crash of EVERY
        # harness launch. Point HEAD at the launcher-declared branch NOW
        # (symbolic-ref accepts unborn branches); the seed fetch below makes
        # it cloneable, and ensure-mirror-head repairs volumes created before
        # this fix. plan/issues/mirror-bare-repo-unborn-head-breaks-all-clones-2026-07-20.md
        if [ -n "$TILLANDSIAS_PROJECT_DEFAULT_BRANCH" ]; then
            git -C "$PROJECT_REPO" symbolic-ref HEAD "refs/heads/$TILLANDSIAS_PROJECT_DEFAULT_BRANCH"
            echo "[git-service] HEAD -> refs/heads/$TILLANDSIAS_PROJECT_DEFAULT_BRANCH (launcher default branch)"
        fi
    fi
    # http.receivepack is deliberately NOT enabled (order 423/426). Git
    # documents it as enabling push "for all users, including anonymous users",
    # and the mirror serves no authenticated HTTP. All forge transport is
    # git:// (see write_forge_gitconfig, which injects
    # url.git://tillandsias-git/<project>.insteadOf). Leaving it on gave the
    # mirror a second anonymous write path with no consumer.
    git -C "$PROJECT_REPO" config --unset-all http.receivepack 2>/dev/null || true
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

# @trace spec:git-mirror-service
# ensure-mirror-head repairs an unborn HEAD (see the script's header and
# plan/issues/mirror-bare-repo-unborn-head-breaks-all-clones-2026-07-20.md).
# ENSURE_HEAD is overridable so offline fixtures exercise the exact same
# implementation this entrypoint runs (same pattern as RELAY_REF below).
# Exit 3 (no heads yet — still seeding) is expected and non-fatal.
ENSURE_HEAD="${ENSURE_HEAD:-/usr/local/share/git-service/ensure-mirror-head}"
ensure_mirror_head() {
    OUT="$("$ENSURE_HEAD" "$1" 2>&1)" && rc=0 || rc=$?
    [ -n "$OUT" ] && retry_msg "[git-mirror] $OUT"
    [ "$rc" -eq 3 ] && return 0
    return "$rc"
}

# @trace spec:git-mirror-service
# Order 449: continuous bounded-window reconcile. The mirror used to advance
# its EXPORTED heads from upstream only at container start (452) or on a push
# failure, so a host coordinator pushing DIRECT to origin left long-lived
# mirrors serving stale heads mid-session — a forge agent cloned stale,
# committed, and its push diverged (Hy3, live 2026-07-20). This loop runs the
# same NON-forced exported-head fast-forward every RECONCILE_INTERVAL seconds
# (default 120 — the "bounded window" of order 449's exit criterion), via the
# shared reconcile-exported-heads pass (RECONCILE_HEADS overridable so
# fixtures exercise the exact same implementation). Diverged heads carrying
# un-relayed agent commits are never clobbered (non-forced); offline
# upstreams keep serving last-known-good heads.
RECONCILE_HEADS="${RECONCILE_HEADS:-/usr/local/share/git-service/reconcile-exported-heads}"
MIRROR_RECONCILE_INTERVAL="${MIRROR_RECONCILE_INTERVAL:-120}"
MIRROR_RECONCILER_PID=""
start_mirror_reconciler() {
    if [ ! -x "$RECONCILE_HEADS" ]; then
        retry_msg "[git-mirror] periodic reconciler NOT started: $RECONCILE_HEADS missing"
        return 0
    fi
    (
        while true; do
            sleep "$MIRROR_RECONCILE_INTERVAL"
            for m in /srv/git/*; do
                [ -d "$m" ] || continue
                OUT="$("$RECONCILE_HEADS" "$m" 2>&1)" || true
                [ -n "$OUT" ] && retry_msg "[git-mirror] periodic: $OUT"
            done
        done
    ) &
    MIRROR_RECONCILER_PID=$!
    echo "[git-service] periodic exported-head reconciler started (pid=$MIRROR_RECONCILER_PID, every ${MIRROR_RECONCILE_INTERVAL}s)"
}

# ── Order 437/441: START THE DAEMON FIRST ──────────────────────────────
# Clone-only forges (order 437) clone from git://tillandsias-git the instant
# they launch, and the per-ref startup retry-push (order 441) can take minutes
# over a large ref set. When the daemon started only AFTER that sweep, every
# forge launched during the sweep failed its clone with "connection refused"
# and crashed (live 2026-07-20: Codex and OpenCode both died on clone). The
# sweep is a BACKGROUND recovery task and must not gate the daemon that serves
# clones. So: renewer + trap + daemon come up here; the sweep runs afterwards
# while the daemon already serves.
VAULT_RENEWER_PID=""
start_vault_token_renewer
start_mirror_reconciler
trap 'echo "[git-service] shutting down..."; kill -TERM "$GIT_DAEMON_PID" $VAULT_RENEWER_PID $MIRROR_RECONCILER_PID 2>/dev/null; exit 0' SIGTERM SIGINT
# receive-pack IS enabled — it is the forge's live push path (order 450).
#
# Order 423 removed --enable=receive-pack to close an "anonymous write path",
# but the authenticated replacement (order 322, smart HTTP) never shipped, so
# every forge push broke ("access denied or repository not exported"). Diagnosed
# by Hy3 in-forge 2026-07-20.
#
# Why re-enabling is acceptable HERE (and why 423 over-corrected for this
# service): the daemon serves ONLY the enclave (--internal network, no internet
# route), so the internet-anonymous-write threat git-daemon(1) warns about does
# not apply. Every container that can reach it is one of the operator's own
# forge agents, which legitimately push by design. The REAL boundaries are
# downstream and unchanged: the pre-receive relay authenticates to GitHub with
# the Vault-held token, and relay-refs.sh never uses --mirror/--all and guards
# bulk deletes — so a rogue push cannot destroy upstream. Order 322 (per-agent
# authenticated smart HTTP) remains the proper fix for a multi-tenant future;
# until then, receive-pack on the internal-only daemon is the working push path.
# The order-423 LIGHTTPD/git-http-backend removal stays — that WAS dead code and
# a genuine anonymous path; only this live daemon push path is restored.
git daemon \
    --reuseaddr \
    --export-all \
    --enable=receive-pack \
    --base-path=/srv/git \
    --listen=0.0.0.0 \
    --port=9418 \
    --verbose &
GIT_DAEMON_PID=$!
echo "$(date -Is) [git-service] daemon listening on 9418 (clones available; startup sweep runs in background)" >> "$SLOG"

# Only do this on a real mirror tree (skip empty/init'ing service).
#
# Safety: build an explicit refspec list from this mirror's local refs.
# Anything not in /srv/git/<project>/refs/ is NOT touched upstream. We never
# pass `--mirror` or `--all` here because the mirror is sparse by design.
for mirror in /srv/git/*; do
    [ -d "$mirror" ] || continue
    # Repair an unborn HEAD on ANY mirror before transport work — including
    # local-only mirrors (no origin) that skip the fetch paths below but
    # already hold forge-pushed heads a clone must be able to check out.
    ensure_mirror_head "$mirror" || true
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
        # The seed just wrote refs/heads/* into a repo whose HEAD may still
        # point at a branch upstream never had (unborn-HEAD defect). Repoint
        # HEAD now so the very first clone checks out a real branch.
        ensure_mirror_head "$mirror" || true
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

    # @trace spec:git-mirror-service
    # Coherence (order 449): advance this mirror's EXPORTED heads to upstream
    # where fast-forwardable, so a forge cloning over git:// gets CURRENT code.
    # The fetch above only populates refs/remotes/origin/* (tracking refs); the
    # cloneable refs/heads/* are NOT advanced by it. Without this step a mirror
    # left behind GitHub — e.g. the host pushed DIRECT to origin (order 449) —
    # keeps serving STALE heads; a forge then commits on stale and its push is
    # rejected non-fast-forward. That is the coherence break Hy3 hit 2026-07-20
    # and the reason concurrent forges could not push transparently.
    # NON-forced (NO leading '+'): a head carrying local un-relayed commits that
    # would need a rewind is LEFT ALONE (fetch reports "[rejected] non-fast-
    # forward") and is relayed UP by the per-ref push below. This is the
    # GitHub->mirror direction; the per-ref retry-push below is mirror->GitHub —
    # together they keep the mirror coherent both ways. Never --mirror/--all:
    # only the explicit exported refs/heads/* set (same sparse-mirror invariant
    # as the seed and relay paths).
    FF_OUTPUT="$(git -C "$mirror" fetch origin 'refs/heads/*:refs/heads/*' 2>&1)" || retry_msg "[git-mirror] Startup exported-head fast-forward (non-fatal; diverged heads relay UP below): $FF_OUTPUT"
    if [ -n "$FF_OUTPUT" ]; then
        retry_msg "[git-mirror] Startup exported-head fast-forward: $FF_OUTPUT"
    fi
    # New heads may have just arrived (e.g. an existing volume whose seed
    # predates the unborn-HEAD fix); make sure HEAD names a cloneable one.
    ensure_mirror_head "$mirror" || true

    # Per-ref relay (order 441): the OLD sweep fed ALL refs to one
    # `git push --atomic` call, so a single stranded (non-fast-forward) ref
    # rejected the ENTIRE transaction and no fast-forwardable ref was flushed.
    # We now relay each ref as its own atomic transaction: a fast-forwardable
    # ref reaches upstream even when a sibling ref is stranded, and a stranded
    # ref is logged BY NAME rather than silently failing the whole sweep. The
    # LIVE single-push path (relay-refs.sh) keeps its own `git push --atomic`
    # and the never-`--mirror`/`--all` invariant untouched.
    #
    # RELAY_REF is overridable (fixtures point it at a mock) so the per-ref
    # loop can be exercised offline.
    RELAY_REF="${RELAY_REF:-hooks/tillandsias-relay-refs}"
    retry_msg "[git-mirror] Startup retry-push: $mirror -> $REMOTE (refs=$REF_COUNT, per-ref)"
    stranded=""
    for ref in $(git -C "$mirror" for-each-ref --format='%(refname)' refs/heads refs/tags 2>/dev/null); do
        NEWSHA="$(git -C "$mirror" rev-parse "$ref")"
        RECORD="${ZERO_SHA} ${NEWSHA} ${ref}"
        if OUTPUT="$(printf '%s\n' "$RECORD" | (cd "$mirror" && "${RELAY_REF}") 2>&1)"; then
            retry_msg "[git-mirror] Startup retry-push OK: $ref"
        else
            retry_msg "[git-mirror] Startup retry-push STRANDED (logged by name): $ref — $OUTPUT"
            stranded="${stranded:+$stranded }$ref"
        fi
    done
    if [ -n "$stranded" ]; then
        retry_msg "[git-mirror] Startup retry-push: $REF_COUNT ref(s) attempted; stranded=$stranded"
    fi
done

echo "$(date -Is) [git-service] startup sweep complete" >> "$SLOG"

# The git daemon, vault renewer, and shutdown trap were all started ABOVE, before
# the startup sweep, so clones are served the instant the container is up (order
# 437/441). Nothing to start here — just wait on the daemon we already launched.

# Wait for the daemon (started before the sweep) to exit.
wait "$GIT_DAEMON_PID"
