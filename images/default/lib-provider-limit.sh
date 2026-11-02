#!/usr/bin/env bash
# @trace order:1941-rlim
#
# lib-provider-limit.sh — a provider's usage limit is reported as itself,
# stops the lane, and holds every later launch until it lifts.
#
# MEASURED on yoga 2026-11-01: after 11 opencode sessions the shared free tier
# answered `429 Too Many Requests`, `Retry-After: 78443`, body "Free usage limit
# reached". Earlier the same night the agent died four times on "EPROTO: The
# TLS handshake failed" (the edge ending sessions with a TLS alert), and later
# lanes kept calling the same provider. Nothing in the lane said "usage limit".
#
# opencode's own log carries the limit as one ERROR line:
#   ... level=ERROR ... message="stream error" providerID=opencode ...
#   error.error="AI_APICallError: Free usage limit reached. ..."
# The Retry-After header appears only when fetch tracing is on
# (BUN_CONFIG_VERBOSE_FETCH, never enabled in production because it prints
# request headers), so the hold defaults to PROVIDER_LIMIT_DEFAULT_HOLD_S when
# the provider's own value was not seen. 24 h: the one measured Retry-After
# was 78443 s (21.8 h).
#
# Record: $(provider_limit_dir)/<provider>, one line
#   <until-epoch> <until-utc> <recorded-utc>
# in the forge's persistent project cache, so every later forge of this
# project on this host reads it. It does NOT yet reach other hosts.
#
# TILLANDSIAS_IGNORE_PROVIDER_LIMIT=1 lets an operator try anyway.

PROVIDER_LIMIT_DEFAULT_HOLD_S="${PROVIDER_LIMIT_DEFAULT_HOLD_S:-86400}"

provider_limit_dir() {
    printf '%s\n' "${TILLANDSIAS_PROVIDER_LIMIT_DIR:-${HOME:-/tmp}/.cache/tillandsias-project/provider-limits}"
}

# Is this log line a provider usage limit? Only the ERROR line: when fetch
# tracing is on, the `< 429` status line comes BEFORE its Retry-After header,
# so recording on it would miss the provider's own value.
provider_limit_is_limit_line() {
    case "$1" in
        *"Free usage limit reached"*) return 0 ;;
    esac
    return 1
}

# The seconds in a `Retry-After: <n>` line, or nothing.
provider_limit_retry_after_of() {
    case "$1" in
        *"Retry-After:"*)
            local v="${1#*Retry-After:}"
            v="${v#"${v%%[![:space:]]*}"}"
            v="${v%%[!0-9]*}"
            [ -n "$v" ] && printf '%s\n' "$v"
            ;;
    esac
}

# provider_limit_record <provider> <hold-seconds>
# Writes the record and prints the operator line and the verdict.
provider_limit_record() {
    local provider="$1" hold="$2" dir now until until_utc
    dir="$(provider_limit_dir)"
    mkdir -p "$dir" 2>/dev/null || true
    now="$(date -u +%s)"
    until=$((now + hold))
    # GNU date (the forge) or BSD date (a macOS fixture host).
    until_utc="$(date -u -d "@$until" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || date -u -r "$until" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || printf '%s' "$until")"
    printf '%s %s %s\n' "$until" "$until_utc" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$dir/$provider" 2>/dev/null || true
    printf '[forge] provider usage limit reached, retry after %s (%s)\n' "$until_utc" "$provider"
    printf 'blocked:provider-usage-limit:provider=%s:retry_after=%s\n' "$provider" "$until_utc"
}

# provider_limit_active <provider> — 0 while a recorded limit has not lifted;
# prints its until-utc.
provider_limit_active() {
    local f until until_utc
    f="$(provider_limit_dir)/$1"
    [ -r "$f" ] || return 1
    read -r until until_utc _ <"$f" 2>/dev/null || return 1
    case "$until" in '' | *[!0-9]*) return 1 ;; esac
    [ "$(date -u +%s)" -lt "$until" ] || return 1
    printf '%s\n' "$until_utc"
}

# provider_limit_refuse <provider> — 0 (refuse) while a limit is active,
# printing why; 1 to go ahead.
provider_limit_refuse() {
    local until_utc
    [ "${TILLANDSIAS_IGNORE_PROVIDER_LIMIT:-0}" = "1" ] && return 1
    until_utc="$(provider_limit_active "$1")" || return 1
    printf '[forge] provider usage limit reached, retry after %s (%s); not calling it. Set TILLANDSIAS_IGNORE_PROVIDER_LIMIT=1 to try anyway.\n' "$until_utc" "$1"
    printf 'blocked:provider-usage-limit:provider=%s:retry_after=%s\n' "$1" "$until_utc"
    return 0
}

# provider_limit_watch_line <provider> <line> — for a log follower: remembers
# a Retry-After it sees, and records the limit (once) on the limit line.
# State lives in PROVIDER_LIMIT_SEEN_RETRY / PROVIDER_LIMIT_RECORDED.
provider_limit_watch_line() {
    local ra
    ra="$(provider_limit_retry_after_of "$2")"
    [ -n "$ra" ] && PROVIDER_LIMIT_SEEN_RETRY="$ra"
    provider_limit_is_limit_line "$2" || return 0
    [ "${PROVIDER_LIMIT_RECORDED:-0}" = "1" ] && return 0
    PROVIDER_LIMIT_RECORDED=1
    provider_limit_record "$1" "${PROVIDER_LIMIT_SEEN_RETRY:-$PROVIDER_LIMIT_DEFAULT_HOLD_S}"
}
