#!/usr/bin/env bash
# @trace spec:tillandsias-vault
# claude-approvals-vault — restore/harvest the operator's one-time interactive
# approvals (workspace trust, bypass-permissions consent, onboarding/theme)
# for claude forge sessions, the same rail provider-oauth-vault rides for the
# OAuth document (operator directive 2026-08-31: "prompt the first time —
# those are valid prompts — then save the verified approval in the vault,
# just like the auth tokens; one approval on the first launch is acceptable,
# as long as it's not on every launch").
#
#   restore  vault -> deep-merge the approval keys into ~/.claude.json
#            (additive; a fresh prompt-and-approve always wins over vault)
#   harvest  extract the approval keys from ~/.claude.json -> vault
#   digest   sha of the extracted approval doc (change detection)
#   watch    poll while CHILD_PID lives; harvest on change — catches the
#            operator's first-ever approval within seconds of the click
#
# The doc contains only booleans and project paths — no credentials — but it
# rides the same scoped vault path discipline as everything else.
set -uo pipefail

USER_CFG="${CLAUDE_CONFIG_FILE:-$HOME/.claude.json}"
VAULT_PATH="secret/claude/approvals"

extract_approvals() {
    [[ -s "$USER_CFG" ]] || { printf '{}'; return 0; }
    jq -c '{hasCompletedOnboarding, theme, bypassPermissionsModeAccepted,
            projects: ((.projects // {}) | with_entries(.value |= {hasTrustDialogAccepted}))}
           | with_entries(select(.value != null))' "$USER_CFG" 2>/dev/null || printf '{}'
}

restore_approvals() {
    local doc tmp
    doc="$(/usr/local/bin/vault-cli.sh read -field=approvals_b64 "$VAULT_PATH" 2>/dev/null | base64 -d 2>/dev/null)" || doc=''
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
        /usr/local/bin/vault-cli.sh write-stdin "$VAULT_PATH" approvals_b64 >/dev/null
}

approvals_digest() { extract_approvals | sha256sum | awk '{print $1}'; }

watch_approvals() {
    local child_pid="$1" poll_secs last current
    poll_secs="${TILLANDSIAS_APPROVALS_POLL_SECS:-3}"
    last="$(approvals_digest)"
    while kill -0 "$child_pid" 2>/dev/null; do
        sleep "$poll_secs"
        current="$(approvals_digest)"
        if [[ "$current" != "$last" ]]; then
            harvest_approvals && last="$current"
        fi
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
