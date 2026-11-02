#!/bin/sh
# @trace spec:git-mirror-service, spec:cross-platform, spec:windows-wsl-runtime
# Post-receive bookkeeping for Tillandsias mirrors.
#
# The must-succeed upstream relay runs in pre-receive. Post-receive cannot
# affect receive-pack's result, so it must never be used to establish durable
# acknowledgement semantics. This hook only records that the already-verified
# transaction was committed to the local mirror.

LOG_CANDIDATES="/var/log/tillandsias/git-push.log $HOME/.cache/tillandsias/git-push.log /tmp/git-push.log"
LOG_FILE=""
for candidate in $LOG_CANDIDATES; do
    dir="$(dirname "$candidate")"
    if [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null; then
        if : > "$candidate" 2>/dev/null || [ -w "$candidate" ]; then
            LOG_FILE="$candidate"
            break
        fi
    fi
done

log_msg() {
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo '?')"
    if [ -n "$LOG_FILE" ]; then
        echo "$timestamp [post-receive] $1" >> "$LOG_FILE" 2>/dev/null
    fi
    echo "[post-receive] $1" >&2
}

COUNT=0
while read -r OLDSHA NEWSHA REFNAME; do
    [ -n "$REFNAME" ] || continue
    COUNT=$((COUNT + 1))
done

if git remote get-url origin >/dev/null 2>&1; then
    log_msg "Committed $COUNT upstream-verified ref update(s) to the local mirror"
else
    log_msg "Committed $COUNT durable local-only ref update(s) (no upstream configured)"
fi

# 1827-3rj4: tell the fleet coordinator this project's namespace moved: ONE
# POST per push of {op: bump, ns, head_sha} to <url>/v1/op, the same request
# tillandsias-plan's coordinator client builds (ops::bump; wire fixture
# cloud/coordinator/test/fixtures/client-ops.json). This hook runs only after
# the pre-receive relay to GitHub succeeded, so the bump follows a real
# upstream change. curl, not the client binary: this image does not ship
# tillandsias-plan.
#
# Best-effort and DETACHED: everything below runs in a background subshell
# with bounded timeouts, so a slow, absent or misconfigured coordinator (or
# vault) never delays or fails the push. The Access service token comes from
# vault at hook time, lives only in that subshell and a 0600 header file that
# is removed at once, and is never logged or put on a command line.
# Unconfigured (no token in vault, the state until 1829-guit provisions it):
# one log line, no request.
COORD_SECRET_PATH="${TILLANDSIAS_COORD_SECRET_PATH:-secret/tillandsias/coordinator/access}"
coordinator_namespace() {
    # The server's normaliser: owner/repo, lowercased, no scheme/host/.git.
    git remote get-url origin 2>/dev/null \
        | sed -E 's#\.git$##; s#^[a-zA-Z]+://[^/]+/##; s#^[^@/]+@[^:]+:##' \
        | tr 'A-Z' 'a-z'
}
coordinator_bump() {
    url="${TILLANDSIAS_COORD_URL:-}"
    id=""
    secret=""
    if command -v vault-cli >/dev/null 2>&1; then
        id="$(timeout 5 vault-cli read -field=client_id "$COORD_SECRET_PATH" 2>/dev/null)" || id=""
        secret="$(timeout 5 vault-cli read -field=client_secret "$COORD_SECRET_PATH" 2>/dev/null)" || secret=""
        [ -n "$url" ] || url="$(timeout 5 vault-cli read -field=url "$COORD_SECRET_PATH" 2>/dev/null)" || url=""
    fi
    if [ -z "$url" ] || [ -z "$id" ] || [ -z "$secret" ]; then
        log_msg "coordinator: not configured (no Access service token at $COORD_SECRET_PATH); no staleness bump sent"
        return 0
    fi
    ns="$(coordinator_namespace)"
    [ -n "$ns" ] || ns="${PROJECT:-unknown}"
    head="$(git rev-parse --verify -q HEAD 2>/dev/null)" || head=""
    case "$head" in *[!0-9a-f]* | "") body="{\"op\":\"bump\",\"ns\":\"$ns\",\"head_sha\":null}" ;;
        *) body="{\"op\":\"bump\",\"ns\":\"$ns\",\"head_sha\":\"$head\"}" ;;
    esac
    hdr="$(umask 077; mktemp)" || { log_msg "coordinator: could not make a header file; no bump sent"; return 0; }
    printf 'CF-Access-Client-Id: %s\nCF-Access-Client-Secret: %s\nContent-Type: application/json\n' \
        "$id" "$secret" >"$hdr"
    code="$(timeout 10 curl -sS -o /dev/null -w '%{http_code}' --max-time 8 -H @"$hdr" \
        -X POST --data "$body" "${url%/}/v1/op" 2>/dev/null)" || code="000"
    rm -f "$hdr"
    case "$code" in
        2??) log_msg "coordinator: bumped $ns head=${head:-none}" ;;
        000 | "") log_msg "coordinator: unreachable at ${url%/}; push unaffected" ;;
        *) log_msg "coordinator: refused the bump (HTTP $code); push unaffected" ;;
    esac
}
if [ "$COUNT" -gt 0 ]; then
    ( coordinator_bump ) </dev/null >/dev/null 2>&1 &
fi
exit 0
