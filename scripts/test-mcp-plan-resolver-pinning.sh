#!/usr/bin/env bash
# @trace order:963-pdrp, spec:forge-environment-discoverability
#
# test-mcp-plan-resolver-pinning.sh — the MCP servers (project-info.sh and
# forge-plan.sh) find the plan ledger by the REPOSITORY and only accept a real
# Tillandsias ledger. Measured defects (tillandsias.org forge agent): a foreign
# repo's plan/index.yaml was promoted into the plan lane, and a checkout that
# lost its marker dir fell back, fail-OPEN, to a stale $HOME/src/tillandsias
# clone.
#
# HERMETIC: scratch repos and a fake HOME carrying a "stale clone" ledger; the
# resolver functions are extracted verbatim from BOTH servers and must agree.
#
#   1  a FOREIGN repo whose plan/index.yaml is not a ledger resolves to NOTHING
#      (not the foreign file, not the $HOME clone)
#   2  a repo that lost plan/ (sparse checkout) resolves to NOTHING — no $HOME
#      fallback from inside a repo
#   3  a real ledger resolves to the REPO's ledger, from a subdirectory too
#   4  outside any repo the fallbacks remain, held to the ledger test: a stale
#      $HOME ledger is found, a non-ledger $HOME file is not
#   5  TILLANDSIAS_PLAN_INDEX still overrides
#   6  BEHAVIOUR: project-info's plan_query run from the sparse repo does not
#      answer with the $HOME clone's packet
#
# Pre-fix: FAILS at arm 1 (the foreign file is accepted) and arm 2 (the $HOME
# clone answers).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PI="$ROOT/images/default/config-overlay/mcp/project-info.sh"
FP="$ROOT/images/default/config-overlay/mcp/forge-plan.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/mcp-plan-resolver.XXXXXX")"
W="$(cd "$W" && pwd -P)"
trap 'rm -rf "$W"' EXIT
pass=0
fail=0
ok() { echo "ok:   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail + 1)); }

export GIT_CONFIG_GLOBAL="$W/gitconfig" GIT_CONFIG_NOSYSTEM=1
printf '[user]\n\tname = t\n\temail = t@example.invalid\n' >"$GIT_CONFIG_GLOBAL"
unset TILLANDSIAS_PLAN_INDEX
H="$W/home"
LEDGER='plan_index:
  version: 1
packets:
  - packet_id: stale-home-clone-packet
    order: 1-home
    status: ready
    pickup_role: linux
    title: from the STALE HOME CLONE
'
mkdir -p "$H/src/tillandsias/plan/index.d"
printf '%s' "$LEDGER" >"$H/src/tillandsias/plan/index.yaml"

repo() { # repo <dir> <index body or "">
    git init -q "$1"
    if [ -n "$2" ]; then mkdir -p "$1/plan/index.d"; printf '%s' "$2" >"$1/plan/index.yaml"; fi
    mkdir -p "$1/sub"; echo x >"$1/README"
}
repo "$W/foreign" 'resource_changes: []
format_version: "1.2"
'
repo "$W/sparse" ""
repo "$W/runtime" "$LEDGER"
mkdir -p "$W/norepo"

for server in "$PI" "$FP"; do
    name="$(basename "$server" .sh)"
    FUNCS="$(awk '/^project_toplevel\(\) \{/,/^\}/' "$server"; awk '/^is_tillandsias_ledger\(\) \{/,/^\}/' "$server"; awk '/^resolve_plan_index\(\) \{/,/^\}/' "$server")"
    case "$FUNCS" in *is_tillandsias_ledger*resolve_plan_index*) ;; *)
        bad "$name: the pinned resolver is not in $server"; continue ;; esac
    res() { # res <cwd> [env...] -> the resolved index path
        (cd "$1" && shift && env HOME="$H" "$@" bash -c 'eval "$1"; resolve_plan_index' _ "$FUNCS")
    }
    [ -z "$(res "$W/foreign")" ] && ok "$name arm 1: a foreign repo's non-ledger plan/index.yaml resolves to nothing" ||
        bad "$name arm 1: foreign -> [$(res "$W/foreign")]"
    [ -z "$(res "$W/sparse")" ] && ok "$name arm 2: a repo without plan/ resolves to nothing (no \$HOME fallback)" ||
        bad "$name arm 2: sparse -> [$(res "$W/sparse")]"
    r3a="$(res "$W/runtime")"; r3b="$(res "$W/runtime/sub")"
    [ "$r3a" = "$W/runtime/plan/index.yaml" ] && [ "$r3b" = "$W/runtime/plan/index.yaml" ] &&
        ok "$name arm 3: a real ledger resolves to the repo's own, from a subdirectory too" ||
        bad "$name arm 3: [$r3a] [$r3b]"
    r4a="$(res "$W/norepo")"
    mv "$H/src/tillandsias/plan/index.yaml" "$W/ledger.keep"
    printf 'roadmap: []\n' >"$H/src/tillandsias/plan/index.yaml"
    r4b="$(res "$W/norepo")"
    mv "$W/ledger.keep" "$H/src/tillandsias/plan/index.yaml"
    [ "$r4a" = "$H/src/tillandsias/plan/index.yaml" ] && [ -z "$r4b" ] &&
        ok "$name arm 4: outside any repo the \$HOME ledger is found, and a non-ledger there is not" ||
        bad "$name arm 4: [$r4a] [$r4b]"
    [ "$(res "$W/foreign" TILLANDSIAS_PLAN_INDEX="$W/runtime/plan/index.yaml")" = "$W/runtime/plan/index.yaml" ] &&
        ok "$name arm 5: TILLANDSIAS_PLAN_INDEX overrides" || bad "$name arm 5"
done

# ── 6: behaviour through project-info's plan_query ─────────────────────────
. "$ROOT/scripts/plan-binary-probe.sh"
PLAN="$(cd "$ROOT" && resolve_plan_binary 2>/dev/null)" || PLAN=""
case "$PLAN" in "" | /*) ;; *) PLAN="$ROOT/${PLAN#./}" ;; esac
if [ -n "$PLAN" ]; then
    out="$(cd "$W/sparse" && printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"plan_query","arguments":{"status":"ready"}}}' |
        HOME="$H" TILLANDSIAS_PLAN_BIN="$PLAN" bash "$PI" 2>/dev/null)"
    if [ -n "$out" ] && ! grep -q 'stale-home-clone-packet' <<<"$out"; then
        ok "arm 6: plan_query from a repo without a ledger does not answer from the \$HOME clone"
    else
        bad "arm 6: [$(cut -c1-200 <<<"$out")]"
    fi
else
    echo "skip: arm 6: no runnable plan binary"
fi

total=$((pass + fail))
if [ "$fail" -eq 0 ]; then
    echo "PASS: mcp-plan-resolver-pinning $pass/$total (963-pdrp)"
    exit 0
fi
echo "FAIL: mcp-plan-resolver-pinning $pass/$total (963-pdrp)"
exit 1
