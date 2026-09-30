#!/usr/bin/env bash
# @trace order:1506-ssb5, openspec/changes/fleet-messaging-poc/specs/fleet-messaging/spec.md
#
# The fleet message bus's MCP surface (1506-ssb5): forge-plan.sh's
# msg_send/msg_recv/msg_list/msg_status tools, wrapping `tillandsias-plan msg`
# behind the same capability probe every other tool uses, and the Codex /
# OpenCode forge entrypoints' pending-mail-at-session-start line. Eight named
# arms, one per clause of this packet's exit criteria as amended by the
# ack-semantics ruling (2026-09-29):
#
#   1 surface     tools/list carries msg_send, msg_recv, msg_list, msg_status
#                 and NO msg_ack (there is no ack verb: operator ruling
#                 2026-09-29) — NEGATIVE CONTROL
#   2 round-trip  msg_send prints the receipt id at once; msg_status reads
#                 pending, then acked:<host>/<lane>@<ts> + via:local once the
#                 fixture writes the receipt (the mover is 1506-q7ab)
#   3 secret      a secret-shaped body sent through msg_send is refused with
#                 why + remedy and writes NOTHING to the outbox — NEGATIVE
#                 CONTROL naming the exact rule text
#   4 degraded    with a stub tillandsias-plan whose `capabilities` omits
#                 `msg`, EVERY msg tool (send/recv/list/status) answers the
#                 degraded {confidence:"unsupported"} envelope, never a fake
#                 success
#   5 argv        the body never reaches argv: msg_send_tool's function body
#                 references the body exactly once (the stdin pipe), and the
#                 msg_send dispatch case never emits --body/-m
#   6 codex       under TILLANDSIAS_FORGE_MSG_DRY_RUN=1 the Codex entrypoint
#                 prints the pending-message line and inbox/new is untouched
#   7 opencode    the same property for the OpenCode entrypoint (task 3.2)
#   8 protocol    an invalid msg_send call (no `to`) is a JSON-RPC protocol
#                 error (-32602), not a silently-executed tool
#
# PRE-FIX RESULT: arms 1-3, 5, 8 fail (no such tools); arm 4 fails (nothing to
# degrade); arms 6-7 fail (the entrypoints print nothing).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FP="$ROOT/images/default/config-overlay/mcp/forge-plan.sh"
CODEX_ENTRYPOINT="$ROOT/images/default/entrypoint-forge-codex.sh"
OPENCODE_ENTRYPOINT="$ROOT/images/default/entrypoint-forge-opencode.sh"
pass=0
total=8
ok() { echo "ok:   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1" >&2; }

. "$ROOT/scripts/plan-binary-probe.sh"
_plan="$(cd "$ROOT" && resolve_plan_binary 2>/dev/null)" || _plan=""
case "$_plan" in ./*) _plan="$ROOT/${_plan#./}" ;; esac
if [ -z "$_plan" ]; then
    echo "fail:fleet-msg-mcp:no-plan-binary"
    echo "  why: the round-trip and degraded arms drive the real binary; with none there is nothing to test" >&2
    echo "  remedy: cargo build --release -p tillandsias-plan, or export TILLANDSIAS_PLAN_BIN=<path>" >&2
    exit 1
fi
PLAN="$_plan"

W="$(mktemp -d "${TMPDIR:-/tmp}/fleet-msg-mcp.XXXXXX")"
trap 'rm -rf "$W"' EXIT
H=fixturehost
STATE="$W/state"
LANES="$STATE/tillandsias/msg/lanes"
mkdir -p "$W/home" "$W/fleet" "$W/bin"
ln -sf "$PLAN" "$W/bin/tillandsias-plan"

snap() { # snap <dir> -> a digest of every file under <dir> (paths and bytes)
    if [ -d "$1" ]; then
        (cd "$1" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do
            printf '%s ' "$f"; cksum <"$f"; done)
    fi
}

# rpc <request-json> -> forge-plan.sh's one line of stdout, over the REAL
# binary and a temp XDG_STATE_HOME/lane; every env var below mirrors
# test-fleet-msg-store.sh's hermetic `m()` harness.
rpc() {
    env -u TILLANDSIAS_MSG_ROOT -u TILLANDSIAS_MSG_LANE_DIR -u TILLANDSIAS_MSG_SHAPE_LAX \
        HOME="$W/home" XDG_STATE_HOME="$STATE" TILLANDSIAS_MSG_HOST="$H" \
        TILLANDSIAS_MSG_LANE=a-default TILLANDSIAS_MSG_FORGE_MOUNT="$W/no-forge-mount" \
        TILLANDSIAS_MSG_FLEET_DIR="$W/fleet" TILLANDSIAS_PLAN_BIN="$PLAN" \
        TILLANDSIAS_PLAN_INDEX="$ROOT/plan/index.yaml" \
        bash "$FP" 2>"$W/rpc.err" <<<"$1"
}
call() { rpc "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/call\",\"params\":{\"name\":\"$1\",\"arguments\":$2}}"; }
text() { "$PLAN" json get -r '.result.content[0].text // empty' <<<"$1" 2>/dev/null; }

# ── arm 1: surface — the tool list, and the negative control ────────────────
list="$(rpc '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')"
# One tool name per line, each wrapped in quotes so the "\"msg_send\"" checks
# below keep matching whole names (no jq: the call-site ratchet, 1375-tsfu).
names="$("$PLAN" json get -r '.result.tools[].name' <<<"$list" 2>/dev/null | sort | sed 's/.*/"&"/')"
has_ack=0
"$PLAN" json get -e '.result.tools[] | select(.name == "msg_ack")' <<<"$list" >/dev/null 2>&1 && has_ack=1
if grep -qF '"msg_send"' <<<"$names" \
    && grep -qF '"msg_recv"' <<<"$names" \
    && grep -qF '"msg_list"' <<<"$names" \
    && grep -qF '"msg_status"' <<<"$names" \
    && [ "$has_ack" = 0 ]; then
    ok "1 surface: tools/list carries msg_send, msg_recv, msg_list, msg_status; NEGATIVE CONTROL: no msg_ack tool exists"
else
    bad "1 names=[$names] has_ack=$has_ack"
fi

# ── arm 2: send -> status round trip ─────────────────────────────────────────
send_body='FYI:1506-ssb5:mcp round trip
- 1506-ssb5'
# JSON string literal without jq (call-site ratchet, 1375-tsfu): escape
# backslash, double quote and newline, which is all these fixed bodies carry.
json_str() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; printf '"%s"' "$s"; }
send_args="{\"to\":[\"$H/b-default\"],\"body\":$(json_str "$send_body")}"
resp="$(call msg_send "$send_args")"
send_text="$(text "$resp")"
id="${send_text#ok:msg:queued:}"
status1="$(text "$(call msg_status "{\"id\":$(json_str "$id")}")")"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat >"$LANES/a-default/receipts/$id" <<EOF
id: $id
from: $H/a-default
ts: $NOW
ttl_s: 86400
broadcast: false
recipients:
- to: $H/b-default
  state: acked
  at: $NOW
  via: local
EOF
status2="$(text "$(call msg_status "{\"id\":$(json_str "$id")}")")"
want2="$(printf 'acked:%s/b-default@%s\nvia:local' "$H" "$NOW")"
case "$id" in
    m-*) idshape=1 ;;
    *) idshape=0 ;;
esac
if [ "$idshape" = 1 ] && [ "$status1" = "pending" ] && [ "$status2" = "$want2" ]; then
    ok "2 round-trip: msg_send prints ok:msg:queued:<id> at once; msg_status reads pending, then acked:<host>/<lane>@<ts> + via:local from the fixture-written receipt"
else
    bad "2 send=[$send_text] status1=[$status1] status2=[$status2]"
fi

# ── arm 3: secret-shaped body — refused, nothing written ────────────────────
before="$(snap "$LANES/a-default/outbox")"
tok="ghp_$(printf 'a%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36)"
secret_args="{\"to\":[\"$H/b-default\"],\"body\":$(json_str "FYI:creds:leak
- 1506-ssb5 $tok")}"
resp3="$(call msg_send "$secret_args")"
text3="$(text "$resp3")"
after="$(snap "$LANES/a-default/outbox")"
if grep -qF 'refused:msg:secret-shaped:github-token' <<<"$text3" \
    && grep -q 'why:' <<<"$text3" && grep -q 'remedy:' <<<"$text3" \
    && [ "$before" = "$after" ]; then
    ok "3 secret: NEGATIVE CONTROL — an MCP msg_send with a secret-shaped body is refused with why+remedy and writes nothing to the outbox"
else
    bad "3 text=[$text3] before=[$before] after=[$after]"
fi

# ── arm 4: degraded — a stub binary whose capabilities omits msg ────────────
cat >"$W/bin/stub-plan" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    capabilities) printf 'answer\ncheck\nstatus\n' ;;
    *) exit 1 ;;
esac
STUB
chmod +x "$W/bin/stub-plan"
degraded() { # degraded <tool> <args-json>
    env TILLANDSIAS_PLAN_BIN="$W/bin/stub-plan" TILLANDSIAS_PLAN_INDEX="$ROOT/plan/index.yaml" \
        bash "$FP" 2>/dev/null <<<"{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/call\",\"params\":{\"name\":\"$1\",\"arguments\":$2}}"
}
d_send="$(text "$(degraded msg_send '{"to":["h/b"],"body":"FYI:x:y"}')")"
d_recv="$(text "$(degraded msg_recv '{}')")"
d_list="$(text "$(degraded msg_list '{}')")"
d_status="$(text "$(degraded msg_status '{"id":"m-x"}')")"
d4=1
for t in "$d_send" "$d_recv" "$d_list" "$d_status"; do
    [ "$("$PLAN" json get -r '.confidence // empty' <<<"$t" 2>/dev/null)" = "unsupported" ] || d4=0
done
if [ "$d4" = 1 ]; then
    ok "4 degraded: with a stub binary whose capabilities omits msg, msg_send/msg_recv/msg_list/msg_status all answer the degraded envelope with confidence=unsupported"
else
    bad "4 send=[$d_send] recv=[$d_recv] list=[$d_list] status=[$d_status]"
fi

# ── arm 5: the body never touches argv ──────────────────────────────────────
# EVERY reference to "$body" inside msg_send_tool must be the stdin-piping
# idiom (`printf '%s' "$body" | ...`); none may sit after the pipe as a bare
# argv token (a `--body "$body"`/`-m "$body"` shape).
fn_body="$(awk '/^msg_send_tool\(\) \{/{f=1} f{print} f&&/^}/{exit}' "$FP")"
body_refs="$(printf '%s' "$fn_body" | grep -o '"\$body"' | wc -l | tr -d ' ')"
body_pipe_uses="$(printf '%s' "$fn_body" | grep -cF "printf '%s' \"\$body\" |")"
send_case="$(awk '/^                "msg_send"\)$/{f=1} f{print} f&&/^                    ;;$/{exit}' "$FP")"
if [ -n "$fn_body" ] && [ "$body_refs" -gt 0 ] && [ "$body_refs" = "$body_pipe_uses" ] \
    && ! grep -qE -- '--body|(^|[^-])-m ' <<<"$send_case"; then
    ok "5 argv: every reference to \$body in msg_send_tool is the stdin pipe (never a bare argv token); the msg_send dispatch case never emits --body/-m"
else
    bad "5 body_refs=$body_refs body_pipe_uses=$body_pipe_uses fn_lines=$(printf '%s' "$fn_body" | grep -c .)"
fi

# ── arm 6/7: the Codex and OpenCode entrypoints print pending mail ──────────
entrypoint_arm() { # entrypoint_arm <script> <label>
    local script="$1" label="$2" lane_dir out rc still
    lane_dir="$W/entry-$label/state/tillandsias/msg/lanes/b-default"
    mkdir -p "$lane_dir/inbox/new" "$lane_dir/inbox/cur"
    local now
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    cat >"$lane_dir/inbox/new/m-fixture-1" <<EOF
id: m-fixture-1
from: yoga/host
to:
- $H/b-default
from_agent: fixture
seq: 1
ts: $now
ttl_s: 86400
broadcast: false
kind: FYI
body: 'FYI:test:hello'
EOF
    out="$(env PATH="$W/bin:$PATH" XDG_STATE_HOME="$W/entry-$label/state" \
        TILLANDSIAS_MSG_HOST="$H" TILLANDSIAS_MSG_LANE=b-default \
        TILLANDSIAS_MSG_FORGE_MOUNT="$W/entry-$label/no-mount" \
        TILLANDSIAS_MSG_FLEET_DIR="$W/entry-$label/fleet" \
        TILLANDSIAS_FORGE_MSG_DRY_RUN=1 bash "$script" 2>&1)"
    rc=$?
    still=0
    [ -f "$lane_dir/inbox/new/m-fixture-1" ] && still=1
    if [ "$rc" = 0 ] && grep -qF '1 pending message(s)' <<<"$out" && [ "$still" = 1 ]; then
        return 0
    fi
    printf 'rc=%s out=[%s] still=%s\n' "$rc" "$out" "$still" >&2
    return 1
}
if entrypoint_arm "$CODEX_ENTRYPOINT" codex; then
    ok "6 codex: under the dry-run seam the Codex entrypoint prints the pending-message count line and inbox/new is untouched"
else
    bad "6 codex entrypoint (see stderr above)"
fi
if entrypoint_arm "$OPENCODE_ENTRYPOINT" opencode; then
    ok "7 opencode: under the dry-run seam the OpenCode entrypoint prints the pending-message count line and inbox/new is untouched"
else
    bad "7 opencode entrypoint (see stderr above)"
fi

# ── arm 8: invalid params is a protocol error, not a silent tool call ───────
resp8="$(call msg_send '{"body":"FYI:x:y"}')"
if [ "$("$PLAN" json get -r '.error.code // empty' <<<"$resp8" 2>/dev/null)" = "-32602" ] \
    && [ "$("$PLAN" json get -r '.result // empty' <<<"$resp8" 2>/dev/null)" = "" ]; then
    ok "8 protocol: msg_send with no 'to' is a JSON-RPC -32602 error, not a tool result"
else
    bad "8 resp=[$resp8]"
fi

if [ "$pass" = "$total" ]; then
    echo "ok:fleet-msg-mcp:${pass}/${total}"
else
    echo "fail:fleet-msg-mcp:${pass}/${total}"
    exit 1
fi
