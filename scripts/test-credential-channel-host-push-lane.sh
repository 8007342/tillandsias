#!/usr/bin/env bash
# @trace order:1456-ib6i
#
# test-credential-channel-host-push-lane.sh — a host whose §6 host-push lane is
# wired has a working push path even when its keyring is locked, and the
# credential guard must say so instead of telling the worker loop to stop.
# Measured on lenovinha 2026-09-28: keyring re-locked, every push landing through
# the lane, guard answering unknown:secret-service-unprobed and
# check-fleet-membership emitting stop-and-report.
#
# The guard's functions are EXTRACTED from the real
# scripts/check-credential-channel.sh (never the whole script, whose tail runs
# the live probe). credential_channel_verdict is stubbed to a failing or passing
# keyring answer, and _ccc_lane_banner to an sshd banner, because this host has
# no socat or nc to stand up a listener. Arm 5 exercises the REAL banner read
# against a live lane when one is listening, and skips by name otherwise.
#
# Arms:
#   1 LANE        keyring fails, lane wired: ok:host-push-lane:<alias>, rc 0,
#                 and the keyring verdict is still reported on stderr
#   2 NO LANE     keyring fails, lane dir absent: the keyring verdict, rc 1
#                 (NEGATIVE CONTROL: this is the stop the lane must not mask)
#   3 NO SSHD     keyring fails, lane files present, sshd silent: rc 1
#   4 KEYRING OK  keyring passes: its own verdict, the lane never consulted
#   5 FORGE       inside a forge the lane is never consulted
#   6 LIVE        the real _ccc_lane_banner reads SSH-2.0 from a live lane
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/scripts/check-credential-channel.sh"
FAIL=0
ok()  { printf 'ok:   %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; FAIL=1; }
skip(){ printf 'skip: %s\n' "$1"; }

extract() { awk -v n="$1" '$0 ~ "^"n"\\(\\) \\{" { p = 1 } p { print } p && /^}$/ { exit }' "$SRC"; }
for f in _ccc_timeout _ccc_lane_banner _ccc_host_push_lane _ccc_verdict_with_lane forge_upstream_auth_verdict _afford _ccc_relay_state; do
    body="$(extract "$f")"
    [ -n "$body" ] || { echo "FAIL: $f not found in $SRC"; exit 1; }
    eval "$body"
done
real_banner="$(declare -f _ccc_lane_banner)"
real_upstream="$(declare -f forge_upstream_auth_verdict)"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/ccc-lane.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
lane="$scratch/host-push"; mkdir -p "$lane"
printf '@cert-authority git-v0test ssh-ed25519 AAAA\n' >"$lane/known_hosts"
: >"$lane/testhost.ed25519"; : >"$lane/testhost.approle.json"
export TILLANDSIAS_HOST_PUSH_HOST=testhost TILLANDSIAS_HOST_PUSH_DIR="$lane"
unset TILLANDSIAS_HOST_KIND

keyring_fails()  { credential_channel_verdict() { echo "unknown:secret-service-unprobed"; return 1; }; }
keyring_passes() { credential_channel_verdict() { echo "ok:gh-keyring-push-verified"; return 0; }; }
sshd_up()        { _ccc_lane_banner() { printf 'SSH-2.0'; }; }
sshd_silent()    { _ccc_lane_banner() { return 1; }; }
upstream_ok()     { forge_upstream_auth_verdict() { echo "ok:forge-git-mirror"; return 0; }; }
upstream_denied() { forge_upstream_auth_verdict() { echo "blocked:upstream-push-unauthorized"; return 1; }; }
upstream_stale()  { forge_upstream_auth_verdict() { echo "blocked:upstream-auth-stale"; return 1; }; }
# 1310-rec6: the mirror's relay-state, stubbed (the real read is a podman exec).
relay_ok()     { _ccc_relay_state() { echo "ok/none/0"; }; }
relay_broken() { _ccc_relay_state() { echo "broken/credential/1"; }; }
relay_ok

keyring_fails; sshd_up; upstream_ok
out="$(_ccc_verdict_with_lane 2>"$scratch/err")"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "ok:host-push-lane:git-v0test" ] \
   && grep -q 'keyring path: unknown:secret-service-unprobed' "$scratch/err"; then
    ok "ARM1 a wired lane is a push path: $out (keyring verdict kept on stderr)"
else bad "ARM1 rc=$rc out='$out' err='$(cat "$scratch/err")'"; fi

keyring_fails; sshd_up; upstream_ok
out="$(TILLANDSIAS_HOST_PUSH_DIR="$scratch/nowhere" _ccc_verdict_with_lane 2>/dev/null)"; rc=$?
[ "$rc" -eq 1 ] && [ "$out" = "unknown:secret-service-unprobed" ] \
    && ok "ARM2 negative control: no lane, the keyring refusal stands" \
    || bad "ARM2 rc=$rc out='$out'"

keyring_fails; sshd_silent
out="$(_ccc_verdict_with_lane 2>/dev/null)"; rc=$?
[ "$rc" -eq 1 ] && [ "$out" = "unknown:secret-service-unprobed" ] \
    && ok "ARM3 lane files without a listening sshd are not a push path" \
    || bad "ARM3 rc=$rc out='$out'"

keyring_passes; sshd_up
out="$(_ccc_verdict_with_lane 2>/dev/null)"; rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "ok:gh-keyring-push-verified" ] \
    && ok "ARM4 a verified keyring answers for itself" \
    || bad "ARM4 rc=$rc out='$out'"

keyring_fails; sshd_up; upstream_ok
out="$(TILLANDSIAS_HOST_KIND=forge _ccc_verdict_with_lane 2>/dev/null)"; rc=$?
[ "$rc" -eq 1 ] && ok "ARM5 a forge never consults the host lane" || bad "ARM5 rc=$rc out='$out'"

eval "$real_banner"
if b="$(_ccc_lane_banner "${TILLANDSIAS_HOST_PUSH_PORT:-2223}")" && [ -n "$b" ]; then
    [ "$b" = "SSH-2.0" ] && ok "ARM6 the real banner read sees a live lane: $b" || bad "ARM6 live banner='$b'"
else skip "ARM6 no lane listening on 127.0.0.1:${TILLANDSIAS_HOST_PUSH_PORT:-2223} (named skip, not a pass)"; fi

# ARM 7 — NEGATIVE: wired, but upstream REFUSES the credential. This is
# macuahuitl-forge's state on 2026-09-28 (lane fine, Vault token rejected
# upstream, every push failed after a green gate): must refuse, by name.
keyring_fails; sshd_up; upstream_denied
out="$(_ccc_verdict_with_lane 2>/dev/null)"; rc=$?
[ "$rc" -eq 1 ] && [ "$out" = "blocked:upstream-push-unauthorized" ] \
    && ok "ARM7 a wired lane whose upstream refuses is NOT a push path: $out" \
    || bad "ARM7 rc=$rc out='$out'"

# ARM 8 — NEGATIVE: wired, but the upstream verdict is stale.
keyring_fails; sshd_up; upstream_stale
out="$(_ccc_verdict_with_lane 2>/dev/null)"; rc=$?
[ "$rc" -eq 1 ] && [ "$out" = "blocked:upstream-auth-stale" ] \
    && ok "ARM8 a stale upstream verdict refuses, by name: $out" \
    || bad "ARM8 rc=$rc out='$out'"

# ARM 9 — LIVE: the REAL verdict reader against this host's mirror, through
# the podman-exec source. Skipped by name when no mirror container runs here.
eval "$real_upstream"
project="$(basename "$(dirname "$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)")")"
if command -v podman >/dev/null 2>&1 && podman container exists "tillandsias-git-$project" 2>/dev/null; then
    out="$(forge_upstream_auth_verdict "podman-exec:tillandsias-git-$project:/srv/git/$project" 2>/dev/null)"
    case "$out" in
        ok:*|blocked:upstream-*) ok "ARM9 the real reader answers from the live mirror: $out" ;;
        *) bad "ARM9 unexpected live verdict: '$out'" ;;
    esac
else skip "ARM9 no tillandsias-git-$project container on this host (named skip, not a pass)"; fi

# ARM 10 (1310-rec6 step 4, host class): the credential is authorized but the
# mirror is BROKEN (two failing ticks): not a push path, named, with a remedy;
# an ok relay-state restores it with nothing else changed.
keyring_fails; sshd_up; upstream_ok; relay_broken
out="$(_ccc_verdict_with_lane 2>"$scratch/err10")"; rc=$?
relay_ok
out_ok="$(_ccc_verdict_with_lane 2>/dev/null)"; rc_ok=$?
if [ "$rc" -eq 1 ] && [ "$out" = "blocked:mirror-broken:credential" ] && grep -q '  remedy: the operator re-seeds' "$scratch/err10" \
   && [ "$rc_ok" -eq 0 ] && [ "$out_ok" = "ok:host-push-lane:git-v0test" ]; then
    ok "ARM10 a broken mirror is not a push path (blocked:mirror-broken:credential, with remedy); an ok tick restores the lane"
else bad "ARM10 broken rc=$rc out='$out'; restored rc=$rc_ok out='$out_ok'"; fi

[ "$FAIL" -eq 0 ] && { echo "PASS: credential-channel-host-push-lane (1456-ib6i)"; exit 0; }
echo "FAILED: credential-channel-host-push-lane (1456-ib6i)"; exit 1
