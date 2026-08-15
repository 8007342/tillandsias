#!/usr/bin/env bash
# @trace spec:git-mirror-service
#
# test-mirror-sshd-posture.sh — order 749-wv4d (design T3, R1 in
# plan/issues/ssh-ca-forge-mirror-push-design-2026-07-31.md §5).
#
# Proves, IN the real images/git container — not argued from the Containerfile —
# that sshd runs under the mirror's actual security posture:
#
#     --read-only --cap-drop=ALL --user 1000, port 2222,
#     writable state ONLY on the /tmp tmpfs and the /srv/git volume
#
# and accepts a TCP connection (an SSH-2.0 banner, read by busybox nc from
# inside the container — no published ports, no relaxed flags).
#
# R1 named this the design's highest-risk rung: every later rung (T4-T13)
# assumes sshd starts at all under that posture. If this fixture cannot pass,
# the whole slice changes shape — do NOT relax --read-only or --cap-drop here;
# that trade belongs to the operator (packet notes, 749-wv4d).
#
# GRAMMAR — exactly one final line per mode:
#   positive -> ok:sshd-under-posture:banner-accepted | fail:sshd-under-posture:<cause>
#   negative -> ok:sshd-negative-control:read-only-blocks-writable-state
#             | fail:sshd-negative-control:<cause>
# Exit 0 on ok, non-zero otherwise.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

MODE="${1:-all}"
IMAGE_TAG="localhost/tillandsias-git:latest"
VOLUME="tillandsias-sshd-posture-test"

cleanup() {
    podman volume rm -f "$VOLUME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

build_image() {
    # The REAL image via the sanctioned builder (source-hash cached, pinned
    # bases, bounded network fetch) — the whole point is the shipped artifact,
    # not a fixture. A raw `podman build` here fails DNS on hosts where build
    # egress is routed for the builder only.
    if ! scripts/build-image.sh git >/tmp/.sshd-posture-build.log 2>&1; then
        echo "fail:sshd-under-posture:image-build-failed (see /tmp/.sshd-posture-build.log)"
        exit 1
    fi
}

# The inner probe runs entirely inside the container: generate a host key on
# the /tmp tmpfs (T4 replaces this with a Vault-signed cert; T3 only proves the
# posture), start sshd as uid 1000 on 2222, and require the SSH-2.0 banner.
# Also asserts the rootfs really is read-only, so the run cannot pass with the
# security flags quietly dropped.
INNER_POSITIVE='set -u
[ "$(id -u)" = "1000" ] || { echo "inner:not-uid-1000"; exit 90; }
if touch /rootfs-write-probe 2>/dev/null; then echo "inner:rootfs-writable"; exit 91; fi
ssh-keygen -q -N "" -t ed25519 -f /tmp/hostkey || { echo "inner:keygen-failed"; exit 92; }
/usr/sbin/sshd -D -e -f /dev/null \
    -o Port=2222 -o ListenAddress=127.0.0.1 \
    -o HostKey=/tmp/hostkey -o PidFile=none \
    2>/tmp/sshd.err &
for _ in $(seq 1 50); do
    banner="$(nc -w 1 127.0.0.1 2222 </dev/null 2>/dev/null | head -c 8)"
    if [ "$banner" = "SSH-2.0-" ]; then echo "inner:banner-ok"; exit 0; fi
    sleep 0.2
done
echo "inner:no-banner"; sed -n "1,10p" /tmp/sshd.err >&2; exit 93'

positive() {
    out="$(podman run --rm \
        --read-only --cap-drop=ALL --user 1000 \
        --tmpfs /tmp:rw,mode=1777 \
        -v "$VOLUME:/srv/git" \
        --entrypoint /bin/bash \
        "$IMAGE_TAG" -c "$INNER_POSITIVE" 2>&1)"
    rc=$?
    if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q 'inner:banner-ok'; then
        echo "ok:sshd-under-posture:banner-accepted"
        return 0
    fi
    printf '%s\n' "$out" | tail -5 >&2
    echo "fail:sshd-under-posture:inner-rc-$rc"
    return 1
}

# NEGATIVE CONTROL (exit criterion 3): with the writable paths removed the
# same probe must FAIL with a NAMED cause (Read-only file system), proving the
# positive run passes because of the declared writable mounts, not vacuously.
#
# Found while writing this control: podman's `--read-only` mounts a tmpfs on
# /tmp and /run BY DEFAULT (`--read-only-tmpfs=true`), so merely omitting the
# explicit `--tmpfs /tmp` removes nothing — keygen succeeded and this control
# passed vacuously. `--read-only-tmpfs=false` is what actually removes the
# writable paths. Design note for T4+: the mirror's /tmp writability comes
# from that podman default, not only from our explicit flag.
INNER_NEGATIVE='err="$(ssh-keygen -q -N "" -t ed25519 -f /tmp/hostkey 2>&1)"
rc=$?
if [ $rc -ne 0 ] && printf "%s" "$err" | grep -qi "read-only file system"; then
    echo "inner:named-cause-ok"; exit 0
fi
echo "inner:unexpected rc=$rc err=$err"; exit 94'

negative() {
    out="$(podman run --rm \
        --read-only --read-only-tmpfs=false --cap-drop=ALL --user 1000 \
        -v "$VOLUME:/srv/git" \
        --entrypoint /bin/bash \
        "$IMAGE_TAG" -c "$INNER_NEGATIVE" 2>&1)"
    rc=$?
    if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q 'inner:named-cause-ok'; then
        echo "ok:sshd-negative-control:read-only-blocks-writable-state"
        return 0
    fi
    printf '%s\n' "$out" | tail -3 >&2
    echo "fail:sshd-negative-control:inner-rc-$rc"
    return 1
}

build_image
case "$MODE" in
    positive) positive ;;
    negative) negative ;;
    all)      positive && negative ;;
    *) echo "usage: $0 [positive|negative|all]" >&2; exit 2 ;;
esac
