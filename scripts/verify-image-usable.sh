#!/usr/bin/env bash
# @trace order:1073-dqtx
#
# verify-image-usable.sh <image-tag> — an image EXISTS is not an image WORKS.
#
# THE DEFECT. On tlatoanis-macbook-air 2026-09-05 a forge build produced three
# independent green signals over an artifact that could not start:
#
#   scripts/build-image.sh forge      -> exit 0, 121s
#   podman image exists <tag>         -> exit 0
#   podman images                     -> the tag, 3.03 GB
#   podman inspect <tag>              -> EXIT 125, faccessat
#                                        .../overlay/1854a58890…: no such file
#   podman run <tag>                  -> same, container never started
#
# A build verdict, an existence check and a plausible size all agreed. Anything
# downstream gating on build success, on `image exists`, or on a size in
# `podman images` proceeds against an image that cannot run.
#
# REPRODUCED HERMETICALLY on yoga 2026-09-06 (isolated --root, `FROM scratch`
# plus a COPY, then the image's own overlay directory removed through
# `podman unshare`). That gives the discriminating table:
#
#   signal              intact   layer dir removed
#   image exists          0            0     <- fooled
#   images (size)       shows        shows   <- fooled
#   image tree            0            0     <- fooled
#   image inspect         0          125     <- CATCHES IT
#   run                   0          125     <- catches it, costs a container
#
# `image inspect` is the cheapest signal that actually touches the layers, so
# that is the one used. `image tree` reads metadata and is fooled, which is
# worth knowing because it LOOKS like the layer-aware choice.
#
# ONE IMPLEMENTATION ON PURPOSE. build-image.sh calls this, the fixture tests
# this, and any other caller that needs a usability assertion should call it
# rather than re-deriving one — two readers of the same question drifting apart
# is the shape 1081-gynk exists for.
#
# Grammar (one line on stdout):
#   ok:image-usable:<tag>
#   violation:image-not-usable:<tag>:inspect-rc=<n>
#   skip:image-usable:<reason>
set -uo pipefail

PODMAN="${TILLANDSIAS_PODMAN:-podman}"
TAG="${1:-}"
if [ -z "$TAG" ]; then
    echo "usage: verify-image-usable.sh <image-tag>" >&2
    exit 2
fi
command -v "$PODMAN" >/dev/null 2>&1 || {
    # A host without podman cannot answer, and must not answer "clean"
    # (1024-c3h3). Skip with the reason named.
    echo "skip:image-usable:no-podman-on-this-host"
    exit 0
}

# Extra args (e.g. --root/--runroot for a hermetic test store) come through
# TILLANDSIAS_PODMAN_ARGS as a pre-split string; unquoted on purpose.
# shellcheck disable=SC2086
err="$("$PODMAN" ${TILLANDSIAS_PODMAN_ARGS:-} image inspect "$TAG" 2>&1 >/dev/null)"
rc=$?

if [ "$rc" -ne 0 ]; then
    echo "violation:image-not-usable:${TAG}:inspect-rc=${rc}"
    {
        echo "  The image EXISTS and cannot be inspected — it is not runnable."
        echo "  podman image inspect exit ${rc}:"
        printf '%s\n' "$err" | sed 's/^/    /'
        echo "  'podman image exists', a size in 'podman images' and 'image tree'"
        echo "  can all agree while a referenced overlay layer is missing from"
        echo "  storage (1073-dqtx). They read metadata; only inspect and run"
        echo "  touch the layers."
        echo "  REMEDY: rebuild without layer reuse —"
        echo "    TILLANDSIAS_BUILD_NO_CACHE=1 scripts/build-image.sh <name> --force"
    } >&2
    exit 1
fi

echo "ok:image-usable:${TAG}"
