#!/usr/bin/env bash
# @trace spec:tillandsias-vault
set -euo pipefail

# CODEX_HOME-aware (order 428): when a worker is given its own CODEX_HOME for
# concurrency isolation, the vault restore MUST write where codex actually
# reads. Hardcoding $HOME/.codex here would silently place the credential in a
# directory codex never consults — the same class of defect as order 430.
AUTH_FILE="${TILLANDSIAS_CODEX_AUTH_FILE:-${CODEX_HOME:-$HOME/.codex}/auth.json}"

restore_auth() {
    local auth_dir tmp
    auth_dir="$(dirname "$AUTH_FILE")"
    mkdir -p "$auth_dir"
    chmod 700 "$auth_dir"
    umask 077
    tmp="$(mktemp "$auth_dir/.auth.json.XXXXXX")"
    trap 'rm -f "$tmp"' RETURN

    if ! vault-cli.sh read -field=credentials_b64 secret/codex/oauth | base64 -d >"$tmp"; then
        echo "ERROR: Codex credentials are unavailable or invalid; run 'tillandsias --codex-login' in a terminal." >&2
        return 2
    fi
    if [[ ! -s "$tmp" ]] || ! jq -e 'type == "object"' "$tmp" >/dev/null; then
        echo "ERROR: Vault returned an invalid Codex credential document; rerun 'tillandsias --codex-login'." >&2
        return 3
    fi
    chmod 600 "$tmp"
    mv -f "$tmp" "$AUTH_FILE"
    trap - RETURN
}

harvest_auth() {
    if [[ ! -s "$AUTH_FILE" ]] || ! jq -e 'type == "object"' "$AUTH_FILE" >/dev/null; then
        return 0
    fi
    base64 -w0 <"$AUTH_FILE" | \
        vault-cli.sh write-stdin secret/codex/oauth credentials_b64 >/dev/null
}

auth_digest() {
    if [[ -s "$AUTH_FILE" ]]; then
        sha256sum "$AUTH_FILE" | awk '{print $1}'
    else
        printf 'missing'
    fi
}

# Order 1914-twan: Codex refresh tokens are single-use (its own
# REFRESH_TOKEN_REUSED_MESSAGE: "your refresh token was already used"), so a
# rotation Vault never receives leaves Vault holding a dead token. A failed
# copy is retried and reported on the lifecycle log, never only warned about.
harvest_with_retry() {
    local attempt
    for attempt in 1 2 3 4 5; do
        harvest_auth 2>/dev/null && return 0
        sleep "$attempt"
    done
    printf '%s\n' "[codex-oauth] blocked:codex-credential-copy-failed: Vault did not take the rotated Codex sign-in after 5 attempts; the next launch may need 'tillandsias --codex-login'" \
        | tee -a "${TILLANDSIAS_LIFECYCLE_LOG:-/tmp/forge-lifecycle.log}" >&2
    return 1
}

# Copy only when the file is written. Operator approval 2026-10-28 (1914-twan):
# an inotify event costs no idle wakeups, where the 2 s poll woke 1,800
# times an hour for a rotation that happens once or twice. The poll remains
# only for an image built before inotify-tools was in the forge base.
copy_if_changed() {
    current="$(auth_digest)"
    if [[ "$current" != "$last" && "$current" != missing ]]; then
        harvest_with_retry && last="$current"
    fi
}

watch_auth() {
    local child_pid="$1" initial_digest="${2:-}" poll_secs last current auth_dir inw_pid name
    last="${initial_digest:-$(auth_digest)}"
    auth_dir="$(dirname "$AUTH_FILE")"
    if command -v inotifywait >/dev/null 2>&1 && [[ -d "$auth_dir" ]]; then
        # Codex writes in place (close_write) or by rename (moved_to). The
        # wrapper stops this watcher with TERM; take inotifywait down with it.
        exec 3< <(exec inotifywait -m -e close_write,moved_to --format '%f' "$auth_dir" 2>&1)
        inw_pid=$!
        trap 'kill "$inw_pid" 2>/dev/null; exit 0' TERM INT
        while read -r name <&3; do
            case "$name" in
                # Catch a write made before the watch existed; from here on
                # every write is an event.
                "Watches established.") copy_if_changed ;;
                "$(basename "$AUTH_FILE")") copy_if_changed ;;
            esac
        done
        return 0
    fi
    poll_secs="${TILLANDSIAS_OAUTH_POLL_SECS:-2}"
    while kill -0 "$child_pid" 2>/dev/null; do
        sleep "$poll_secs"
        copy_if_changed
    done
    # The session ended, possibly by SIGKILL with no EXIT trap: copy a rotation
    # made since the last poll, or it is lost and the vaulted token is dead.
    copy_if_changed
}

case "${1:-}" in
    restore) restore_auth ;;
    harvest) harvest_auth ;;
    digest) auth_digest ;;
    watch)
        [[ "${2:-}" =~ ^[0-9]+$ ]] || { echo "Usage: codex-oauth-vault watch CHILD_PID" >&2; exit 64; }
        watch_auth "$2" "${3:-}"
        ;;
    *) echo "Usage: codex-oauth-vault {restore|harvest|digest|watch CHILD_PID [INITIAL_DIGEST]}" >&2; exit 64 ;;
esac
