#!/usr/bin/env bash
# @trace spec:tillandsias-vault
# claude-approvals-vault — restore/harvest the operator's one-time interactive
# approvals (workspace trust, onboarding/theme) for claude forge sessions,
# the same rail provider-oauth-vault rides for the OAuth document (operator
# directive 2026-08-31: "prompt the first time — those are valid prompts —
# then save the verified approval in the vault, just like the auth tokens;
# one approval on the first launch is acceptable, as long as it's not on
# every launch").
#
# The bypass-permissions consent (bypassPermissionsModeAccepted) is no
# longer made durable by this file (order 1437-y2wu, operator directive
# 2026-09-27: pre-accept it, for all projects, for all harnesses). It is
# SEEDED at launch by lib-common.sh::seed_claude_bypass_consent, forge-gated,
# before restore_approvals below ever runs — so a Vault wipe cannot bring the
# dialog back. This file still extracts/restores that key when present (a
# harmless no-op once the seed has already set it — restore's deep-merge
# gives the live config priority), but nothing depends on it doing so.
#
#   restore  vault -> deep-merge the approval keys into ~/.claude.json
#            (additive; a fresh prompt-and-approve always wins over vault)
#   harvest  extract the approval keys from ~/.claude.json -> vault
#   digest   sha of the extracted approval doc (change detection)
#   watch    harvest on each write of the config (an inotify event; a poll
#            while CHILD_PID lives only on an image without inotify-tools) —
#            catches the operator's first-ever approval right after the click
#
# The doc contains only booleans and project paths — no credentials — but it
# rides the same scoped vault path discipline as everything else.
set -uo pipefail

USER_CFG="${CLAUDE_CONFIG_FILE:-$HOME/.claude.json}"
VAULT_PATH="secret/claude/approvals"
VAULT_CLI="${TILLANDSIAS_VAULT_CLI:-/usr/local/bin/vault-cli.sh}"

extract_approvals() {
    [[ -s "$USER_CFG" ]] || { printf '{}'; return 0; }
    jq -c '{hasCompletedOnboarding, theme, bypassPermissionsModeAccepted,
            projects: ((.projects // {}) | with_entries(.value |= {hasTrustDialogAccepted}))}
           | with_entries(select(.value != null))' "$USER_CFG" 2>/dev/null || printf '{}'
}

restore_approvals() {
    local doc tmp
    doc="$("$VAULT_CLI" read -field=approvals_b64 "$VAULT_PATH" 2>/dev/null | base64 -d 2>/dev/null)" || doc=''
    [[ -n "$doc" ]] || { echo "[approvals] no vault doc yet — first launch will prompt once and harvest" >&2; return 0; }
    printf '%s' "$doc" | jq -e 'type == "object"' >/dev/null 2>&1 || { echo "[approvals] vault doc invalid; ignoring" >&2; return 0; }
    mkdir -p "$(dirname "$USER_CFG")"
    [[ -s "$USER_CFG" ]] || printf '{}\n' >"$USER_CFG"
    tmp="$(mktemp "${USER_CFG}.tmp.XXXXXX")" || return 1
    # Deep-merge, vault filling gaps only: live config wins where it has a
    # value, so a re-prompted fresh approval is never clobbered by history.
    jq --argjson v "$doc" '
        ($v * .) |
        .projects = (($v.projects // {}) * (.projects // {}))' \
        "$USER_CFG" >"$tmp" || { rm -f "$tmp"; return 1; }
    chmod 600 "$tmp"
    mv -f "$tmp" "$USER_CFG"
    echo "[approvals] restored from vault" >&2
}

harvest_approvals() {
    local doc
    doc="$(extract_approvals)"
    [[ "$doc" != '{}' && -n "$doc" ]] || return 0
    printf '%s' "$doc" | base64 -w0 | \
        "$VAULT_CLI" write-stdin "$VAULT_PATH" approvals_b64 >/dev/null
}

approvals_digest() { extract_approvals | sha256sum | awk '{print $1}'; }

# Operator approval 2026-10-28 (1914-twan): copy on an inotify event, not a
# 3 s poll (1,200 wakeups an hour, each running jq over the whole config).
harvest_if_changed() {
    current="$(approvals_digest)"
    if [[ "$current" != "$last" ]]; then
        harvest_approvals && last="$current"
    fi
}

watch_approvals() {
    local child_pid="$1" poll_secs last current cfg_dir name inw_pid beat
    last="$(approvals_digest)"
    cfg_dir="$(dirname "$USER_CFG")"
    if command -v inotifywait >/dev/null 2>&1 && [[ -d "$cfg_dir" ]]; then
        # Claude rewrites the config in place or by rename. 2076-w7kd: a
        # session that dies without stopping this watcher must not leave it
        # blocked on an event that never comes, so the child is re-checked
        # on every quiet beat and the last harvest after the loop still runs.
        exec 3< <(exec inotifywait -m -e close_write,moved_to --format '%f' "$cfg_dir" 2>&1)
        inw_pid=$!
        trap 'kill "$inw_pid" 2>/dev/null; exit 0' TERM INT
        beat="${TILLANDSIAS_APPROVALS_WATCH_BEAT_SECS:-5}"
        while kill -0 "$child_pid" 2>/dev/null; do
            if read -r -t "$beat" name <&3; then
                case "$name" in
                    # Catch a write made before the watch existed.
                    "Watches established.") harvest_if_changed ;;
                    "$(basename "$USER_CFG")") harvest_if_changed ;;
                esac
            elif (( $? <= 128 )); then
                # inotifywait went away (EOF): keep watching by polling.
                break
            fi
        done
        kill "$inw_pid" 2>/dev/null || true
        exec 3<&-
        trap - TERM INT
    fi
    poll_secs="${TILLANDSIAS_APPROVALS_POLL_SECS:-3}"
    while kill -0 "$child_pid" 2>/dev/null; do
        sleep "$poll_secs"
        harvest_if_changed
    done
    harvest_approvals || true
}

case "${1:-}" in
    restore) restore_approvals ;;
    harvest) harvest_approvals ;;
    digest) approvals_digest ;;
    watch)
        [[ "${2:-}" =~ ^[0-9]+$ ]] || { echo "Usage: claude-approvals-vault watch CHILD_PID" >&2; exit 64; }
        watch_approvals "$2"
        ;;
    *) echo "Usage: claude-approvals-vault {restore|harvest|digest|watch CHILD_PID}" >&2; exit 64 ;;
esac
