#!/usr/bin/env bash
# @trace order:1073-dqtx
#
# Pin: an image that EXISTS but whose overlay layer is gone must be REFUSED,
# and an intact image must still pass.
#
# BOTH DIRECTIONS, because "refuses a broken image" is trivially satisfied by
# refusing every image, and that would break every build in the fleet. Arm 2 is
# the control and it is the load-bearing one.
#
# THE BROKEN STATE IS CONSTRUCTED, because the original could not be kept. It
# was observed once on tlatoanis-macbook-air 2026-09-05 and the --no-cache
# rebuild that cleared it DESTROYED THE EVIDENCE, so the packet asked for a
# synthetic reproduction. This is it: build an image, then remove the overlay
# directory its RootFS references.
#
# HERMETIC BY CONSTRUCTION, and that is not a nicety. The manipulation deletes
# a directory out of container storage, so it runs against an isolated
# `--root`/`--runroot` under mktemp and never touches the host's real store —
# which on a developer workstation holds the toolbox the fleet compiles in.
# `FROM scratch` plus a COPY needs no registry, so the fixture works offline
# and on a host with no images pulled.
#
# WHY `podman unshare` FOR THE REMOVAL: rootless overlay content is owned by a
# subuid, so a plain `rm -rf` fails with EPERM partway through and leaves the
# layer PARTIALLY present. Measured: against that partial state `image inspect`
# still returns 0 and only `run` fails — so a fixture that skipped `unshare`
# would construct a different, weaker defect and then "prove" the check misses
# it. The removal has to be complete for the arm to mean what it says.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY="$ROOT/scripts/verify-image-usable.sh"
PODMAN="${TILLANDSIAS_PODMAN:-podman}"

pass=0; fail=0
ok()  { printf 'ok:   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$1" >&2; fail=$((fail + 1)); }

command -v "$PODMAN" >/dev/null 2>&1 || { echo "SKIP: no podman on this host"; exit 0; }
[ -x "$VERIFY" ] || { echo "FAIL: $VERIFY missing or not executable" >&2; exit 1; }

W="$(mktemp -d "${TMPDIR:-/tmp}/image-usability.XXXXXX")"
cleanup() { "$PODMAN" unshare rm -rf "$W" 2>/dev/null || true; rm -rf "$W" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

STORE=(--root "$W/root" --runroot "$W/run")
mkdir -p "$W/ctx"
echo hello > "$W/ctx/f.txt"
printf 'FROM scratch\nCOPY f.txt /\n' > "$W/ctx/Containerfile"

"$PODMAN" "${STORE[@]}" build -q -t probe:latest "$W/ctx" >/dev/null 2>&1
build_rc=$?
if [ "$build_rc" -ne 0 ]; then
    # A host that cannot build into a scratch store cannot run this fixture.
    # Skip with the reason named rather than fail (1024-c3h3).
    echo "SKIP: cannot build into an isolated store (rc=$build_rc)"
    exit 0
fi

export TILLANDSIAS_PODMAN_ARGS="--root $W/root --runroot $W/run"

# ── ARM 1: an INTACT image passes ─────────────────────────────────────────
# First, because every later arm is meaningless if the check refuses a good
# image — and because a check that refuses everything would score arm 3.
out1="$(bash "$VERIFY" probe:latest 2>/dev/null)"; rc1=$?
case "$out1" in
    ok:image-usable:probe:latest) ok "an intact image passes" ;;
    *) bad "an intact image was not accepted: rc=$rc1 out=$out1" ;;
esac
[ "$rc1" -eq 0 ] && ok "an intact image exits 0" || bad "intact image exit $rc1, want 0"

# ── ARM 2: the signals that LIE still lie (the packet's premise) ──────────
# If `image exists` started failing on the broken state, the defect would have
# fixed itself and this whole packet would be moot. Pinning the premise keeps
# the fixture honest about WHY a usability check is needed.
layer="$("$PODMAN" "${STORE[@]}" image inspect probe:latest \
    --format '{{range .RootFS.Layers}}{{println .}}{{end}}' 2>/dev/null | head -1)"
layer="${layer#sha256:}"
if [ -z "$layer" ] || [ ! -d "$W/root/overlay/$layer" ]; then
    echo "SKIP: cannot locate the image's overlay directory to break"
    exit 0
fi
"$PODMAN" unshare rm -rf "$W/root/overlay/$layer" 2>/dev/null
if [ -d "$W/root/overlay/$layer" ]; then
    echo "SKIP: could not fully remove the layer dir; a partial removal is a"
    echo "      DIFFERENT defect and would make arm 3 assert the wrong thing"
    exit 0
fi

"$PODMAN" "${STORE[@]}" image exists probe:latest 2>/dev/null
exists_rc=$?
[ "$exists_rc" -eq 0 ] \
    && ok "PREMISE: 'image exists' still reports 0 over the broken image" \
    || bad "'image exists' now catches it (rc=$exists_rc) — re-read the packet, the premise moved"

"$PODMAN" "${STORE[@]}" image tree probe:latest >/dev/null 2>&1
tree_rc=$?
[ "$tree_rc" -eq 0 ] \
    && ok "PREMISE: 'image tree' still reports 0 over the broken image" \
    || bad "'image tree' now catches it (rc=$tree_rc)"

# ── ARM 3: the check REFUSES the broken image ────────────────────────────
out3="$(bash "$VERIFY" probe:latest 2>/dev/null)"; rc3=$?
case "$out3" in
    violation:image-not-usable:probe:latest:*) ok "a broken image is refused with a named verdict" ;;
    *) bad "the broken image was not refused: rc=$rc3 out=$out3" ;;
esac
[ "$rc3" -eq 1 ] && ok "a broken image exits 1" || bad "broken image exit $rc3, want 1"

# ── ARM 4: the refusal NAMES the remedy ──────────────────────────────────
# Criterion 2: an operator must not be left reading a faccessat error against a
# build that claimed to work.
err4="$(bash "$VERIFY" probe:latest 2>&1 >/dev/null)"
case "$err4" in
    *TILLANDSIAS_BUILD_NO_CACHE=1*) ok "the refusal names the --no-cache remedy" ;;
    *) bad "the refusal does not name the remedy: $err4" ;;
esac

printf 'image-usability-check: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
printf 'ok:image-usability-check:%d\n' "$pass"
