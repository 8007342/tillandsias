#!/usr/bin/env bash
# @trace order:1443-we89, spec:command-policies
#
# test-pretooluse-command-policy.sh — the Bash-tool bridge, driven with hook
# JSON exactly as Claude Code sends it, so it never needs the hook installed.
#
#   1  an unquoted heredoc carrying a backtick is refused (why + remedy)
#   2  pipefail + `| grep -q`, and a check-/test- script `| tail -1`, are refused
#   3  gh auth refresh / login / token are refused
#   4  destructive classes ask (the permissionDecision JSON), never allow; a
#      soft reset follows the policy engine (allowed in a forge, asked elsewhere)
#   5  a shell string with a pipe or $( ) crossing a boundary is refused
#   6  NEGATIVE CONTROL: ordinary commands, a QUOTED heredoc with backticks and a
#      pipeline with no pipefail and no verdict consumer all allow, silently
#   7  --status prints the counts and the three-part retirement condition; the
#      kill switch allows everything and is logged
#   8  the stub is under sixty lines and bash-dialect clean
#
# Pre-fix: FAILS at arm 1 (no stub, no `policy classify-bash`).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STUB="$ROOT/scripts/hooks/claude-pretooluse-command-policy.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/pretooluse-policy.XXXXXX")"
trap 'rm -rf "$W"' EXIT
export TILLANDSIAS_PRETOOLUSE_LOG="$W/decisions.jsonl"
unset TILLANDSIAS_PRETOOLUSE_HOOK
pass=0
fail=0
ok() { echo "ok:   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail + 1)); }

[ -f "$STUB" ] || { echo "FAIL: arm 1: $STUB does not exist" >&2; echo "FAIL: pretooluse-command-policy 0/1 (1443-we89)"; exit 1; }
. "$ROOT/scripts/plan-binary-probe.sh"
PLAN="$(cd "$ROOT" && resolve_plan_binary)" || { echo "FAIL: no runnable plan binary" >&2; exit 1; }
case "$PLAN" in /*) ;; *) PLAN="$ROOT/${PLAN#./}" ;; esac
export TILLANDSIAS_PLAN_BIN="$PLAN"

# JSON string escaping for the hook input: backslash, quote, newline, tab.
json_str() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    printf '"%s"' "$s"
}
# hook <command> [tool] → $OUT (stdout), $ERR (stderr), $RC
hook() {
    local tool="${2:-Bash}"
    printf '{"session_id":"fixture","hook_event_name":"PreToolUse","tool_name":"%s","cwd":%s,"tool_input":{"command":%s}}' \
        "$tool" "$(json_str "$ROOT")" "$(json_str "$1")" |
        bash "$STUB" >"$W/out" 2>"$W/err"
    RC=$?
    OUT="$(cat "$W/out")"
    ERR="$(cat "$W/err")"
}
expect_deny() { # <label> <token> <command> [remedy substring...]
    local label="$1" token="$2" cmd="$3"
    shift 3
    hook "$cmd"
    local good=1
    [ "$RC" -eq 2 ] && [ -z "$OUT" ] || good=0
    grep -qx "refused:bash-policy:$token" <<<"$ERR" || good=0
    grep -q '^why: ' <<<"$ERR" || good=0
    grep -q '^remedy: ' <<<"$ERR" || good=0
    local r
    for r in "$@"; do grep -qF -- "$r" <<<"$ERR" || good=0; done
    [ "$good" = 1 ] && ok "$label" || bad "$label: rc=$RC out=[$OUT] err=[$ERR]"
}
expect_ask() { # <label> <class> <command>
    hook "$3"
    if [ "$RC" -eq 0 ] &&
        [ "$("$PLAN" json get -r '.hookSpecificOutput.permissionDecision' <<<"$OUT" 2>/dev/null)" = ask ] &&
        [ "$("$PLAN" json get -r '.hookSpecificOutput.hookEventName' <<<"$OUT" 2>/dev/null)" = PreToolUse ] &&
        grep -qF "consent class: $2" <<<"$OUT"; then
        ok "$1"
    else
        bad "$1: rc=$RC out=[$OUT] err=[$ERR]"
    fi
}
expect_allow() { # <label> <command> [tool]
    hook "$2" "${3:-Bash}"
    [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ] && ok "$1" || bad "$1: rc=$RC out=[$OUT] err=[$ERR]"
}

# ── 1 ───────────────────────────────────────────────────────────────────────
expect_deny "arm 1: unquoted heredoc with a backtick span is refused" unquoted-heredoc-executes-prose \
    $'cat > note.md <<EOF\nrun `openspec init` first\nEOF' "<<'EOF'" "tillandsias-plan run --stdin-file"

# ── 2 ───────────────────────────────────────────────────────────────────────
expect_deny "arm 2: pipefail + grep -q verdict pipeline is refused" sigpipe-verdict-pipeline \
    'set -o pipefail; git log --oneline | grep -q fix && echo yes' "run --json" 'grep -q PAT <<<"$'
expect_deny "arm 2: a check script's verdict through tail -1 is refused" verdict-through-tail \
    'bash scripts/check-bash-dialect.sh | tail -1'

# ── 3 ───────────────────────────────────────────────────────────────────────
for sub in refresh login token; do
    expect_deny "arm 3: gh auth $sub is refused" no-credential-mutation "gh auth $sub"
done

# ── 4 ───────────────────────────────────────────────────────────────────────
expect_ask "arm 4: rm -rf outside the working dir, TMPDIR and scratch asks" workspace-destroy 'rm -rf /etc/some-dir'
expect_ask "arm 4: a force-push to linux-next asks" force-push 'git push --force origin linux-next'
# Soft resets follow the policy engine's own host-kind reading, which an
# environment variable cannot override (a forge needs physical evidence).
soft="$("$PLAN" policy eval -- tillandsias --reset-state 2>/dev/null | head -n 1)"
for cmd in 'podman system reset --force' 'tillandsias --reset-state'; do
    if [ "$soft" = "ok:policy:soft-reset:forge-preauthorised" ]; then
        expect_allow "arm 4: '$cmd' is a soft reset, pre-authorised in this forge" "$cmd"
    else
        expect_ask "arm 4: '$cmd' asks on this host (soft reset)" soft-reset "$cmd"
    fi
    out="$("$PLAN" policy classify-bash --command "$cmd" --host-kind bare-metal)"; rc=$?
    [ "$rc" -eq 4 ] && grep -qx 'consent:bash-policy:soft-reset' <<<"$out" &&
        ok "arm 4: '$cmd' asks on bare metal, never allows" || bad "arm 4 bare-metal '$cmd': rc=$rc [$out]"
done
out="$("$PLAN" policy classify-bash --command 'rm -rf /tmp/pretooluse-scratch-x' --cwd "$ROOT")"; rc=$?
[ "$rc" -eq 0 ] && ok "arm 4: rm -rf under TMPDIR needs no consent" || bad "arm 4 tmp rm: rc=$rc [$out]"

# ── 5 ───────────────────────────────────────────────────────────────────────
expect_deny "arm 5: wsl.exe … bash -lc with a pipe is refused" string-crosses-a-boundary \
    'wsl.exe -d x -- bash -lc "a | b"'
expect_deny "arm 5: bash -c \"\$(cat f)\" is refused" string-crosses-a-boundary 'bash -c "$(cat f)"'

# ── 6: NEGATIVE CONTROL ─────────────────────────────────────────────────────
expect_allow "arm 6: git status allows" 'git status'
expect_allow "arm 6: ls -la /tmp allows" 'ls -la /tmp'
expect_allow "arm 6: a QUOTED heredoc with backticks allows" $'cat > note.md <<\'EOF\'\nrun `openspec init` first\nEOF'
expect_allow "arm 6: printf | sort with no pipefail and no verdict consumer allows" 'printf %s "$x" | sort'
expect_allow "arm 6: a plain bash -c string allows (unknown shapes allow)" 'bash -c "echo hi"'
expect_allow "arm 6: a non-Bash tool is not this bridge's business" 'rm -rf /' Write

# ── 7 ───────────────────────────────────────────────────────────────────────
status="$(bash "$STUB" --status)"; rc=$?
if [ "$rc" -eq 0 ] && grep -qE '^decisions=[0-9]+/[0-9]+/[0-9]+ ' <<<"$status" &&
    grep -qF '(a) 1443-8pur and 1443-r4cj are closed on every locus' <<<"$status" &&
    grep -qF '(b) the audit shows zero deny and zero ask decisions from caller=pretooluse for 14 consecutive fleet days' <<<"$status" &&
    grep -qF "(c) the operator flips the Bash tool's default" <<<"$status"; then
    ok "arm 7: --status prints decisions=<d>/<a>/<al> and the three-part retirement condition"
else
    bad "arm 7: status rc=$rc [$status]"
fi
TILLANDSIAS_PRETOOLUSE_HOOK=off hook 'gh auth refresh'
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && grep -q '"kill_switch":1' "$TILLANDSIAS_PRETOOLUSE_LOG"; then
    ok "arm 7: the kill switch allows a deny-shaped command and logs kill_switch=1"
else
    bad "arm 7: kill switch rc=$RC out=[$OUT] log=[$(tail -n 1 "$TILLANDSIAS_PRETOOLUSE_LOG" 2>/dev/null)]"
fi
if grep -qF 'openspec' "$TILLANDSIAS_PRETOOLUSE_LOG"; then
    bad "arm 7: the decision log recorded a raw command"
else
    ok "arm 7: the decision log never records the raw command"
fi

# ── 8 ───────────────────────────────────────────────────────────────────────
n="$(wc -l <"$STUB" | tr -d ' ')"
dialect="$(TILLANDSIAS_DIALECT_SCAN_DIR="$STUB" bash "$ROOT/scripts/check-bash-dialect.sh" 2>/dev/null)"
[ "$n" -lt 60 ] && [ "$dialect" = "ok:bash-dialect-clean" ] &&
    ok "arm 8: the stub is $n lines and bash-dialect clean" || bad "arm 8: lines=$n dialect=[$dialect]"
out="$(printf '{"tool_name":"Bash","tool_input":{"command":"gh auth refresh"}}' |
    TILLANDSIAS_PLAN_BIN="$W/not-runnable" bash "$STUB" 2>"$W/err")"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && grep -q '^note:pretooluse:no-plan-binary' "$W/err" &&
    ok "arm 8: with no runnable plan binary the bridge allows, with a note" || bad "arm 8 no-binary: rc=$rc [$out] [$(cat "$W/err")]"

# ── 9: the wiring (operator ruling 1: commit the hook to the project) ───────
jget() { "$PLAN" json get "$@"; }
repo_cmd="$(jget -r '.hooks.PreToolUse[0].hooks[0].command' "$ROOT/.claude/settings.json" 2>/dev/null)"
repo_match="$(jget -r '.hooks.PreToolUse[0].matcher' "$ROOT/.claude/settings.json" 2>/dev/null)"
[ "$repo_match" = Bash ] && [ "$repo_cmd" = '"$CLAUDE_PROJECT_DIR"/scripts/hooks/claude-pretooluse-command-policy.sh' ] &&
    ok "arm 9: .claude/settings.json runs the stub for Bash, anchored on \$CLAUDE_PROJECT_DIR (any mount prefix)" ||
    bad "arm 9: repo settings matcher=[$repo_match] command=[$repo_cmd]"
OVERLAY="$ROOT/images/default/config-overlay/claude/settings.json"
ov_cmd="$(jget -r '.hooks.PreToolUse[0].hooks[0].command' "$OVERLAY" 2>/dev/null)"
[ "$(jget -r '.hooks.PreToolUse[0].matcher' "$OVERLAY" 2>/dev/null)" = Bash ] &&
    [ "$ov_cmd" = "tillandsias-plan policy classify-bash --hook" ] &&
    ok "arm 9: the forge overlay runs the classifier directly (projects without the stub)" ||
    bad "arm 9: overlay command=[$ov_cmd]"
if command -v jq >/dev/null 2>&1; then
    trace_lifecycle() { :; }
    eval "$(sed -n '/^seed_claude_pretooluse_hook()/,/^}/p' "$ROOT/images/default/lib-common.sh")"
    mkdir -p "$W/overlay/claude"
    cp "$OVERLAY" "$W/overlay/claude/settings.json"
    SETTINGS="$W/home/.claude/settings.json"
    mkdir -p "$(dirname "$SETTINGS")"
    printf '{"skipDangerousModePermissionPrompt":true,"hooks":{"PostToolUse":[{"matcher":"Edit","hooks":[{"type":"command","command":"true"}]}]}}\n' >"$SETTINGS"
    for _ in 1 2; do
        TILLANDSIAS_HOST_KIND=forge TILLANDSIAS_CONFIG_OVERLAY_ROOT="$W/overlay" CLAUDE_SETTINGS_FILE="$SETTINGS" \
            seed_claude_pretooluse_hook
    done
    got="$(jget -c '[.skipDangerousModePermissionPrompt, .hooks.PostToolUse[0].matcher, .hooks.PreToolUse[0].hooks[0].command]' "$SETTINGS" 2>/dev/null)"
    n="$(grep -o 'classify-bash' "$SETTINGS" | wc -l | tr -d ' ')"
    [ "$got" = '[true,"Edit","tillandsias-plan policy classify-bash --hook"]' ] && [ "$n" = 1 ] &&
        ok "arm 9: the forge seed merges the hook once, keeping every other setting and hook" ||
        bad "arm 9: seed merge got=[$got] copies=$n"
    rm -f "$W/home/.claude/settings.json"
    TILLANDSIAS_HOST_KIND= TILLANDSIAS_CONFIG_OVERLAY_ROOT="$W/overlay" CLAUDE_SETTINGS_FILE="$SETTINGS" \
        seed_claude_pretooluse_hook
    [ ! -e "$SETTINGS" ] && ok "arm 9: outside a forge the seed writes nothing" || bad "arm 9: non-forge seed wrote $SETTINGS"
else
    echo "note:pretooluse-command-policy:no-jq — the forge seed arm needs jq (it ships in the forge image)"
fi

total=$((pass + fail))
if [ "$fail" -eq 0 ]; then
    echo "PASS: pretooluse-command-policy $pass/$total (1443-we89)"
    exit 0
fi
echo "FAIL: pretooluse-command-policy $pass/$total (1443-we89)"
exit 1
