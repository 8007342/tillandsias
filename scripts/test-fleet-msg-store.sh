#!/usr/bin/env bash
# @trace order:1506-nvqt, openspec/changes/fleet-messaging-poc/specs/fleet-messaging/spec.md
#
# The fleet message bus's LOCAL store: `tillandsias-plan msg` over a temp
# XDG_STATE_HOME. No daemon runs here and no socket is opened; where the
# exit criteria need the infrastructure's ack, the FIXTURE writes the receipt
# (the mover is 1506-q7ab). Twelve named arms, one per clause of 1506-nvqt's
# exit criteria as amended by the ack-semantics ruling (2026-09-29):
#
#   1 shape       a 9-line body is refused:msg:shape:lines>8, outbox unchanged
#   2 secret      ghp_ + 36 chars is refused:msg:secret-shaped:github-token
#                 NEGATIVE CONTROL: TILLANDSIAS_MSG_SHAPE_LAX=1 (a seam honoured
#                 only on an explicit TILLANDSIAS_MSG_ROOT) makes this arm FAIL
#   3 duplicate   a repeated --id prints skip:msg:duplicate:<id>, store unchanged
#   4 queued      send with no daemon prints ok:msg:queued:<id> within 1 s and
#                 status prints pending
#   5 recv        recv twice prints the same id, recv --keep leaves new/
#                 untouched, the sender's receipt byte-identical throughout
#   6 status      pending -> acked:<host>/<lane>@<ts> + via:local, and
#                 undelivered:expired, from fixture-written receipts
#   7 ttl         --ttl 30 / 700000 refused:msg:ttl-out-of-bounds:<v>:min=60:max=604800;
#                 an omitted --ttl records 86400
#   8 expiry      a message past its TTL in inbox/ is not printed and is gone
#   9 reply       --in-reply-to a broadcast copy planted in the LOCAL INBOX is
#                 refused:msg:reply-to-broadcast:<id> with the remedy (the
#                 sender has no receipt for it, so a receipts-only check fails
#                 this arm); an unknown id is refused:msg:unknown-reply-target
#  10 gap         a seq gap is printed with the gap: prefix
#  11 no-lane     whoami with no lane is refused:msg:no-lane, stdout empty
#  12 surface     capabilities lists msg, the forge-plan probe
#                 (lib-expert-capability.sh) sees it, and `msg ack` is refused
#                 as an unknown verb with every receipt unchanged
#
# PRE-FIX RESULT: every arm fails — `msg` was an unknown subcommand.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; total=12
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; }

_plan="$(cd "$ROOT" && . scripts/plan-binary-probe.sh && resolve_plan_binary 2>/dev/null)" || _plan=""
case "$_plan" in ./*) _plan="$ROOT/${_plan#./}" ;; esac
if [ -z "$_plan" ]; then
    echo "fail:fleet-msg-store:no-plan-binary"
    echo "  why: the arms drive the real binary; with none there is nothing to test" >&2
    echo "  remedy: cargo build -p tillandsias-plan, or export TILLANDSIAS_PLAN_BIN=<path>" >&2
    exit 1
fi
PLAN="$_plan"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
H=fixturehost
STATE="$T/state"
LANES="$STATE/tillandsias/msg/lanes"
A="$LANES/a-default"; B="$LANES/b-default"
mkdir -p "$T/home" "$T/fleet"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
BODY="FYI:1506-nvqt:store fixture
- scripts/test-fleet-msg-store.sh"

# m <lane|-> <args...>: runs `msg` hermetically; sets OUT, ERR, RC.
# stdin is the caller's (a body or </dev/null).
m() {
    local lane="$1"; shift
    OUT="$(env -u TILLANDSIAS_MSG_ROOT -u TILLANDSIAS_MSG_LANE_DIR -u TILLANDSIAS_MSG_LANE \
        -u TILLANDSIAS_MSG_SHAPE_LAX -u TILLANDSIAS_AGENT_ID \
        HOME="$T/home" XDG_STATE_HOME="$STATE" TILLANDSIAS_MSG_HOST="$H" \
        TILLANDSIAS_MSG_FORGE_MOUNT="$T/no-forge-mount" TILLANDSIAS_MSG_FLEET_DIR="$T/fleet" \
        ${lane:+TILLANDSIAS_MSG_LANE=$lane} ${EXTRA_ENV:-} \
        "$PLAN" msg "$@" 2>"$T/err")"; RC=$?
    ERR="$(cat "$T/err")"
}
has() { grep -qF -- "$1" <<<"$2"; }
first() { printf '%s\n' "$1" | sed -n 1p; }
afforded() { has "  why: " "$1" && has "  remedy: " "$1"; }
# snap <dir>: a digest of every file under <dir> (paths and bytes).
snap() {
    if [ -d "$1" ]; then
        (cd "$1" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do
            printf '%s ' "$f"; cksum < "$f"; done)
    fi
}
qid() { printf '%s' "${OUT#ok:msg:queued:}"; }

# ── arm 1: shape ─────────────────────────────────────────────────────────────
nine="$(printf 'FYI:x:nine lines\n- 1506-nvqt\n- 1506-nvqt\n- 1506-nvqt\n- 1506-nvqt\n- 1506-nvqt\n- 1506-nvqt\n- 1506-nvqt\n- 1506-nvqt')"
before="$(snap "$A/outbox")"
m a-default send --to "$H/b-default" <<<"$nine"
if [ "$(first "$ERR")" = "refused:msg:shape:lines>8" ] && [ "$RC" = 1 ] && [ -z "$OUT" ] \
   && afforded "$ERR" && [ "$before" = "$(snap "$A/outbox")" ]; then
    ok "1 shape: a 9-line body is refused:msg:shape:lines>8 with why/remedy and an unchanged outbox"
else bad "1 out=[$OUT] rc=$RC err=[$(first "$ERR")]"; fi

# ── arm 2: secret (and its negative control) ────────────────────────────────
secret_arm() {
    local tok b0
    tok="ghp_$(printf 'a%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36)"
    b0="$(snap "$A/outbox")"
    # The body is otherwise well-shaped (it carries a ref), so with the secret
    # check off the send SUCCEEDS — the control below fails the arm for that
    # reason and no other.
    m a-default send --to "$H/b-default" <<<"FYI:creds:leak
- 1506-nvqt $tok"
    [ "$(first "$ERR")" = "refused:msg:secret-shaped:github-token" ] && [ "$RC" = 1 ] \
        && afforded "$ERR" && [ "$b0" = "$(snap "$A/outbox")" ]
}
if secret_arm; then s_ok=1; else s_ok=0; s_err="$ERR"; fi
EXTRA_ENV="TILLANDSIAS_MSG_SHAPE_LAX=1 TILLANDSIAS_MSG_ROOT=$STATE/tillandsias/msg"
neg=0
if ! secret_arm && [ "${OUT#ok:msg:queued:}" != "$OUT" ]; then neg=1; fi
EXTRA_ENV=""
if [ "$s_ok" = 1 ] && [ "$neg" = 1 ]; then
    ok "2 secret: ghp_+36 is refused:msg:secret-shaped:github-token; NEGATIVE CONTROL: the LAX seam makes the arm fail"
else bad "2 secret_ok=$s_ok neg_control_failed_the_arm=$neg err=[$(first "${s_err:-}")]"; fi

# ── arm 3: duplicate id ──────────────────────────────────────────────────────
m a-default send --to "$H/b-default" --id fixture-dup-1 <<<"$BODY"
o1="$OUT"
b0="$(snap "$A")"
m a-default send --to "$H/b-default" --id fixture-dup-1 <<<"ASK:other:body
- 1506-nvqt"
if [ "$o1" = "ok:msg:queued:fixture-dup-1" ] && [ "$OUT" = "skip:msg:duplicate:fixture-dup-1" ] \
   && [ "$RC" = 0 ] && [ "$b0" = "$(snap "$A")" ]; then
    ok "3 duplicate: a repeated --id prints skip:msg:duplicate:<id> and writes nothing"
else bad "3 first=[$o1] out=[$OUT] rc=$RC"; fi

# ── arm 4: queued at once, pending ───────────────────────────────────────────
t0="${EPOCHREALTIME:-$(date +%s)}"
m a-default send --to "$H/b-default" <<<"$BODY"
t1="${EPOCHREALTIME:-$(date +%s)}"
ID="$(qid)"; o4="$OUT"
el="$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%d", ((b - a) <= 1.0) }')"
m a-default status "$ID" </dev/null
case "$ID" in m-[0-9]*t[0-9]*z-[0-9a-f]*) idshape=1 ;; *) idshape=0 ;; esac
if [ "${o4#ok:msg:queued:}" != "$o4" ] && [ "$idshape" = 1 ] && [ "$el" = 1 ] \
   && [ -f "$A/outbox/new/$ID" ] && [ "$OUT" = "pending" ] && [ "$RC" = 0 ]; then
    ok "4 queued: ok:msg:queued:<id> within 1 s with no daemon; status prints pending"
else bad "4 send=[$o4] id-shape=$idshape within-1s=$el status=[$OUT] rc=$RC"; fi

# ── arm 5: recv is local bookkeeping ─────────────────────────────────────────
# The fixture plays the mover: the copy lands in b's inbox/new.
mkdir -p "$B/inbox/new" "$B/inbox/cur"
cp "$A/outbox/new/$ID" "$B/inbox/new/$ID"
r0="$(cksum < "$A/receipts/$ID")"
m b-default recv --keep </dev/null; k="$OUT"
kept=0; [ -f "$B/inbox/new/$ID" ] && kept=1
m b-default recv </dev/null; r1="$OUT"
m b-default recv </dev/null; r2="$OUT"
moved=0; [ ! -f "$B/inbox/new/$ID" ] && [ -f "$B/inbox/cur/$ID" ] && moved=1
if has "msg:$ID from=$H/a-default" "$k" && [ "$kept" = 1 ] && has "msg:$ID " "$r1" \
   && [ "$r1" = "$r2" ] && [ "$moved" = 1 ] && [ "$r0" = "$(cksum < "$A/receipts/$ID")" ]; then
    ok "5 recv: twice prints the same id, --keep leaves new/ untouched, the sender's receipt is byte-identical"
else bad "5 keep=[$k] kept=$kept r1=[$r1] r2=[$r2] moved=$moved"; fi

# ── arm 6: status walks the fixture-written receipts ─────────────────────────
m a-default status "$ID" </dev/null; s0="$OUT"
cat > "$A/receipts/$ID" <<EOF
id: $ID
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
m a-default status "$ID" </dev/null; s1="$OUT"
cat > "$A/receipts/$ID" <<EOF
id: $ID
from: $H/a-default
ts: $NOW
ttl_s: 86400
broadcast: false
recipients:
- to: $H/b-default
  state: undelivered
  at: $NOW
  reason: expired
EOF
m a-default status "$ID" </dev/null; s2="$OUT"
want1="$(printf 'acked:%s/b-default@%s\nvia:local' "$H" "$NOW")"
if [ "$s0" = "pending" ] && [ "$s1" = "$want1" ] && [ "$s2" = "undelivered:expired" ]; then
    ok "6 status: pending -> acked:<host>/<lane>@<ts> + via:local, and undelivered:expired"
else bad "6 s0=[$s0] s1=[$s1] s2=[$s2]"; fi

# ── arm 7: TTL bounds and default ────────────────────────────────────────────
b0="$(snap "$A")"
m a-default send --to "$H/b-default" --ttl 30 <<<"$BODY"; e30="$(first "$ERR")"; c30=$RC; a30="$ERR"
m a-default send --to "$H/b-default" --ttl 700000 <<<"$BODY"; e7="$(first "$ERR")"; c7=$RC
unchanged=0; [ "$b0" = "$(snap "$A")" ] && unchanged=1
m a-default send --to "$H/b-default" <<<"$BODY"; did="$(qid)"
dttl="$(sed -n 's/^ttl_s: //p' "$A/outbox/new/$did" 2>/dev/null)"
if [ "$e30" = "refused:msg:ttl-out-of-bounds:30:min=60:max=604800" ] && [ "$c30" = 1 ] \
   && [ "$e7" = "refused:msg:ttl-out-of-bounds:700000:min=60:max=604800" ] && [ "$c7" = 1 ] \
   && afforded "$a30" && [ "$unchanged" = 1 ] && [ "$dttl" = "86400" ]; then
    ok "7 ttl: 30 and 700000 are refused out-of-bounds, nothing written; an omitted --ttl records 86400"
else bad "7 e30=[$e30] e7=[$e7] unchanged=$unchanged default=[$dttl]"; fi

# ── arm 8: an unread message past its TTL leaves the mailbox ────────────────
cat > "$B/inbox/new/m-fixture-expired" <<EOF
id: m-fixture-expired
from: $H/z-default
to:
- $H/b-default
from_agent: fixture
seq: 1
ts: 2000-01-01T00:00:00Z
ttl_s: 60
broadcast: false
kind: FYI
body: 'FYI:old:long expired'
EOF
m b-default recv </dev/null
if ! has "m-fixture-expired" "$OUT" && [ ! -e "$B/inbox/new/m-fixture-expired" ] \
   && [ ! -e "$B/inbox/cur/m-fixture-expired" ] && [ "$RC" = 0 ]; then
    ok "8 expiry: a message past its TTL is not printed by recv and is gone from inbox/"
else bad "8 out=[$OUT] rc=$RC"; fi

# ── arm 9: reply-to-broadcast (recipient side) and unknown target ───────────
mkdir -p "$A/inbox/new"
cat > "$A/inbox/new/m-fixture-bcast" <<EOF
id: m-fixture-bcast
from: $H/z-default
to:
- $H/a-default
from_agent: fixture
seq: 0
ts: $NOW
ttl_s: 86400
broadcast: true
kind: FYI
body: 'FYI:all:to everyone'
EOF
b0="$(snap "$A/outbox")"
m a-default send --to "$H/z-default" --in-reply-to m-fixture-bcast <<<"$BODY"
e9="$(first "$ERR")"; c9=$RC; a9="$ERR"
m a-default send --to "$H/z-default" --in-reply-to m-never-seen <<<"$BODY"
u9="$(first "$ERR")"; cu=$RC
want9="refused:msg:reply-to-broadcast:m-fixture-bcast:a broadcast has no single counterpart; send a new message to $H/z-default instead"
if [ "$e9" = "$want9" ] && [ "$c9" = 1 ] && afforded "$a9" && [ ! -e "$A/receipts/m-fixture-bcast" ] \
   && [ "$u9" = "refused:msg:unknown-reply-target:m-never-seen" ] && [ "$cu" = 1 ] \
   && [ "$b0" = "$(snap "$A/outbox")" ]; then
    ok "9 reply: a reply to a broadcast in the local inbox is refused naming the remedy; an unknown id is unknown-reply-target"
else bad "9 got=[$e9] unknown=[$u9]"; fi

# ── arm 10: a seq gap is flagged ─────────────────────────────────────────────
for s in 1 3; do
    cat > "$B/inbox/new/m-fixture-seq$s" <<EOF
id: m-fixture-seq$s
from: $H/y-default
to:
- $H/b-default
from_agent: fixture
seq: $s
ts: $NOW
ttl_s: 86400
broadcast: false
kind: FYI
body: 'FYI:seq:number $s'
EOF
done
m b-default recv </dev/null
if has "msg:m-fixture-seq1 " "$OUT" && ! has "gap:msg:m-fixture-seq1 " "$OUT" \
   && has "gap:msg:m-fixture-seq3 " "$OUT"; then
    ok "10 gap: seq 3 after seq 1 is printed with the gap: prefix; seq 1 is not"
else bad "10 out=[$OUT]"; fi

# ── arm 11: no lane ──────────────────────────────────────────────────────────
m "" whoami </dev/null
if [ -z "$OUT" ] && [ "$(first "$ERR")" = "refused:msg:no-lane" ] && [ "$RC" = 1 ] && afforded "$ERR"; then
    m a-default whoami </dev/null
    if [ "$OUT" = "$H/a-default" ]; then
        ok "11 no-lane: whoami with no lane is refused:msg:no-lane with an empty stdout; with one it prints <host>/<lane>"
    else bad "11 with-lane=[$OUT]"; fi
else bad "11 out=[$OUT] rc=$RC err=[$(first "$ERR")]"; fi

# ── arm 12: the surface — capabilities, the forge-plan probe, no ack verb ────
caps="$("$PLAN" capabilities 2>/dev/null)"
probe=0
if (. "$ROOT/images/default/lib-expert-capability.sh" \
      && tillandsias_expert_capability "$PLAN" "" \
      && case ",${TILLANDSIAS_EXPERT_CAP_NOW:-}," in *,msg,*) exit 0 ;; *) exit 1 ;; esac); then
    probe=1
fi
b0="$(snap "$LANES")"
m a-default ack "$ID" </dev/null
if grep -qx msg <<<"$caps" && [ "$probe" = 1 ] && [ "$(first "$ERR")" = "refused:msg:unknown-verb:ack" ] \
   && [ "$RC" = 1 ] && afforded "$ERR" && [ "$b0" = "$(snap "$LANES")" ]; then
    ok "12 surface: capabilities lists msg, the forge-plan probe sees it, msg ack is an unknown verb and changes no receipt"
else bad "12 caps-has-msg=$(grep -cx msg <<<"$caps") probe=$probe ack=[$(first "$ERR")]"; fi

if [ "$pass" = "$total" ]; then
    echo "ok:fleet-msg-store:${pass}/${total}"
else
    echo "fail:fleet-msg-store:${pass}/${total}"
    exit 1
fi
