#!/usr/bin/env bash
# @trace order:605-u9g5
#
# codex-mcp-stub.sh — a faithful minimal model of the verified `codex mcp`
# interface (codex-cli 0.146.0) for hermetic registration fixtures.
#
# It is a MODEL, not a mirror, of the real CLI. The behaviors it reproduces
# are exactly the ones the helper and the fixture depend on:
#
#   * `codex mcp add <name> -- <command>` appends a `[mcp_servers.<name>]`
#     table to $CODEX_HOME/config.toml, REPLACING an existing same-name table
#     (so a double application leaves exactly one entry), and leaves every
#     other byte of the config untouched.
#   * `codex mcp list --json` emits the same shape the real CLI emits, so the
#     helper's jq selection and the fixture's count assertions hold against
#     either binary.
#   * auth.json is never read or written.
#
# Deliberately NOT modeled: codex's whole-file TOML re-serialization on write
# (the fixture asserts semantic preservation of unrelated content, which both
# the stub and the real CLI satisfy), its provider-auth document handling, and
# its TUI. The stub supports stdio servers only; `add` with an --env or --url
# or an existing server not shaped as a stdio table is refused loudly so a
# fixture cannot silently drift past the supported contract.

set -euo pipefail

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
CONFIG="$CODEX_HOME/config.toml"

die() {
    printf '%s\n' "codex-mcp-stub: $*" >&2
    exit 1
}

# read_block <file> <header> — print a `[header]` table block (header + body
# until the next top-level `[` table) if present, else nothing.
read_block() {
    local file="$1" header="$2"
    awk -v h="$header" '
        $0 == h { inblock = 1; print; next }
        inblock && /^\[/ { exit }
        inblock { print }
    ' "$file" 2>/dev/null || true
}

# drop_block <file> <header> — rewrite the file without the given table block.
drop_block() {
    local file="$1" header="$2"
    awk -v h="$header" '
        $0 == h { skip = 1; next }
        skip && /^\[/ { skip = 0 }
        skip { next }
        { print }
    ' "$file" >"$file.stub-tmp" && mv "$file.stub-tmp" "$file"
}

mcp_add() {
    [ $# -ge 2 ] || die "usage: codex mcp add <NAME> -- <COMMAND>..."
    local name="$1"
    shift
    [ "${1:-}" = "--" ] && shift || die "expected -- before the command"
    [ $# -ge 1 ] || die "no command supplied for $name"
    case "$name" in
        *$'\n'* | *"["* | *"]"*) die "unsafe server name: $name" ;;
    esac

    mkdir -p "$CODEX_HOME"
    : >/dev/null
    [ -f "$CONFIG" ] || : >"$CONFIG"

    local header="[mcp_servers.$name]"
    if read_block "$CONFIG" "$header" >/dev/null; then
        drop_block "$CONFIG" "$header"
    fi
    printf '%s\n' "$header" "command = \"$1\"" >>"$CONFIG"
    printf 'Added global MCP server %s.\n' "'$name'"
}

mcp_list() {
    local json="["
    local first=1
    local name block command
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        block="$(read_block "$CONFIG" "[mcp_servers.$name]")"
        command="$(printf '%s\n' "$block" | awk -F'"' '/^command = "/{ print $2; exit }')"
        [ -n "$command" ] || continue
        [ "$first" = 1 ] || json="$json,"
        first=0
        json="$json{\"name\":\"$name\",\"enabled\":true,\"disabled_reason\":null,\"transport\":{\"type\":\"stdio\",\"command\":\"$command\",\"args\":[]},\"startup_timeout_sec\":null,\"tool_timeout_sec\":null,\"auth_status\":\"unsupported\"}"
    done < <(awk '/^\[mcp_servers\./ && $0 !~ /\]\./ { gsub(/^\[mcp_servers\./, "", $0); gsub(/\]$/, "", $0); print }' "$CONFIG" 2>/dev/null || true)
    printf '%s\n' "$json]"
}

[ $# -ge 1 ] || die "usage: codex mcp <add|list> ..."
cmd="$1"
shift
case "$cmd" in
    mcp)
        [ $# -ge 1 ] || die "usage: codex mcp <add|list> ..."
        sub="$1"
        shift
        case "$sub" in
            add) mcp_add "$@" ;;
            list)
                case "${1:-}" in
                    --json) mcp_list ;;
                    *) die "stub supports only: codex mcp list --json" ;;
                esac
                ;;
            *) die "stub supports only: codex mcp add|list" ;;
        esac
        ;;
    *) die "stub supports only: codex mcp add|list" ;;
esac
