#!/bin/bash
set -euo pipefail

# @trace plan/issues/forge-image-creation-vs-firstrun-split-research-2026-07-04.md (order 222)
#
# Selective destructive reset: wipes every tillandsias-OWNED container,
# volume, secret, and image, but explicitly PRESERVES the upstream base
# images pulled from public registries (registry.fedoraproject.org,
# docker.io/library/alpine, docker.io/hashicorp/vault, docker.io/library/caddy).
#
# `podman system reset --force` (the release-acceptance destructive gate) also
# wipes those upstream bases, forcing a full re-pull on every smoke iteration
# even though they rarely change and the thing actually under test is always
# the localhost/tillandsias-* layer. This script is an OPT-IN fast-iteration
# alternative — it does NOT replace `podman system reset --force` as the
# release-acceptance gate. Default smoke-skill behavior is unchanged; this
# script only runs when explicitly invoked (e.g. via
# TILLANDSIAS_SMOKE_RESET_MODE=selective in the smoke skills).
#
# Preservation is an ALLOWLIST, not a denylist: a new upstream base added
# later is wiped by default until explicitly added to KEEP_IMAGE_PATTERNS
# below — failing toward the existing (safe, well-tested) destructive
# behavior rather than silently keeping something new and untested.
#
# Usage: scripts/selective-tillandsias-reset.sh [--dry-run]

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
fi

PODMAN="${TILLANDSIAS_PODMAN_BIN:-podman}"

# Allowlist of upstream base image references to PRESERVE. Matched as exact
# repo:tag strings (not globs) against `podman images` output, so a stale
# entry here simply never matches anything — safe by construction.
KEEP_IMAGE_PATTERNS=(
    "registry.fedoraproject.org/fedora-minimal:44"
    "docker.io/library/alpine:3.20"
    "docker.io/hashicorp/vault:1.18"
    "docker.io/library/caddy:2-alpine"
)

_log() { printf '[selective-reset] %s\n' "$*"; }

_is_kept_image() {
    local ref="$1" keep
    for keep in "${KEEP_IMAGE_PATTERNS[@]}"; do
        [[ "$ref" == "$keep" ]] && return 0
    done
    return 1
}

_log "Stopping and removing all containers..."
CONTAINER_IDS="$("$PODMAN" ps -aq)"
if [[ -n "$CONTAINER_IDS" ]]; then
    if [[ "$DRY_RUN" == true ]]; then
        _log "(dry-run) would remove containers:"
        "$PODMAN" ps -a --format '{{.Names}} ({{.Image}})'
    else
        "$PODMAN" rm -f $CONTAINER_IDS >/dev/null
    fi
else
    _log "no containers to remove"
fi

_log "Removing tillandsias-owned volumes..."
VOLUME_IDS="$("$PODMAN" volume ls -q)"
if [[ -n "$VOLUME_IDS" ]]; then
    if [[ "$DRY_RUN" == true ]]; then
        _log "(dry-run) would remove volumes:"
        "$PODMAN" volume ls --format '{{.Name}}'
    else
        "$PODMAN" volume rm -f $VOLUME_IDS >/dev/null
    fi
else
    _log "no volumes to remove"
fi

_log "Removing tillandsias-owned secrets..."
SECRET_IDS="$("$PODMAN" secret ls -q 2>/dev/null || true)"
if [[ -n "$SECRET_IDS" ]]; then
    if [[ "$DRY_RUN" == true ]]; then
        _log "(dry-run) would remove secrets:"
        "$PODMAN" secret ls --format '{{.Name}}'
    else
        "$PODMAN" secret rm $SECRET_IDS >/dev/null
    fi
else
    _log "no secrets to remove"
fi

_log "Removing tillandsias-owned images (preserving allowlisted upstream bases)..."
# Two passes, keyed on IMAGE ID (not repo:tag): a single image ID can have
# MULTIPLE repo:tag rows (e.g. an allowlisted base pulled both by tag and by
# digest shows a second `<none>:<none>` row for the SAME ID). Classifying
# row-by-row and calling `podman rmi -f <id>` on the "dangling" row would
# delete every tag of that ID — including an allowlisted one. Collecting a
# KEEP_IDS set first, and skipping any ID in it during removal regardless of
# what a LATER row for that same ID looks like, makes this collision
# impossible by construction.
declare -A KEEP_IDS=()
while IFS=$'\t' read -r repo_tag image_id; do
    [[ -z "$image_id" ]] && continue
    if _is_kept_image "$repo_tag"; then
        KEEP_IDS["$image_id"]=1
        _log "keeping upstream base: $repo_tag ($image_id)"
    fi
done < <("$PODMAN" images --format '{{.Repository}}:{{.Tag}}'$'\t''{{.ID}}')

REMOVED=0
KEPT=${#KEEP_IDS[@]}
while IFS=$'\t' read -r repo_tag image_id; do
    [[ -z "$image_id" ]] && continue
    if [[ -n "${KEEP_IDS[$image_id]:-}" ]]; then
        continue
    fi
    # Anything whose ID isn't in KEEP_IDS is removed — tillandsias-*,
    # dangling/<none>:<none>, or an unrecognized reference all fail toward
    # the existing destructive behavior rather than silently keeping
    # something new/untracked.
    if [[ "$DRY_RUN" == true ]]; then
        _log "(dry-run) would remove image: $repo_tag ($image_id)"
    else
        "$PODMAN" rmi -f "$image_id" >/dev/null 2>&1 || true
    fi
    REMOVED=$((REMOVED + 1))
done < <("$PODMAN" images --format '{{.Repository}}:{{.Tag}}'$'\t''{{.ID}}' | awk -F'\t' '!seen[$2]++')

_log "done: $REMOVED image(s) removed, $KEPT upstream base(s) preserved"

if [[ "$DRY_RUN" == false ]]; then
    REMAINING_TILLANDSIAS="$("$PODMAN" images --format '{{.Repository}}' | grep -c '^localhost/tillandsias-' || true)"
    if [[ "$REMAINING_TILLANDSIAS" -ne 0 ]]; then
        _log "ERROR: $REMAINING_TILLANDSIAS tillandsias-* image(s) still present after reset"
        exit 1
    fi
    MISSING_BASES=0
    for keep in "${KEEP_IMAGE_PATTERNS[@]}"; do
        if ! "$PODMAN" image exists "$keep" 2>/dev/null; then
            _log "ERROR: allowlisted base $keep is missing after reset"
            MISSING_BASES=$((MISSING_BASES + 1))
        fi
    done
    if [[ "$MISSING_BASES" -ne 0 ]]; then
        exit 1
    fi
fi
