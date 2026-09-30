#!/usr/bin/env bash
# @trace order:1310-rec6, spec:git-mirror-service
#
# test-mirror-healthcheck-quiet.sh — the git mirror's HEALTHCHECK must not
# make git-daemon log a fatal line, and must still fail when git is not served.
#
# MEASURED on lenovinha 2026-09-29: 23,209 `fatal: the remote end hung up
# unexpectedly` lines in one tillandsias-git container log, EVERY one directly
# after a `Connection from 127.0.0.1` made by the 2 s `nc -w 1 127.0.0.1 9418`
# healthcheck, NONE from a relay. A healthy mirror's log could not be told from
# a failing one (1310-rec6 step 1: separate noise from failure first).
#
# Runs INSIDE the tillandsias-git image (the only place git-daemon exists on
# these hosts) against a scratch bare repository and a verbose daemon in the
# container's own network namespace. Skips by name without podman or the image.
#
# A probe that CONNECTS always writes to the daemon log, and even a real git
# request leaves the fatal on ~1-3% of runs (measured, v0 and v2). The new
# probe checks the LISTEN socket in /proc/net/tcp and never connects.
#
# Arms (inside the container):
#   1 OLD      (negative control) 5 bare-TCP probes produce 5 hung-up fatals,
#              so the measurement can see the noise at all
#   2 NEW      20 runs of images/git/healthcheck.sh exit 0 and add NO line at
#              all to the daemon log (not even `Connection from`)
#   3 LIVENESS with the daemon stopped the new probe FAILS: still a real check
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${TILLANDSIAS_GIT_IMAGE:-localhost/tillandsias-git:latest}"
command -v podman >/dev/null 2>&1 || { echo "skip:mirror-healthcheck-quiet:no-podman (named skip, not a pass)"; exit 0; }
podman image exists "$IMAGE" 2>/dev/null || { echo "skip:mirror-healthcheck-quiet:no-image:$IMAGE (named skip, not a pass)"; exit 0; }

W="$(mktemp -d "${TMPDIR:-/tmp}/hc-quiet.XXXXXX")"; trap 'rm -rf "$W"' EXIT
cp "$ROOT/images/git/healthcheck.sh" "$W/healthcheck.sh"
cat > "$W/inner.sh" <<'INNER'
#!/bin/sh
set -u
export GIT_SERVICE_ROOT=/tmp/srv
mkdir -p "$GIT_SERVICE_ROOT"
git init -q --bare "$GIT_SERVICE_ROOT/proj"
git -C "$GIT_SERVICE_ROOT/proj" symbolic-ref HEAD refs/heads/main
t=/tmp/t; git init -q -b main "$t"; git -C "$t" -c user.email=f@f -c user.name=f commit -q --allow-empty -m x
git -C "$t" push -q "$GIT_SERVICE_ROOT/proj" main
git daemon --verbose --reuseaddr --export-all --base-path="$GIT_SERVICE_ROOT" \
    --listen=127.0.0.1 --port=9418 2>/tmp/daemon.log &
dpid=$!
# Wait for the LISTEN socket with the socket probe itself: an nc-based wait
# would leave a connection whose disconnect lands, late, in a later window.
i=0; while ! sh /hc/healthcheck.sh; do i=$((i+1)); [ "$i" -gt 50 ] && break; sleep 0.1; done
# Each phase SETTLES before the next is counted: git-daemon logs a probe's
# disconnect asynchronously, and a straggler from one phase must not be
# charged to the next (the first version of this fixture did exactly that).
# Counted by line number, never by truncating the daemon's open log.
sleep 2
fatals() { grep -c 'hung up unexpectedly' /tmp/daemon.log; }
lines() { grep -c . /tmp/daemon.log; }
# NEW first, so no nc connection exists yet to straggle into its window.
l0="$(lines)"
ok=0; for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do sh /hc/healthcheck.sh && ok=$((ok+1)); done
sleep 2; new=$(( $(lines) - l0 ))
f0="$(fatals)"
for n in 1 2 3 4 5; do nc -w 1 127.0.0.1 9418 </dev/null; done
sleep 2; old=$(( $(fatals) - f0 ))
kill "$dpid"; wait "$dpid" 2>/dev/null; sleep 0.5
sh /hc/healthcheck.sh; down=$?
echo "OLD=$old NEW=$new NEW_OK=$ok DOWN_RC=$down"
INNER
chmod +x "$W/inner.sh"
# The image runs as user git: mktemp's 0700 would hide the mount from it.
chmod 0755 "$W"; chmod 0644 "$W/healthcheck.sh"; chmod 0755 "$W/inner.sh"
# --no-healthcheck: the image's own HEALTHCHECK (the old nc probe, every 2 s)
# would otherwise connect during the measurement: the very noise measured.
res="$(podman run --rm --no-healthcheck --network none --entrypoint sh -v "$W:/hc:ro,Z" "$IMAGE" /hc/inner.sh 2>/dev/null | grep '^OLD=')"
FAIL=0
ok()  { printf 'ok:   %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; FAIL=1; }
[ -n "$res" ] || { echo "FAIL: the in-container probe produced no result"; exit 1; }
eval "$res"   # OLD NEW NEW_OK DOWN_RC, integers from the container
[ "$OLD" -ge 5 ] && ok "ARM1 negative control: 5 bare-TCP probes made $OLD hung-up fatals (the old healthcheck's noise is measurable)" \
    || bad "ARM1 the old probe produced $OLD fatals; the measurement cannot see the noise"
[ "$NEW" -eq 0 ] && [ "$NEW_OK" -eq 20 ] && ok "ARM2 20 runs of healthcheck.sh: all exit 0, 0 lines added to the daemon log" \
    || bad "ARM2 new probe: $NEW_OK/20 ok, $NEW daemon log lines"
[ "$DOWN_RC" -ne 0 ] && ok "ARM3 with git-daemon stopped the probe fails (rc=$DOWN_RC): still a liveness check" \
    || bad "ARM3 the probe passed with no daemon running"
[ "$FAIL" -eq 0 ] && { echo "PASS: mirror-healthcheck-quiet (1310-rec6)"; exit 0; }
echo "FAILED: mirror-healthcheck-quiet (1310-rec6)"; exit 1
