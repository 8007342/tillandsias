#!/usr/bin/env bash
# @trace spec:git-mirror-service, spec:user-runtime-lifecycle, spec:litmus-framework
#
# Detect running containers whose image is OLDER than the image sources in this
# checkout.
#
# WHY THIS EXISTS (order 422)
#
# Three times we have shipped a fix, watched its litmus go green, and then spent
# hours debugging the very defect we had already fixed — because the RUNNING
# container still served a pre-fix image:
#
#   order 301 -> 302   safe reconcile refspec
#   order 369 -> 384   relay auto-reconcile
#   order 414 -> 422   vault token renewer (vault-cli lookup-self was
#                      "unknown subcommand" in the running mirror while the
#                      checkout had defined it for days)
#
# The 414 instance was the expensive one: the mirror's Vault AppRole token has a
# ~1h TTL, the running image had no renewer, so roughly one hour into EVERY forge
# session the mirror silently lost push and reported a misleading "run GitHub
# Login" diagnostic. Agents then misdiagnosed it for hours.
#
# The build engine already tags every image with a content hash of its sources
# (scripts/hash-image-sources.sh). So "is the running container current?" is
# exactly "does the running container's image carry the tag equal to the current
# source hash?" — a deterministic check with no timestamps and no heuristics.
#
# TWO BUILD PATHS, TWO IDENTITY CONVENTIONS (corrected 2026-07-19)
#
# The first version of this gate assumed one convention — that a current image
# always carries a tag equal to hash-image-sources.sh output — and reported
# STALE whenever that tag was absent. That assumption is UNSOUND, and it
# produced a false STALE verdict against the live vault and proxy containers:
#
#   * scripts/build-image.sh tags with the bare source hash, but
#     _remove_stale_image_tags PRUNES tags on later builds, and an explicit
#     --tag bypasses the canonical tag entirely. Tag absence therefore does not
#     imply stale content.
#   * crates/tillandsias-core/src/image_builder.rs builds with an
#     `io.tillandsias.image.source-digest` LABEL and states outright that "the
#     canonical tag and its source-digest label are the durable identity". That
#     digest is computed in Rust over the context tree plus non-filesystem build
#     inputs, and shell cannot reproduce it.
#
# So this gate now reports three states, not two, and only claims STALE when it
# has positive evidence. An image whose identity it cannot evaluate is
# INDETERMINATE and defers to the Rust builder — claiming STALE on ambiguous
# evidence is the same error as claiming PASS on ambiguous evidence, just in the
# safer direction. Either way the gate would be asserting more than it knows.
#
# Exit codes:
#   0  every checked image is current, absent (unless --require-running), or
#      deferred to the authoritative Rust builder
#   1  DRIFT: positive evidence that a running container is older than the
#      checkout
#   2  usage error / missing dependency
#   3  INDETERMINATE with --strict: identity could not be evaluated

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ROOT/scripts"

usage() {
    cat >&2 <<'EOF'
Usage: check-running-image-freshness.sh [--require-running] [image ...]

Compares each running tillandsias container against the content hash of its
image sources in this checkout, and fails loud when they diverge.

  image              image short name (e.g. "git", "vault"). Defaults to every
                     directory under images/ that has a Containerfile.
  --require-running  treat "no container running for this image" as a failure
                     instead of a skip. Use in e2e lanes that have just
                     launched the runtime.
  --strict           treat an INDETERMINATE identity as a failure (exit 3)
                     instead of passing. Use where every image is expected to
                     carry a canonical source-hash tag.

Exit: 0 current, 1 drift, 2 usage error.
EOF
    exit 2
}

REQUIRE_RUNNING=0
STRICT=0
IMAGES=()
while [ $# -gt 0 ]; do
    case "$1" in
        --require-running) REQUIRE_RUNNING=1; shift ;;
        --strict) STRICT=1; shift ;;
        -h|--help) usage ;;
        -*) echo "check-running-image-freshness: unknown flag: $1" >&2; usage ;;
        *) IMAGES+=("$1"); shift ;;
    esac
done

command -v podman >/dev/null 2>&1 || {
    echo "check-running-image-freshness: podman not found" >&2
    exit 2
}
[ -x "$SCRIPT_DIR/hash-image-sources.sh" ] || {
    echo "check-running-image-freshness: missing $SCRIPT_DIR/hash-image-sources.sh" >&2
    exit 2
}

if [ ${#IMAGES[@]} -eq 0 ]; then
    for d in "$ROOT"/images/*/; do
        [ -f "${d}Containerfile" ] || continue
        IMAGES+=("$(basename "$d")")
    done
fi

DRIFTED=0
CHECKED=0
SKIPPED=0
INDETERMINATE=0

for IMAGE in "${IMAGES[@]}"; do
    IMAGE_DIR="$ROOT/images/$IMAGE"
    if [ ! -d "$IMAGE_DIR" ]; then
        echo "check-running-image-freshness: no such image dir: images/$IMAGE" >&2
        exit 2
    fi

    EXPECTED="$("$SCRIPT_DIR/hash-image-sources.sh" "$IMAGE" "$IMAGE_DIR" "$ROOT")" || {
        echo "check-running-image-freshness: failed to hash sources for $IMAGE" >&2
        exit 2
    }

    # Every container whose image repository is this image, regardless of which
    # tag it was started from.
    mapfile -t CONTAINERS < <(
        podman ps --format '{{.Names}}\t{{.Image}}' 2>/dev/null \
            | awk -F'\t' -v img="tillandsias-$IMAGE" '$2 ~ ("(^|/)" img ":") {print $1}'
    )

    if [ ${#CONTAINERS[@]} -eq 0 ]; then
        if [ "$REQUIRE_RUNNING" -eq 1 ]; then
            echo "FAIL: no running container for tillandsias-$IMAGE (--require-running)" >&2
            DRIFTED=1
        else
            SKIPPED=$((SKIPPED + 1))
        fi
        continue
    fi

    for C in "${CONTAINERS[@]}"; do
        CHECKED=$((CHECKED + 1))
        IMAGE_ID="$(podman inspect -f '{{.Image}}' "$C" 2>/dev/null || true)"
        if [ -z "$IMAGE_ID" ]; then
            echo "FAIL: cannot resolve image id for container $C" >&2
            DRIFTED=1
            continue
        fi

        TAGS="$(podman inspect -f '{{range .RepoTags}}{{.}} {{end}}' "$IMAGE_ID" 2>/dev/null || true)"
        SOURCE_DIGEST="$(podman inspect -f '{{index .Labels "io.tillandsias.image.source-digest"}}' "$IMAGE_ID" 2>/dev/null || true)"

        if printf '%s' "$TAGS" | tr ' ' '\n' | grep -qx "localhost/tillandsias-$IMAGE:$EXPECTED"; then
            # Positive evidence of currency: the canonical source-hash tag is
            # present on the exact image this container runs.
            echo "ok: $C runs current tillandsias-$IMAGE (${EXPECTED:0:12})"
        elif [ -n "$SOURCE_DIGEST" ] && [ "$SOURCE_DIGEST" != "<no value>" ]; then
            # Built by the Rust image_builder, whose source-digest is computed
            # over the context tree plus non-filesystem build inputs. Shell
            # cannot recompute it, so this gate must NOT guess. Defer.
            echo "indeterminate: $C carries a source-digest label (${SOURCE_DIGEST:0:19}…);"
            echo "               freshness for this image is owned by tillandsias-core::image_builder."
            INDETERMINATE=$((INDETERMINATE + 1))
        elif printf '%s' "$TAGS" | tr ' ' '\n' | grep -q "tillandsias-$IMAGE:[0-9a-f]\{64\}$"; then
            # It carries SOME canonical source-hash tag, just not the expected
            # one. That is positive evidence of drift.
            RUNNING_TAG="$(printf '%s' "$TAGS" | tr ' ' '\n' | grep "tillandsias-$IMAGE:[0-9a-f]\{64\}$" | head -1)"
            echo "FAIL: $C runs a STALE tillandsias-$IMAGE image" >&2
            echo "      running:  $RUNNING_TAG" >&2
            echo "      expected: localhost/tillandsias-$IMAGE:${EXPECTED}" >&2
            echo "      fix:      ./build-$IMAGE.sh && relaunch the container" >&2
            DRIFTED=1
        else
            # No canonical tag and no label — tags may simply have been pruned
            # by a later build. Absence of evidence is not evidence of drift.
            RUNNING_TAG="$(printf '%s' "$TAGS" | tr ' ' '\n' | grep "tillandsias-$IMAGE:" | head -1 || true)"
            echo "indeterminate: $C carries neither a canonical source-hash tag nor a"
            echo "               source-digest label (running: ${RUNNING_TAG:-<untagged> $IMAGE_ID});"
            echo "               cannot prove current or stale. Rebuild to establish identity."
            INDETERMINATE=$((INDETERMINATE + 1))
        fi
    done
done

if [ "$DRIFTED" -ne 0 ]; then
    echo "FAIL: running image(s) older than the checkout — the fix you are testing may not be deployed" >&2
    exit 1
fi

if [ "$INDETERMINATE" -gt 0 ] && [ "$STRICT" -eq 1 ]; then
    echo "INDETERMINATE (--strict): $INDETERMINATE container(s) could not be evaluated" >&2
    exit 3
fi

echo "PASS: running image freshness (checked $CHECKED container(s), $INDETERMINATE indeterminate, skipped $SKIPPED image(s) with none running)"
exit 0
