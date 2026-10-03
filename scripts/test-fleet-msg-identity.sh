#!/usr/bin/env bash
# @trace order:1506-32k5, openspec/changes/fleet-messaging-poc/design.md (Decision 4)
#
# The fleet message bus's HOST IDENTITY: one X25519 static key per host, its
# public half in a peer directory, and Noise XX pinned to that directory. The
# REAL `tillandsias --msg-serve` binary over loopback, with temp key files
# (the explicit-root seam — no Vault is ever touched), a temp peers directory,
# temp HOME and store root. Five named arms, one per clause of 1506-32k5's
# exit criteria:
#
#   1 handshake   alpha and beta (both minted into the peers dir) complete the
#                 handshake over 127.0.0.1 and exchange the proto frame: the
#                 acceptor prints ok:msg:accept:peer=alpha:fp=<fp_alpha>:proto=1.0,
#                 the dialer ok:msg:dial:peer=beta:fp=<fp_beta>:proto=1.0
#   2 unknown     gamma's key is absent from the directory: the acceptor prints
#                 refused:msg:unknown-peer:<fp_gamma> and envelope_bytes_read=0
#                 (the counting seam); then gamma's record is landed with a
#                 noise_fp that does not hash its noise_pub: the record is
#                 refused (refused:msg:peer-record:gamma:fp-mismatch), the key
#                 is still unknown, and again zero bytes are read
#   3 proto       a hello claiming proto 2.0 (TILLANDSIAS_MSG_PROTO seam) is
#                 refused:msg:proto-major:2 on the acceptor and the dialer
#                 reports the peer's refusal naming it
#   4 mint        --mint again without --rotate is skip:msg:key-exists and the
#                 peer file is byte-identical; --mint --rotate prints a new
#                 fingerprint, rewrites noise_pub/noise_fp, and KEEPS a foreign
#                 field (announce_pub, which 1548-cii8 adds to the same record)
#   5 policy      no shipped Vault policy except tray.hcl grants anything on
#                 secret/data/fleet/msg/* or its metadata (the policy files are
#                 what load_policies writes verbatim); tray.hcl reads it; the
#                 git-mirror policy's grants are exactly the GitHub token pair
# Mutation controls (each re-runs an arm's predicate where the property is
# removed; the arm must then FAIL):
#   NEG-LATE      TILLANDSIAS_MSG_LOOKUP_AFTER_READ=1 moves the directory
#                 lookup after the first envelope read: gamma is still refused
#                 but envelope_bytes_read > 0, so arm 2's predicate FAILS
#   NEG-POLICY    a copy of the policy dir whose forge.hcl gains
#                 path "secret/data/fleet/*" makes arm 5's predicate FAIL,
#                 naming forge.hcl
#
# PRE-FIX RESULT: FAILS — `--mint` is an unknown flag
# (refused:msg-serve:usage:--mint). Point TILLANDSIAS_MSG_SERVE_BIN at a
# pre-1506-32k5 tillandsias to see it.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; total=5; controls=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; }

if ! command -v cargo >/dev/null 2>&1 && [ -z "${TILLANDSIAS_MSG_SERVE_BIN:-}" ]; then
    echo "skip:fleet-msg-identity:no-cargo"
    echo "  why: the arms drive the real binary and there is no cargo to build it" >&2
    echo "  remedy: install cargo, or export TILLANDSIAS_MSG_SERVE_BIN" >&2
    exit 3
fi

T="$(mktemp -d "${TMPDIR:-/tmp}/fleet-msg-identity.XXXXXX")"
APID=""
cleanup() {
    if [ -n "$APID" ]; then kill "$APID" 2>/dev/null; wait "$APID" 2>/dev/null; fi
    rm -rf "$T"
}
trap cleanup EXIT

TARGET="${CARGO_TARGET_DIR:-$ROOT/target}/debug"
if [ -z "${TILLANDSIAS_MSG_SERVE_BIN:-}" ]; then
    echo "[fleet-msg-identity] building tillandsias..." >&2
    if ! (cd "$ROOT" && cargo build -p tillandsias-headless --bin tillandsias) >"$T/build.log" 2>&1; then
        tail -20 "$T/build.log"
        echo "fail:fleet-msg-identity:build"
        echo "  why: the arms need the real binary and the build failed (log above)" >&2
        echo "  remedy: fix the build; if build.rs asks for the router sidecar, run bash scripts/build-sidecar.sh once" >&2
        exit 1
    fi
fi
BIN="${TILLANDSIAS_MSG_SERVE_BIN:-$TARGET/tillandsias}"
if [ ! -x "$BIN" ]; then
    echo "fail:fleet-msg-identity:binary-missing:$BIN"
    exit 1
fi

PEERS="$T/peers"            # the shared directory alpha and beta trust
ELSEWHERE="$T/elsewhere"    # gamma mints here: NOT in $PEERS
mkdir -p "$T/home" "$T/store" "$T/keys" "$PEERS" "$ELSEWHERE"

# as <host> <peers dir> [VAR=value ...] -- <args...>: the real binary as one
# host, hermetic. Every seam needs the explicit TILLANDSIAS_MSG_ROOT set here.
as() {
    local host="$1" peers="$2"; shift 2
    local extra=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do extra+=("$1"); shift; done
    shift
    env -u TILLANDSIAS_MSG_PROTO -u TILLANDSIAS_MSG_LOOKUP_AFTER_READ -u TILLANDSIAS_MSG_PEERS_DIR \
        HOME="$T/home" XDG_STATE_HOME="$T/home/state" \
        TILLANDSIAS_MSG_ROOT="$T/store" TILLANDSIAS_MSG_HOST="$host" \
        TILLANDSIAS_MSG_KEY_FILE="$T/keys/$host.json" TILLANDSIAS_MSG_ACCEPT_TIMEOUT_MS=15000 \
        ${extra[@]+"${extra[@]}"} "$BIN" --msg-serve --peers "$peers" "$@"
}
has() { grep -qF -- "$1" <<<"$2"; }
# fp_of <peer file>: the noise_fp field.
fp_of() { sed -n 's/^noise_fp: *//p' "$1"; }

# session <acceptor> <dialer> <tag> [dialer VAR=value ...]: one accept-once
# and one dial-once over 127.0.0.1. Sets ACC (acceptor stdout), ACC_ERR,
# DIAL (dialer stdout), ACC_RC, DIAL_RC. Acceptor-side seams come from
# ACC_ENV (an array).
session() {
    local acc="$1" dial="$2" tag="$3"; shift 3
    : >"$T/$tag.acc"
    as "$acc" "$PEERS" ${ACC_ENV[@]+"${ACC_ENV[@]}"} -- --accept-once 127.0.0.1:0 \
        >"$T/$tag.acc" 2>"$T/$tag.acc.err" &
    APID=$!
    local addr="" n=150
    while [ "$n" -gt 0 ]; do
        addr="$(sed -n 's/^listening://p' "$T/$tag.acc")"
        [ -n "$addr" ] && break
        kill -0 "$APID" 2>/dev/null || break
        sleep 0.1; n=$((n-1))
    done
    if [ -z "$addr" ]; then
        DIAL="(acceptor never listened)"; DIAL_RC=99
    else
        DIAL="$(as "$dial" "$PEERS" "$@" -- --dial-once "$addr" 2>"$T/$tag.dial.err")"; DIAL_RC=$?
    fi
    wait "$APID"; ACC_RC=$?; APID=""
    ACC="$(cat "$T/$tag.acc")"; ACC_ERR="$(cat "$T/$tag.acc.err")"
}
ACC_ENV=()

# ── mint the three hosts ─────────────────────────────────────────────────────
MA="$(as alpha "$PEERS" -- --mint 2>&1)"; RA=$?
MB="$(as beta "$PEERS" -- --mint 2>&1)"; RB=$?
MG="$(as gamma "$ELSEWHERE" -- --mint 2>&1)"; RG=$?
if [ "$RA$RB$RG" != 000 ] || ! has "ok:msg:minted:alpha:" "$MA"; then
    echo "FAIL: mint — alpha rc=$RA [$MA] beta rc=$RB gamma rc=$RG"
    echo "fail:fleet-msg-identity:0/$total+0-controls"
    exit 1
fi
FA="$(fp_of "$PEERS/alpha.yaml")"; FB="$(fp_of "$PEERS/beta.yaml")"; FG="$(fp_of "$ELSEWHERE/gamma.yaml")"
# The key is in the seam's file, never a Vault: --mint says which store.
if ! has "store:file:$T/keys/alpha.json" "$MA"; then
    echo "FAIL: mint did not report the seam store: [$MA]"
fi

# ── arm 1: two known peers complete and exchange the proto frame ─────────────
session beta alpha a1
if [ "$ACC_RC" = 0 ] && [ "$DIAL_RC" = 0 ] \
   && has "ok:msg:accept:peer=alpha:fp=$FA:proto=1.0" "$ACC" \
   && has "ok:msg:dial:peer=beta:fp=$FB:proto=1.0" "$DIAL"; then
    ok "1 handshake: alpha->beta complete Noise XX pinned to the directory and exchange proto 1.0 (fp $FA / $FB)"
else bad "1 handshake: acc rc=$ACC_RC [$ACC] [$ACC_ERR] dial rc=$DIAL_RC [$DIAL]"; fi

# ── arm 2: an unknown key is refused before any envelope byte is read ────────
# unknown_zero <tag>: the arm's predicate over the last session.
unknown_zero() {
    [ "$ACC_RC" = 1 ] && has "refused:msg:unknown-peer:$FG" "$ACC" && has "envelope_bytes_read=0" "$ACC"
}
session beta gamma a2a
a2a_ok=0; unknown_zero && a2a_ok=1
a2a_acc="$ACC"
cp "$ELSEWHERE/gamma.yaml" "$T/gamma.tampered"
FG_BAD="$(tr '0123456789abcdef' '123456789abcdef0' <<<"$FG")"
sed -i "s/^noise_fp: .*/noise_fp: $FG_BAD/" "$T/gamma.tampered"
cp "$T/gamma.tampered" "$PEERS/gamma.yaml"
session beta gamma a2b
a2b_ok=0; unknown_zero && has "refused:msg:peer-record:gamma:fp-mismatch" "$ACC_ERR" && a2b_ok=1
if [ "$a2a_ok" = 1 ] && [ "$a2b_ok" = 1 ]; then
    ok "2 unknown: gamma (absent, then filed with a noise_fp that does not hash its key) is refused:msg:unknown-peer:$FG with envelope_bytes_read=0"
else bad "2 unknown: absent=[$a2a_acc] tampered=[$ACC] err=[$ACC_ERR]"; fi

# NEG-LATE: the same predicate with the lookup moved after the first read.
ACC_ENV=(TILLANDSIAS_MSG_LOOKUP_AFTER_READ=1)
session beta gamma neglate
ACC_ENV=()
if ! unknown_zero && has "refused:msg:unknown-peer:$FG" "$ACC" && ! has "envelope_bytes_read=0" "$ACC"; then
    echo "ok:   NEG-LATE: with the lookup after the first envelope read gamma is still refused but bytes were read (arm 2 fails)"
    controls=$((controls+1))
else echo "FAIL: NEG-LATE: [$ACC] — the count did not see a late lookup, or the seam did not reach"; fi
rm -f "$PEERS/gamma.yaml"

# ── arm 3: an unknown proto major is refused naming it ───────────────────────
session beta alpha a3 TILLANDSIAS_MSG_PROTO=2.0
if [ "$ACC_RC" = 1 ] && has "refused:msg:proto-major:2" "$ACC" \
   && [ "$DIAL_RC" = 1 ] && has "refused:msg:peer-said:refused:msg:proto-major:2" "$DIAL"; then
    ok "3 proto: a hello claiming 2.0 is refused:msg:proto-major:2 and the dialer reports it"
else bad "3 proto: acc rc=$ACC_RC [$ACC] dial rc=$DIAL_RC [$DIAL]"; fi

# ── arm 4: --mint is idempotent; --rotate rewrites and keeps foreign fields ──
printf 'announce_pub: ed25519-from-1548-cii8\n' >>"$PEERS/alpha.yaml"
before="$(cksum <"$PEERS/alpha.yaml")"
M2="$(as alpha "$PEERS" -- --mint 2>/dev/null)"; R2=$?
after="$(cksum <"$PEERS/alpha.yaml")"
M3="$(as alpha "$PEERS" -- --mint --rotate 2>/dev/null)"; R3=$?
FA2="$(fp_of "$PEERS/alpha.yaml")"
if [ "$R2" = 0 ] && has "skip:msg:key-exists:alpha:$FA" "$M2" && [ "$before" = "$after" ] \
   && [ "$R3" = 0 ] && has "ok:msg:rotated:alpha:$FA->$FA2" "$M3" && [ -n "$FA2" ] && [ "$FA2" != "$FA" ] \
   && grep -qx 'announce_pub: ed25519-from-1548-cii8' "$PEERS/alpha.yaml"; then
    ok "4 mint: a second --mint is skip:msg:key-exists (file unchanged); --rotate rewrites $FA -> $FA2 and keeps announce_pub"
else bad "4 mint: second rc=$R2 [$M2] unchanged=$([ "$before" = "$after" ] && echo y || echo n) rotate rc=$R3 [$M3] fp=$FA2"; fi

# ── arm 5: no policy but the host resident's reaches secret/data/fleet/msg/ ──
# stanzas <file>: one "<pattern> <caps>" line per path stanza, comments cut.
stanzas() {
    awk '{ sub(/#.*/, "") }
         /path[ \t]+"/ { match($0, /"[^"]*"/); pat = substr($0, RSTART+1, RLENGTH-2); caps = "" ; inside = 1 }
         inside && /capabilities/ { c = $0; sub(/.*\[/, "", c); sub(/\].*/, "", c); gsub(/[" \t]/, "", c); caps = c }
         inside && /}/ { print pat, caps; inside = 0 }' "$1"
}
# grants <pattern> <path>: does a Vault path pattern (trailing * = prefix,
# + = one segment) match the path?
grants() {
    local re="$1" glob=0
    case "$re" in *'*') glob=1; re="${re%\*}" ;; esac
    re="${re//./\\.}"; re="${re//+/[^/]+}"
    if [ "$glob" = 1 ]; then re="^${re}.*\$"; else re="^${re}\$"; fi
    [[ "$2" =~ $re ]]
}
# audit <policy dir>: prints one violation per line; empty = clean.
audit() {
    local f name pat caps probe saw_tray_read=0 mirror=""
    for f in "$1"/*.hcl; do
        name="${f##*/}"
        while read -r pat caps; do
            [ -z "$pat" ] && continue
            if [ "$name" = tray.hcl ]; then
                if grants "$pat" secret/data/fleet/msg/static && has read "$caps"; then saw_tray_read=1; fi
                continue
            fi
            [ "$name" = git-mirror.hcl ] && mirror="$mirror$pat:$caps;"
            [ "$caps" = deny ] && continue
            for probe in secret/data/fleet/msg/static secret/data/fleet/msg/x secret/metadata/fleet/msg/static; do
                if grants "$pat" "$probe"; then echo "$name grants [$caps] on $probe via \"$pat\""; fi
            done
        done < <(stanzas "$f")
    done
    [ "$saw_tray_read" = 1 ] || echo "tray.hcl (host resident) cannot read secret/data/fleet/msg/static"
    [ "$mirror" = "secret/data/github/token:read;secret/metadata/github/token:read;" ] \
        || echo "git-mirror.hcl grants changed: $mirror"
}
POL="$ROOT/images/vault/policies"
nfiles=0; for f in "$POL"/*.hcl; do nfiles=$((nfiles+1)); done
# Premise: the matcher matches what Vault would, both ways.
premise=1
grants 'secret/*' secret/data/fleet/msg/static || premise=0
grants 'secret/+/fleet/msg/*' secret/metadata/fleet/msg/static || premise=0
grants 'secret/data/fleet*' secret/data/fleet/msg/static || premise=0
grants 'secret/data/github/token' secret/data/fleet/msg/static && premise=0
V="$(audit "$POL")"
if [ "$premise" = 1 ] && [ "$nfiles" -ge 12 ] && [ -z "$V" ]; then
    ok "5 policy: none of $nfiles shipped policies but tray.hcl grants anything under secret/data/fleet/msg/; git-mirror grants unchanged"
else bad "5 policy: premise=$premise files=$nfiles violations=[$V]"; fi

# NEG-POLICY: a fleet-wide read added to a copy of forge.hcl must be named.
mkdir -p "$T/pol"; cp "$POL"/*.hcl "$T/pol/"
printf '\npath "secret/data/fleet/*" {\n  capabilities = ["read"]\n}\n' >>"$T/pol/forge.hcl"
VN="$(audit "$T/pol")"
if [ -n "$VN" ] && has 'forge.hcl grants [read] on secret/data/fleet/msg/static' "$VN"; then
    echo "ok:   NEG-POLICY: a forge.hcl granting secret/data/fleet/* is named (arm 5 fails)"
    controls=$((controls+1))
else echo "FAIL: NEG-POLICY: the mutated forge.hcl was not caught: [$VN]"; fi

if [ "$pass" = "$total" ] && [ "$controls" = 2 ]; then
    echo "ok:fleet-msg-identity:$pass/$total+$controls-controls"
    exit 0
fi
echo "fail:fleet-msg-identity:$pass/$total+$controls-controls"
exit 1
