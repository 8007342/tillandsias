#!/usr/bin/env bash
# @trace order:605-u9g5, spec:forge-environment-discoverability
set -euo pipefail


# ORDER 799-tb7q — resolve `jq` through the shared host-preferred /
# toolbox-fallback dispatch instead of assuming the host has it.
# shellcheck source=scripts/lib/tool-dispatch.sh
# Resolve the lib by WALKING UP, not by a fixed depth (order 914-ahsy). The
# fixed form `dirname "${BASH_SOURCE[0]}"/lib/...` is correct only for a caller
# sitting directly in scripts/. From scripts/refusal-calibration/ it points at a
# lib that does not exist, the `|| true` swallows the miss, and the tool variable
# silently falls back to the bare name — a conversion that passes review, passes
# the suite, and changes nothing.
_td_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
while [ -n "$_td_dir" ] && [ "$_td_dir" != "/" ] && [ ! -f "$_td_dir/lib/tool-dispatch.sh" ]; do
    _td_dir="$(dirname "$_td_dir")"
done
if [ -f "$_td_dir/lib/tool-dispatch.sh" ]; then
    . "$_td_dir/lib/tool-dispatch.sh" 2>/dev/null || true
fi
if command -v resolve_tool >/dev/null 2>&1; then
    JQ="$(resolve_tool jq || printf 'jq')"
else
    JQ="jq"   # lib unavailable: preserve the previous behaviour exactly
fi

# Behavioral fixture for images/default/config-overlay/codex/register-experts.sh
# (order 605-u9g5). Exercises empty and pre-populated CODEX_HOME roots, applies
# the helper TWICE in each, and asserts:
#
#   * a double application leaves exactly one entry per expert server
#   * auth.json is byte-preserved
#   * unrelated config keys and an unrelated MCP server survive registration
#
# The Codex CLI is INJECTABLE via CODEX_BIN: when set, the real binary is
# used; otherwise a real `codex` on PATH is preferred; otherwise the committed
# stub (scripts/fixtures/codex-mcp-stub.sh) pins the same contract hermetically
# so the test stays deterministic on hosts without Codex.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/images/default/config-overlay/codex/register-experts.sh"
STUB="$ROOT/scripts/fixtures/codex-mcp-stub.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The image chmods the MCP scripts at build time
# (`RUN chmod +x /home/forge/.config-overlay/mcp/*.sh`), but the source tree
# does not carry those modes — forge-plan.sh and host-browser.sh are 0644 in
# the repo. The fixture therefore builds its own executable overlay so the
# helper's `-x` guard is exercised against a faithful runtime layout without
# depending on (or mutating) the working tree.
OVL="$WORK/overlay"
mkdir -p "$OVL/mcp"
cp "$ROOT/images/default/config-overlay/mcp/forge-plan.sh" "$OVL/mcp/forge-plan.sh"
cp "$ROOT/images/default/config-overlay/mcp/project-info.sh" "$OVL/mcp/project-info.sh"
cp "$ROOT/images/default/config-overlay/mcp/host-browser.sh" "$OVL/mcp/host-browser.sh"
chmod +x "$OVL/mcp/"*.sh

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

if [ -n "${CODEX_BIN:-}" ]; then
    [ -x "$CODEX_BIN" ] || fail "CODEX_BIN=$CODEX_BIN is not executable"
    BIN="$CODEX_BIN"
elif command -v codex >/dev/null 2>&1; then
    BIN="$(command -v codex)"
else
    BIN="$STUB"
fi

# apply_helper <home> [socket] — run the helper as the entrypoint does. The
# lane's TILLANDSIAS_CONTROL_SOCKET is set when a socket is given and UNSET
# otherwise, so a value from the calling shell cannot leak into a scenario.
SOCK="/run/host/tillandsias-mcp/mcp.sock"
apply_helper() {
    local home="$1" sock="${2:-}"
    if [ -n "$sock" ]; then
        HOME="$home" CODEX_HOME="$home/.codex" CODEX_BIN="$BIN" \
            TILLANDSIAS_CONFIG_OVERLAY_ROOT="$OVL" TILLANDSIAS_CONTROL_SOCKET="$sock" \
            "$HELPER" >>"$WORK/helper.log" 2>&1 || fail "registration helper failed (see $WORK/helper.log)"
    else
        env -u TILLANDSIAS_CONTROL_SOCKET \
            HOME="$home" CODEX_HOME="$home/.codex" CODEX_BIN="$BIN" \
            TILLANDSIAS_CONFIG_OVERLAY_ROOT="$OVL" \
            "$HELPER" >>"$WORK/helper.log" 2>&1 || fail "registration helper failed (see $WORK/helper.log)"
    fi
}

# env_of <home> <name> — the registered server's .transport.env as compact JSON
# ("null" when it has none).
env_of() {
    list_query "$1" -c --arg n "$2" '.[] | select(.name == $n) | .transport.env'
}

# list_query <home> <jq-args>... — one jq query over `codex mcp list --json`.
# The fixture's only jq call site (jq-callsite ratchet floor is 1).
list_query() {
    local home="$1"
    shift
    HOME="$home" CODEX_HOME="$home/.codex" CODEX_BIN="$BIN" \
        "$BIN" mcp list --json 2>/dev/null | "$JQ" "$@"
}

# names_from <home> — sorted list of registered MCP server names, one per line.
names_from() {
    list_query "$1" -r '.[].name' | sort
}

count_named() {
    local home="$1" name="$2"
    names_from "$home" | grep -cxF "$name"
}

# ── Scenario A: empty CODEX_HOME, double application ─────────────
A="$WORK/empty"
mkdir -p "$A"
apply_helper "$A"
apply_helper "$A"    # second application must stay idempotent
[ "$(count_named "$A" forge-plan)" = 1 ] || fail "forge-plan not exactly once after double apply"
[ "$(count_named "$A" project-info)" = 1 ] || fail "project-info not exactly once after double apply"
[ "$(count_named "$A" host-browser)" = 1 ] || fail "host-browser not exactly once after double apply"
total_a="$(names_from "$A" | wc -l | tr -d ' ')"
[ "$total_a" = 3 ] || fail "empty scenario registered $total_a servers (expected forge-plan + project-info + host-browser)"

# ── Scenario B: pre-populated CODEX_HOME, double application ─────
B="$WORK/pre"
mkdir -p "$B/.codex"
cat > "$B/.codex/config.toml" <<'EOF'
model = "gpt-5"
temperature = 0.7

[tracing]
log_prompts = false

[mcp_servers.custom]
command = "custom-server"
env = { KEY = "v" }
EOF
printf '%s\n' '{"OPENAI_API_KEY":"sk-secret"}' > "$B/.codex/auth.json"
cp "$B/.codex/auth.json" "$WORK/auth.before"
apply_helper "$B"
apply_helper "$B"
[ "$(count_named "$B" forge-plan)" = 1 ] || fail "forge-plan not exactly once in pre-populated scenario"
[ "$(count_named "$B" project-info)" = 1 ] || fail "project-info not exactly once in pre-populated scenario"
[ "$(count_named "$B" host-browser)" = 1 ] || fail "host-browser not exactly once in pre-populated scenario"
[ "$(count_named "$B" custom)" = 1 ] || fail "unrelated custom server was dropped or duplicated"
total_b="$(names_from "$B" | wc -l | tr -d ' ')"
[ "$total_b" = 4 ] || fail "pre-populated scenario registered $total_b servers (expected custom + forge-plan + project-info + host-browser)"
diff -q "$WORK/auth.before" "$B/.codex/auth.json" >/dev/null \
    || fail "auth.json was not byte-preserved"
grep -Fq 'model = "gpt-5"' "$B/.codex/config.toml" || fail "unrelated config key model was lost"
grep -Fq 'temperature = 0.7' "$B/.codex/config.toml" || fail "unrelated config key temperature was lost"
grep -Fq 'log_prompts = false' "$B/.codex/config.toml" || fail "unrelated config key tracing.log_prompts was lost"
grep -Fq 'custom-server' "$B/.codex/config.toml" || fail "unrelated MCP server custom was lost"
grep -Fq 'KEY = "v"' "$B/.codex/config.toml" || fail "unrelated MCP server custom env was lost"

# ── Scenario C: the lane socket reaches host-browser (order 1667-jna9) ──
# Codex starts a stdio MCP server with only HOME LANG PATH PWD SHLVL USER
# (measured in codex-cli 0.162.1, 2026-10-14), so host-browser.sh never saw
# TILLANDSIAS_CONTROL_SOCKET and exited at startup: a Codex lane had no
# publish_local or browser.open. The helper must forward it explicitly.
C="$WORK/socket"
mkdir -p "$C"
apply_helper "$C" "$SOCK"
apply_helper "$C" "$SOCK"
want_env="{\"TILLANDSIAS_CONTROL_SOCKET\":\"$SOCK\"}"   # jq -c spelling
got_env="$(env_of "$C" host-browser)"
[ "$got_env" = "$want_env" ] \
    || fail "host-browser is registered without the lane socket: env=$got_env (want $want_env) — a Codex lane cannot reach publish_local"
[ "$(env_of "$C" forge-plan)" = null ] || fail "forge-plan was given an env it does not declare: $(env_of "$C" forge-plan)"
[ "$(count_named "$C" host-browser)" = 1 ] || fail "host-browser not exactly once after a double apply with the socket"
[ "$(grep -cxF '[mcp_servers.host-browser.env]' "$C/.codex/config.toml")" = 1 ] \
    || fail "host-browser env table is not exactly once after a double apply"

# ── Scenario D: a registration from before the socket is upgraded ──────
# A worker whose CODEX_HOME already lists host-browser WITHOUT the env must not
# be skipped as "already registered".
D="$WORK/stale"
mkdir -p "$D"
apply_helper "$D"
[ "$(env_of "$D" host-browser)" = null ] || fail "with no lane socket, host-browser got an env: $(env_of "$D" host-browser)"
apply_helper "$D" "$SOCK"
[ "$(env_of "$D" host-browser)" = "$want_env" ] \
    || fail "a stale host-browser registration (no env) was kept: env=$(env_of "$D" host-browser)"
[ "$(count_named "$D" host-browser)" = 1 ] || fail "host-browser not exactly once after the upgrade"

# ── Wire-level assertions shared by the image and the source tree ──
[ -x "$HELPER" ] || fail "helper is not executable"
grep -Fq 'register-codex-experts' "$ROOT/images/default/Containerfile" \
    || fail "Containerfile does not install register-codex-experts"
grep -Fq 'config-overlay/codex/register-experts.sh' "$ROOT/images/default/Containerfile" \
    || fail "Containerfile does not COPY the helper from config-overlay/codex"
grep -Fq 'register-codex-experts' "$ROOT/images/default/entrypoint-forge-codex.sh" \
    || fail "codex entrypoint does not invoke register-codex-experts"
grep -Fq 'require_codex' "$ROOT/images/default/entrypoint-forge-codex.sh" \
    || fail "codex entrypoint lost require_codex"
launch_reg=$(grep -n 'register-codex-experts' "$ROOT/images/default/entrypoint-forge-codex.sh" | head -1 | cut -d: -f1)
launch_require=$(grep -n '^require_codex$' "$ROOT/images/default/entrypoint-forge-codex.sh" | cut -d: -f1)
launch_banner=$(grep -n '^show_banner "codex"$' "$ROOT/images/default/entrypoint-forge-codex.sh" | cut -d: -f1)
[ -n "$launch_reg" ] && [ -n "$launch_require" ] && [ -n "$launch_banner" ] \
    || fail "cannot locate registration ordering in codex entrypoint"
[ "$launch_reg" -gt "$launch_require" ] || fail "registration precedes require_codex (CLI not guaranteed present)"
[ "$launch_reg" -lt "$launch_banner" ] || fail "registration is not before the launch path"

echo "PASS: Codex expert MCP registration is idempotent, auth/config-preserving, forwards the lane socket to host-browser, and is wired before launch (binary: $BIN)"
