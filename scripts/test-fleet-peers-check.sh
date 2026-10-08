#!/usr/bin/env bash
# @trace order:1548-cii8, openspec/changes/fleet-wan-rendezvous/design.md (Decision 6)
#
# `tillandsias fleet peers check`: the REAL binary over temp peers
# directories. Good records are written by the real `--msg-serve --mint`
# (1506-32k5, temp key files, no Vault) and then completed with the fields
# 1548-cii8 adds, so the check runs over the one shared record, not a
# parallel fixture format. Arms:
#
#   1 good      one complete record passes: rc 0, ok:fleet-peers:1-records
#   2 four      a directory holding one good record and four bad ones (missing
#               ssh_host_ca_pub, host Yoga_Laptop, a noise_fp that does not
#               hash its noise_pub, an email in a field) exits 1 with EXACTLY
#               four named refusals, one per bad record, each followed by a
#               why: and a remedy: line; the good record is not named
#   3 more      a duplicate noise_pub, a record filed under another host's
#               name, a malformed owner.yaml and an EMPTY directory are each
#               refused by name (an empty directory must not pass)
#   4 foreign   a good record that also carries minted/lan_hints/mesh_ip
#               passes: the check does not reject fields it does not own
# Mutation control (re-runs arm 2's fp predicate where the property is
# removed; the arm's predicate must then FAIL):
#   NEG-LAX     TILLANDSIAS_FLEET_PEERS_LAX=1 skips the noise_fp check, so the
#               bad-fp record is no longer refused and arm 2's predicate FAILS.
#               The seam is compiled only under cfg(debug_assertions), so this
#               also proves the fixture drives the DEBUG build.
#
# PRE-FIX RESULT: FAILS — there is no `fleet` verb (the binary treats `fleet`
# as a project path), so arm 1 never prints ok:fleet-peers:1-records.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; total=4; controls=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; }

if ! command -v cargo >/dev/null 2>&1 && [ -z "${TILLANDSIAS_MSG_SERVE_BIN:-}" ]; then
    echo "skip:fleet-peers-check:no-cargo"
    echo "  why: the arms drive the real binary and there is no cargo to build it" >&2
    echo "  remedy: install cargo, or export TILLANDSIAS_MSG_SERVE_BIN" >&2
    exit 3
fi

T="$(mktemp -d "${TMPDIR:-/tmp}/fleet-peers-check.XXXXXX")"
trap 'rm -rf "$T"' EXIT

TARGET="${CARGO_TARGET_DIR:-$ROOT/target}/debug"
if [ -z "${TILLANDSIAS_MSG_SERVE_BIN:-}" ]; then
    echo "[fleet-peers-check] building tillandsias..." >&2
    if ! (cd "$ROOT" && cargo build -p tillandsias-headless --bin tillandsias) >"$T/build.log" 2>&1; then
        tail -20 "$T/build.log"
        echo "fail:fleet-peers-check:build"
        echo "  why: the arms need the real binary and the build failed (log above)" >&2
        echo "  remedy: fix the build; if build.rs asks for the router sidecar, run bash scripts/build-sidecar.sh once" >&2
        exit 1
    fi
fi
BIN="${TILLANDSIAS_MSG_SERVE_BIN:-$TARGET/tillandsias}"
if [ ! -x "$BIN" ]; then
    echo "fail:fleet-peers-check:binary-missing:$BIN"
    exit 1
fi
mkdir -p "$T/home" "$T/store" "$T/keys"

# mint <peers dir> <host>: a real --mint into <peers dir>/<host>.yaml.
mint() {
    env -u TILLANDSIAS_MSG_PEERS_DIR HOME="$T/home" XDG_STATE_HOME="$T/home/state" \
        TILLANDSIAS_MSG_ROOT="$T/store" TILLANDSIAS_MSG_HOST="$2" \
        TILLANDSIAS_MSG_KEY_FILE="$T/keys/$2.json" \
        "$BIN" --msg-serve --peers "$1" --mint >/dev/null 2>"$T/mint.err" \
        || { echo "fail:fleet-peers-check:mint:$2"; cat "$T/mint.err"; exit 1; }
}

CA_HOST='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGhvc3Q='
CA_USER='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHVzZXI='
# complete <file> [skip-field]: append the 1548-cii8 fields the mint does not
# write. A 64-hex announce_pub is derived from the file's own noise_pub with a
# different leading byte; it is only shape-checked.
complete() {
    local f="$1" skip="${2:-}" pub
    pub="$(sed -n 's/^noise_pub: *//p' "$f")"
    {
        echo "announce_pub: ff${pub:2}"
        [ "$skip" = ssh_host_ca_pub ] || echo "ssh_host_ca_pub: $CA_HOST"
        echo "ssh_user_ca_pub: $CA_USER"
        echo "class_declared: laptop"
        echo "substrate: podman"
        echo "admitted:"
        echo "  date: 2026-10-03"
        echo "  by: cloudflare-login"
    } >>"$f"
}

# check <peers dir> [VAR=value ...]: sets OUT (stdout), ERR (stderr), RC.
check() {
    local d="$1"; shift
    env -u TILLANDSIAS_MSG_PEERS_DIR -u TILLANDSIAS_FLEET_PEERS_LAX HOME="$T/home" \
        ${@+"$@"} "$BIN" fleet peers check --peers "$d" >"$T/out" 2>"$T/err"
    RC=$?
    OUT="$(cat "$T/out")"; ERR="$(cat "$T/err")"
}
has() { grep -qF -- "$1" <<<"$2"; }
# nverdicts: the number of per-record refusal lines on ERR (the summary line
# ends in -refusals and is not one).
nverdicts() { grep -E '^refused:fleet-peers:' <<<"$ERR" | grep -vc -- '-refusals$'; }
# affordance_ok <verdict prefix>: the verdict is followed by why: and remedy:.
affordance_ok() { grep -A2 -F -- "$1" <<<"$ERR" | grep -q '^  why: ' \
    && grep -A2 -F -- "$1" <<<"$ERR" | grep -q '^  remedy: '; }

# ---- arm 1: one good record passes -----------------------------------------
D1="$T/a1"; mkdir -p "$D1"
mint "$D1" alpha; complete "$D1/alpha.yaml"
check "$D1"
if [ "$RC" = 0 ] && [ "$OUT" = "ok:fleet-peers:1-records" ] && [ -z "$ERR" ]; then
    ok "good — one complete record passes"
else
    bad "good — rc=$RC out=[$OUT] err=[$ERR]"
fi

# ---- arm 2: four bad records, exactly four named refusals -------------------
D2="$T/a2"; mkdir -p "$D2"
mint "$D2" alpha;  complete "$D2/alpha.yaml"
mint "$D2" nocaa;  complete "$D2/nocaa.yaml" ssh_host_ca_pub
mint "$D2" yoga-laptop; complete "$D2/yoga-laptop.yaml"
sed -i 's/^host: yoga-laptop$/host: Yoga_Laptop/' "$D2/yoga-laptop.yaml"
mint "$D2" badfp;  complete "$D2/badfp.yaml"
sed -i 's/^noise_fp: .*/noise_fp: 00000000000000000000000000000000/' "$D2/badfp.yaml"
mint "$D2" mailed; complete "$D2/mailed.yaml"
sed -i "s|^ssh_user_ca_pub: .*|ssh_user_ca_pub: $CA_USER bob@example.com|" "$D2/mailed.yaml"
check "$D2"
a2=1
[ "$RC" = 1 ] || { a2=0; echo "  rc=$RC, want 1"; }
[ "$(nverdicts)" = 4 ] || { a2=0; echo "  $(nverdicts) refusals, want exactly 4"; }
for v in 'refused:fleet-peers:nocaa:missing-field:ssh_host_ca_pub' \
         'refused:fleet-peers:yoga-laptop:non-canonical-host:Yoga_Laptop' \
         'refused:fleet-peers:badfp:noise-fp-mismatch' \
         'refused:fleet-peers:mailed:email-in-field:ssh_user_ca_pub'; do
    if ! has "$v" "$ERR"; then a2=0; echo "  missing: $v"; fi
    if ! affordance_ok "$v"; then a2=0; echo "  no why:/remedy: after $v"; fi
done
if has 'fleet-peers:alpha:' "$ERR"; then a2=0; echo "  the good record alpha was named"; fi
if [ "$a2" = 1 ]; then ok "four — four bad records, exactly four named refusals with why/remedy"
else bad "four — $ERR"; fi

# ---- arm 3: duplicate key, wrong file name, malformed owner, empty dir ------
a3=1
D3="$T/a3/peers"; mkdir -p "$D3"
mint "$D3" alpha; complete "$D3/alpha.yaml"
cp "$D3/alpha.yaml" "$D3/beta.yaml"; sed -i 's/^host: alpha$/host: beta/' "$D3/beta.yaml"
mint "$D3" gamma; complete "$D3/gamma.yaml"
cp "$D3/gamma.yaml" "$D3/delta.yaml"      # host: gamma filed as delta
check "$D3"
has 'refused:fleet-peers:beta:duplicate-noise-pub-of:alpha' "$ERR" || { a3=0; echo "  no duplicate-noise-pub-of"; }
has 'refused:fleet-peers:delta:host-is-not-file-name:gamma' "$ERR" || { a3=0; echo "  no host-is-not-file-name"; }
[ "$RC" = 1 ] || { a3=0; echo "  rc=$RC, want 1"; }
printf 'github_user_id: not-a-number\ncloudflare_user_sha256: abc\nsalt: 00\n' >"$T/a3/owner.yaml"
rm -f "$D3/beta.yaml" "$D3/delta.yaml"
check "$D3"
has 'refused:fleet-peers:owner:malformed-field:github_user_id' "$ERR" || { a3=0; echo "  no owner github_user_id refusal"; }
has 'refused:fleet-peers:owner:malformed-field:cloudflare_user_sha256' "$ERR" || { a3=0; echo "  no owner sha refusal"; }
printf 'github_user_id: 12345\ncloudflare_user_sha256: %s\nsalt: 0011223344556677\n' "$(printf 'ab%.0s' $(seq 32))" >"$T/a3/owner.yaml"
check "$D3"
[ "$RC" = 0 ] || { a3=0; echo "  a good owner.yaml was refused: $ERR"; }
D3E="$T/a3e"; mkdir -p "$D3E"
check "$D3E"
if [ "$RC" = 1 ] && has 'refused:fleet-peers:-:no-records' "$ERR" && affordance_ok 'no-records'; then :
else a3=0; echo "  an empty directory rc=$RC err=[$ERR]"; fi
if [ "$a3" = 1 ]; then ok "more — duplicate key, wrong file name, bad owner, empty dir each refused by name"
else bad "more"; fi

# ---- arm 4: foreign fields are kept, not rejected ---------------------------
D4="$T/a4"; mkdir -p "$D4"
mint "$D4" alpha; complete "$D4/alpha.yaml"
printf 'lan_hints: [192.168.1.5:48620]\nmesh_ip: 100.64.0.7\nsomething_new: 1\n' >>"$D4/alpha.yaml"
check "$D4"
if [ "$RC" = 0 ] && [ "$OUT" = "ok:fleet-peers:1-records" ]; then ok "foreign — optional and unknown fields do not refuse"
else bad "foreign — rc=$RC err=[$ERR]"; fi

# ---- control NEG-LAX: skipping the fp check turns arm 2's fp predicate red --
check "$D2" TILLANDSIAS_FLEET_PEERS_LAX=1
if has 'refused:fleet-peers:badfp:noise-fp-mismatch' "$ERR"; then
    bad "NEG-LAX — the fp refusal survived the LAX seam (is this a release binary?)"
elif [ "$(nverdicts)" = 3 ]; then
    echo "ok:   NEG-LAX — with the fp check skipped arm 2 predicate fails (3 refusals, no noise-fp-mismatch)"
    controls=$((controls+1))
else
    bad "NEG-LAX — expected exactly 3 refusals without the fp one, got $(nverdicts)"
fi

if [ "$pass" = "$total" ] && [ "$controls" = 1 ]; then
    echo "ok:fleet-peers-check:$pass/$total+$controls-controls"
    exit 0
fi
echo "fail:fleet-peers-check:$pass/$total+$controls-controls"
exit 1
