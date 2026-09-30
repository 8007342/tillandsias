#!/usr/bin/env bash
# @trace order:1506-q7ab, openspec/changes/fleet-messaging-poc/specs/fleet-messaging/spec.md
#
# The fleet message bus's SAME-HOST rung: the REAL `tillandsias --msg-serve`
# (the resident mover) and the REAL `tillandsias-plan msg` CLI over a temp
# store (TILLANDSIAS_MSG_ROOT), temp HOME, XDG dirs and wake socket. No
# container, no network, nothing under the real $HOME. Arms, one per clause of
# 1506-q7ab's exit criteria as amended by the ack-semantics ruling:
#
#   1 ack         a-default -> b-default: a's status reads
#                 acked:<host>/b-default@<ts> + via:local while NO recv has run
#                 in b (b's inbox/cur empty, no recv-state)
#   2 mount       an envelope in a-default's outbox claiming from b-default
#                 lands in a's dead/, refused:msg:from-lane-mismatch logged,
#                 b-default byte-identical, a's status
#                 undelivered:refused:from-lane-mismatch
#   3 secret      hvs.+24 chars: refused at `msg send` (CLI) AND, written
#                 straight into outbox/new, by the mover:
#                 refused:msg:secret-shaped:vault-token, nothing delivered
#   4 reply       a reply to a broadcast b holds: refused at `msg send` (CLI)
#                 AND, written straight into b's outbox, by the mover; b's
#                 status reads undelivered:refused:reply-to-broadcast
#   5 ttl         a --ttl 60 message acked into b-default is gone from b's
#                 inbox 61 s after the send; a's status still acked:
#   6 wake        recv --wait in c-default returns within 2 s of a delivery
#   7 wildcard    host -> @<host>/* reaches a-default and b-default (every
#                 lane but the sender) with two acked receipt lines
#   8 plain       a lane whose outbox/new is a symlink onto b-default's inbox
#                 is refused:msg:lane-not-plain; b's mail is neither read nor
#                 moved (the mover never follows a link out of a lane)
# Mutation controls (each re-runs an arm's predicate against a seam that
# removes the property; the arm must then FAIL):
#   NEG-LAX       TILLANDSIAS_MSG_MOVER_LAX=1 (the mover's second secret check
#                 off) makes arm 3's direct-write half FAIL: it is delivered
#   NEG-FSYNC     TILLANDSIAS_MSG_SKIP_FSYNC=1 makes arm 1 FAIL: the mover
#                 holds no proof of durability and refuses the ack
#   GUARD         the LAX seam WITHOUT an explicit TILLANDSIAS_MSG_ROOT is
#                 ignored: a real store's mover still refuses the secret
#
# PRE-FIX RESULT: FAILS — `--msg-serve` is an unknown flag
# ("Unsupported option: --msg-serve"). Point TILLANDSIAS_MSG_SERVE_BIN at a
# pre-1506-q7ab tillandsias to see every arm fail that way.
#
# Arm 5 waits in real time (61 s after its send); the other arms run inside
# that window, so the fixture takes about 65 s after the build.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; total=8; controls=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; }

if ! command -v cargo >/dev/null 2>&1 && [ -z "${TILLANDSIAS_MSG_SERVE_BIN:-}" ]; then
    echo "skip:fleet-msg-same-host:no-cargo"
    echo "  why: the arms drive the real binaries and there is no cargo to build them" >&2
    echo "  remedy: install cargo, or export TILLANDSIAS_MSG_SERVE_BIN and TILLANDSIAS_PLAN_BIN" >&2
    exit 3
fi

T="$(mktemp -d "${TMPDIR:-/tmp}/fleet-msg-same-host.XXXXXX")"
MPID=""
cleanup() {
    if [ -n "$MPID" ]; then kill "$MPID" 2>/dev/null; wait "$MPID" 2>/dev/null; fi
    rm -rf "$T"
}
trap cleanup EXIT

TARGET="${CARGO_TARGET_DIR:-$ROOT/target}/debug"
if [ -z "${TILLANDSIAS_MSG_SERVE_BIN:-}" ]; then
    echo "[fleet-msg-same-host] building tillandsias and tillandsias-plan..." >&2
    if ! (cd "$ROOT" && cargo build -p tillandsias-headless --bin tillandsias \
            && cargo build -p tillandsias-plan --bin tillandsias-plan) >"$T/build.log" 2>&1; then
        tail -20 "$T/build.log"
        echo "fail:fleet-msg-same-host:build"
        echo "  why: the arms need the real binaries and the build failed (log above)" >&2
        echo "  remedy: fix the build; if build.rs asks for the router sidecar, run bash scripts/build-sidecar.sh once" >&2
        exit 1
    fi
fi
BIN="${TILLANDSIAS_MSG_SERVE_BIN:-$TARGET/tillandsias}"
PLAN="${TILLANDSIAS_PLAN_BIN:-$TARGET/tillandsias-plan}"
for b in "$BIN" "$PLAN"; do
    if [ ! -x "$b" ]; then
        echo "fail:fleet-msg-same-host:binary-missing:$b"
        echo "  why: the arms drive the real binaries" >&2
        echo "  remedy: cargo build -p tillandsias-headless -p tillandsias-plan, or export TILLANDSIAS_MSG_SERVE_BIN / TILLANDSIAS_PLAN_BIN" >&2
        exit 1
    fi
done

H=fixturehost
S="$T/store"                     # the explicit store root
WAKE="$T/run/tillandsias/msg.sock"
mkdir -p "$T/home" "$T/state" "$T/run" "$T/fleet"
chmod 700 "$T/run"
LANES="$S/lanes"
BODY="FYI:1506-q7ab:same-host fixture
- scripts/test-fleet-msg-same-host.sh"
SECRET_BODY="FYI:creds:leak
- 1506-q7ab hvs.$(printf 'a%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24)"

# m <lane> <msg args...>: the CLI against store $S; sets OUT, ERR, RC.
m() {
    local lane="$1"; shift
    OUT="$(env -u TILLANDSIAS_MSG_LANE_DIR -u TILLANDSIAS_MSG_SHAPE_LAX -u TILLANDSIAS_AGENT_ID \
        HOME="$T/home" XDG_STATE_HOME="$T/state" XDG_RUNTIME_DIR="$T/run" \
        TILLANDSIAS_MSG_ROOT="${STORE:-$S}" TILLANDSIAS_MSG_HOST="$H" TILLANDSIAS_MSG_WAKE_SOCK="$WAKE" \
        TILLANDSIAS_MSG_FORGE_MOUNT="$T/no-forge-mount" TILLANDSIAS_MSG_FLEET_DIR="$T/fleet" \
        TILLANDSIAS_MSG_LANE="$lane" "$PLAN" msg "$@" 2>"$T/err")"; RC=$?
    ERR="$(cat "$T/err")"
}
# mover <env assignments...> <args...>: the real binary, hermetic.
mover() {
    env -u TILLANDSIAS_MSG_ROOT -u TILLANDSIAS_MSG_MOVER_LAX -u TILLANDSIAS_MSG_SKIP_FSYNC \
        -u TILLANDSIAS_MSG_WAKE_SOCK \
        HOME="$T/home" XDG_STATE_HOME="$T/state" XDG_RUNTIME_DIR="$T/run" \
        TILLANDSIAS_MSG_HOST="$H" TILLANDSIAS_MSG_POLL_MS=100 TILLANDSIAS_MSG_SWEEP_MS=250 \
        "$@"
}
has() { grep -qF -- "$1" <<<"$2"; }
line() { printf '%s\n' "$2" | sed -n "$1p"; }
qid() { printf '%s' "${OUT#ok:msg:queued:}"; }
# snap <dir>: a digest of every file under <dir> (paths and bytes).
snap() {
    if [ -d "$1" ]; then
        (cd "$1" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do
            printf '%s ' "$f"; cksum < "$f"; done)
    fi
}
# wait_for <tenths> <command...>: poll until the command succeeds.
wait_for() {
    local n="$1"; shift
    while [ "$n" -gt 0 ]; do
        "$@" && return 0
        sleep 0.1; n=$((n-1))
    done
    "$@"
}
acked_by() { # <sender lane> <id> <mailbox>
    m "$1" status "$2"; has "acked:$3@" "$OUT"
}
# put <store> <lane> <id> <from> <to> <body> [extra yaml line]: an envelope
# written STRAIGHT into outbox/new (tmp then mv), bypassing the CLI.
put() {
    local st="$1" lane="$2" id="$3" from="$4" to="$5" body="$6" extra="${7:-}" d ts
    d="$st/lanes/$lane/outbox"; mkdir -p "$d/tmp" "$d/new"
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    {
        printf 'id: %s\nfrom: %s\nto:\n- %s\nfrom_agent: fixture\nseq: 0\nts: %s\nttl_s: 3600\nbroadcast: false\nkind: FYI\n' \
            "$id" "$from" "$to" "$ts"
        if [ -n "$extra" ]; then printf '%s\n' "$extra"; fi
        printf 'body: |-\n'
        printf '%s\n' "$body" | sed 's/^/  /'
    } >"$d/tmp/.$id"
    mv "$d/tmp/.$id" "$d/new/$id"
}

# ── pre-fix probe ────────────────────────────────────────────────────────────
probe="$(mover TILLANDSIAS_MSG_ROOT="$T/probe" "$BIN" --msg-serve --once 2>&1)"
if has "Unsupported option" "$probe"; then
    echo "FAIL: every arm — --msg-serve is an unknown flag in $BIN (pre-fix)"
    echo "fail:fleet-msg-same-host:0/$total"
    exit 1
fi

# ── the resident, and the lanes a launcher would have made ──────────────────
for l in a-default b-default; do mkdir -p "$LANES/$l"; done
mover TILLANDSIAS_MSG_ROOT="$S" TILLANDSIAS_MSG_WAKE_SOCK="$WAKE" \
    "$BIN" --msg-serve >"$T/mover.out" 2>"$T/mover.log" &
MPID=$!
if ! wait_for 100 test -S "$WAKE"; then
    echo "FAIL: the mover never bound its wake socket"; cat "$T/mover.log"
    echo "fail:fleet-msg-same-host:0/$total"; exit 1
fi
log() { cat "$T/mover.log"; }

# ── arm 5, first half: a --ttl 60 message, timed from the send ──────────────
m a-default send --to "$H/b-default" --ttl 60 <<<"$BODY"
TTL_ID="$(qid)"; TTL_T0="$(date +%s)"   # taken AFTER send: ts <= TTL_T0
wait_for 50 acked_by a-default "$TTL_ID" "$H/b-default"; ttl_acked=$?

# ── arm 1: the ack, before any recv ──────────────────────────────────────────
m a-default send --to "$H/b-default" <<<"$BODY"; A1="$(qid)"
wait_for 50 acked_by a-default "$A1" "$H/b-default"
m a-default status "$A1"
if [ "$RC" = 0 ] && has "acked:$H/b-default@" "$(line 1 "$OUT")" && [ "$(line 2 "$OUT")" = "via:local" ] \
   && [ -f "$LANES/b-default/inbox/new/$A1" ] && [ -z "$(ls -A "$LANES/b-default/inbox/cur")" ] \
   && [ ! -e "$LANES/b-default/recv-state" ]; then
    ok "1 ack: acked:$H/b-default@<ts> + via:local with NO recv run in b-default"
else bad "1 status=[$OUT] rc=$RC b_new=[$(ls "$LANES/b-default/inbox/new")] b_cur=[$(ls "$LANES/b-default/inbox/cur")]"; fi

# ── arm 2: attribution by mount ──────────────────────────────────────────────
b_before="$(snap "$LANES/b-default")"
put "$S" a-default m-fixture-liar "$H/b-default" "$H/b-default" "$BODY"
wait_for 50 test -f "$LANES/a-default/dead/m-fixture-liar"
sleep 0.5
m a-default status m-fixture-liar
if [ -f "$LANES/a-default/dead/m-fixture-liar" ] && has "refused:msg:from-lane-mismatch:m-fixture-liar" "$(log)" \
   && [ "$b_before" = "$(snap "$LANES/b-default")" ] && [ "$OUT" = "undelivered:refused:from-lane-mismatch" ]; then
    ok "2 mount: a lane claiming b-default is refused:msg:from-lane-mismatch to its own dead/, b-default untouched"
else bad "2 dead=$([ -f "$LANES/a-default/dead/m-fixture-liar" ] && echo y) status=[$OUT] b_same=$([ "$b_before" = "$(snap "$LANES/b-default")" ] && echo y)"; fi

# ── arm 3: the secret, at both sites ─────────────────────────────────────────
# secret_direct <store> <id>: the mover-side predicate, reused by NEG-LAX.
secret_direct() {
    [ -f "$1/lanes/a-default/dead/$2" ] && [ ! -e "$1/lanes/b-default/inbox/new/$2" ] \
        && grep -qF "refused:msg:secret-shaped:vault-token:$2" "$3"
}
m a-default send --to "$H/b-default" <<<"$SECRET_BODY"
cli_ok=0
if [ "$(line 1 "$ERR")" = "refused:msg:secret-shaped:vault-token" ] && [ "$RC" = 1 ]; then cli_ok=1; fi
put "$S" a-default m-fixture-secret "$H/a-default" "$H/b-default" "$SECRET_BODY"
wait_for 50 test -f "$LANES/a-default/dead/m-fixture-secret"
m a-default status m-fixture-secret
if [ "$cli_ok" = 1 ] && secret_direct "$S" m-fixture-secret "$T/mover.log" \
   && [ "$OUT" = "undelivered:refused:secret-shaped:vault-token" ]; then
    ok "3 secret: hvs.+24 refused at msg send AND, written straight into outbox/new, by the mover"
else bad "3 cli=$cli_ok status=[$OUT] dead=$([ -f "$LANES/a-default/dead/m-fixture-secret" ] && echo y)"; fi

# ── arm 7: the wildcard (before c-default exists) ────────────────────────────
m host send --to "@$H/*" <<<"$BODY"; BID="$(qid)"
wait_for 50 acked_by host "$BID" "$H/b-default"
wait_for 50 acked_by host "$BID" "$H/a-default"
m host status "$BID"
if [ "$(line 1 "$OUT")" = "broadcast:2" ] && has "acked:$H/a-default@" "$OUT" && has "acked:$H/b-default@" "$OUT" \
   && [ "$(printf '%s\n' "$OUT" | grep -c '^acked:')" = 2 ] \
   && [ -f "$LANES/a-default/inbox/new/$BID" ] && [ -f "$LANES/b-default/inbox/new/$BID" ] \
   && [ ! -e "$LANES/host/inbox/new/$BID" ]; then
    ok "7 wildcard: @$H/* reached a-default and b-default with two acked lines (broadcast:2)"
else bad "7 status=[$OUT]"; fi

# ── arm 4: a reply to that broadcast, at both sites ──────────────────────────
m b-default send --to "$H/host" --in-reply-to "$BID" <<<"$BODY"
cli_ok=0
if has "refused:msg:reply-to-broadcast:$BID" "$(line 1 "$ERR")" && [ "$RC" = 1 ]; then cli_ok=1; fi
put "$S" b-default m-fixture-reply "$H/b-default" "$H/host" "$BODY" "in_reply_to: $BID"
wait_for 50 test -f "$LANES/b-default/dead/m-fixture-reply"
m b-default status m-fixture-reply
if [ "$cli_ok" = 1 ] && [ -f "$LANES/b-default/dead/m-fixture-reply" ] \
   && [ ! -e "$LANES/host/inbox/new/m-fixture-reply" ] \
   && has "refused:msg:reply-to-broadcast:$BID:m-fixture-reply" "$(log)" \
   && [ "$OUT" = "undelivered:refused:reply-to-broadcast" ]; then
    ok "4 reply: a reply to a broadcast is refused at msg send AND, written straight into an outbox, by the mover"
else bad "4 cli=$cli_ok status=[$OUT]"; fi

# ── arm 6: recv --wait and the wake socket ───────────────────────────────────
mkdir -p "$LANES/c-default"
sleep 0.5
( m c-default recv --wait 20; printf '%s\n' "$OUT" >"$T/recv.out" ) &
rpid=$!
sleep 1
w0="$(date +%s)"
m a-default send --to "$H/c-default" <<<"$BODY"; W_ID="$(qid)"
wait "$rpid"; w1="$(date +%s)"
if grep -qF "msg:$W_ID " "$T/recv.out" && [ $((w1 - w0)) -le 2 ]; then
    ok "6 wake: recv --wait returned $((w1 - w0)) s after the send, printing the message"
else bad "6 elapsed=$((w1 - w0)) recv=[$(cat "$T/recv.out")]"; fi

# ── arm 8: a lane that is not plain ──────────────────────────────────────────
b_before="$(snap "$LANES/b-default")"
mkdir -p "$LANES/d-default/outbox"
ln -s ../../b-default/inbox/new "$LANES/d-default/outbox/new"
wait_for 50 grep -qF "refused:msg:lane-not-plain:d-default" "$T/mover.log"
sleep 0.5
if has "refused:msg:lane-not-plain:d-default" "$(log)" && [ "$b_before" = "$(snap "$LANES/b-default")" ] \
   && [ -z "$(ls -A "$LANES/d-default/dead" 2>/dev/null)" ]; then
    ok "8 plain: an outbox symlinked onto b-default's inbox is refused:msg:lane-not-plain; b's mail unread and unmoved"
else bad "8 b_same=$([ "$b_before" = "$(snap "$LANES/b-default")" ] && echo y) d_dead=[$(ls "$LANES/d-default/dead" 2>/dev/null)]"; fi
rm -rf "$LANES/d-default"

# ── controls (fresh stores, one pass each) ───────────────────────────────────
# NEG-LAX: without the mover's second secret check, arm 3's direct write is
# delivered, so its predicate must FAIL.
S2="$T/store-lax"; mkdir -p "$S2/lanes/a-default" "$S2/lanes/b-default"
put "$S2" a-default m-fixture-secret "$H/a-default" "$H/b-default" "$SECRET_BODY"
mover TILLANDSIAS_MSG_ROOT="$S2" TILLANDSIAS_MSG_MOVER_LAX=1 "$BIN" --msg-serve --once >/dev/null 2>"$T/lax.log"
if ! secret_direct "$S2" m-fixture-secret "$T/lax.log" && [ -f "$S2/lanes/b-default/inbox/new/m-fixture-secret" ]; then
    echo "ok:   NEG-LAX: with the mover's second check off, arm 3's direct write is DELIVERED (the arm fails)"
    controls=$((controls+1))
else echo "FAIL: NEG-LAX: the LAX seam did not reach the mover's secret check"; fi

# NEG-FSYNC: with fsync skipped the mover holds no proof and refuses the ack,
# so arm 1's predicate must FAIL.
S3="$T/store-nofsync"; mkdir -p "$S3/lanes/a-default" "$S3/lanes/b-default"
STORE="$S3" m a-default send --to "$H/b-default" <<<"$BODY"; F_ID="$(qid)"
mover TILLANDSIAS_MSG_ROOT="$S3" TILLANDSIAS_MSG_SKIP_FSYNC=1 "$BIN" --msg-serve --once >/dev/null 2>"$T/nofsync.log"
STORE="$S3" m a-default status "$F_ID"
if [ "$OUT" = "pending" ] && grep -qF "refused:msg:ack-without-fsync:$F_ID" "$T/nofsync.log"; then
    echo "ok:   NEG-FSYNC: with fsync skipped the receipt stays pending and the mover says why (arm 1 fails)"
    controls=$((controls+1))
else echo "FAIL: NEG-FSYNC: status=[$OUT] — an ack was written without fsync, or the seam did not reach"; fi

# GUARD: the LAX seam is ignored for a store not named explicitly (here the
# XDG_STATE_HOME default), so it can never weaken a real store.
S4="$T/state/tillandsias/msg"; mkdir -p "$S4/lanes/a-default" "$S4/lanes/b-default"
put "$S4" a-default m-fixture-secret "$H/a-default" "$H/b-default" "$SECRET_BODY"
mover TILLANDSIAS_MSG_MOVER_LAX=1 "$BIN" --msg-serve --once >/dev/null 2>"$T/guard.log"
if secret_direct "$S4" m-fixture-secret "$T/guard.log"; then
    echo "ok:   GUARD: without an explicit TILLANDSIAS_MSG_ROOT the LAX seam is ignored and the secret is refused"
    controls=$((controls+1))
else echo "FAIL: GUARD: the LAX seam weakened a store that was not named explicitly"; fi

# ── arm 5, second half: 61 s after the send ──────────────────────────────────
while [ "$(date +%s)" -lt $((TTL_T0 + 61)) ]; do sleep 0.5; done
m a-default status "$TTL_ID"
if [ "$ttl_acked" = 0 ] && [ ! -e "$LANES/b-default/inbox/new/$TTL_ID" ] && [ ! -e "$LANES/b-default/inbox/cur/$TTL_ID" ] \
   && has "acked:$H/b-default@" "$(line 1 "$OUT")"; then
    ok "5 ttl: the --ttl 60 message acked into b-default is gone from its inbox 61 s later; the sender still reads acked:"
else bad "5 acked_first=$ttl_acked status=[$OUT] b_new=[$(ls "$LANES/b-default/inbox/new")]"; fi

if [ "$pass" = "$total" ] && [ "$controls" = 3 ]; then
    echo "ok:fleet-msg-same-host:$pass/$total+$controls-controls"
    exit 0
fi
echo "--- mover log ---"; log | tail -40
echo "fail:fleet-msg-same-host:$pass/$total+$controls-controls"
exit 1
