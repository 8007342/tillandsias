#!/usr/bin/env bash
# @trace gap:TR-006
#
# Manage Tillandsias cache and disk usage.
#
# This script monitors disk usage and automatically evicts old cached images
# when disk usage exceeds 85%. Preserves images from the last 30 days.
#
# Invoked from: tillandsias-headless startup via run_disk_usage_check()
# See: crates/tillandsias-headless/src/main.rs
#
# Exit codes:
#   0 — success (disk OK or cleanup completed)
#   1 — error (e.g., cannot determine disk usage)

set -euo pipefail

# Defaults
DISK_THRESHOLD_PERCENT=85
CACHE_RETENTION_DAYS=30
PODMAN_STORAGE="${PODMAN_STORAGE:-${XDG_DATA_HOME:-$HOME/.local/share}/containers/storage}"
DEBUG="${DEBUG:-0}"

# Logging helper
log_info() {
    echo "[tillandsias-cache] $1"
}

log_error() {
    echo "[tillandsias-cache] ERROR: $1" >&2
}

log_debug() {
    if [[ "$DEBUG" == "1" ]]; then
        echo "[tillandsias-cache] DEBUG: $1" >&2
    fi
}

# @trace spec:disk-usage-detection
#
# Get the filesystem mounted at the podman storage root.
# Returns the mount point (e.g., "/home" or "/").
get_storage_mount() {
    local storage="$1"

    # Find the mount point by walking up the path
    while [[ "$storage" != "/" ]]; do
        if mountpoint -q "$storage" 2>/dev/null; then
            echo "$storage"
            return 0
        fi
        storage=$(dirname "$storage")
    done

    echo "/"
    return 0
}

# @trace spec:disk-usage-detection
#
# Check current disk usage for the filesystem containing podman storage.
# Returns percentage used (e.g., "73" for 73%).
# Returns 1 if determination fails.
get_disk_usage_percent() {
    local storage="$1"
    local mount

    mount=$(get_storage_mount "$storage")
    log_debug "Podman storage '$storage' is on mount '$mount'"

    # Use df to get usage percentage; suppress errors on missing/unmountable dirs
    if ! df_output=$(df "$mount" 2>/dev/null); then
        log_error "Cannot determine disk usage for $mount"
        return 1
    fi

    # Parse percentage from df output (second line, last field before '%')
    # Example: /dev/sda1 5242880 3932160 1310720  75% /home
    local percent
    percent=$(echo "$df_output" | tail -1 | awk '{print $5}' | sed 's/%//')

    if [[ ! "$percent" =~ ^[0-9]+$ ]]; then
        log_error "Failed to parse disk usage from df output: $df_output"
        return 1
    fi

    echo "$percent"
    return 0
}

# @trace spec:podman-image-eviction
#
# Get a list of all cached Tillandsias images sorted by creation time (oldest first).
# Format: "image_id creation_timestamp"
get_old_images() {
    local cutoff_timestamp

    # Calculate cutoff: retention_days ago
    cutoff_timestamp=$(date -d "$CACHE_RETENTION_DAYS days ago" +%s 2>/dev/null || date -v-${CACHE_RETENTION_DAYS}d +%s)
    log_debug "Images older than $(date -d @$cutoff_timestamp 2>/dev/null || date -r $cutoff_timestamp) will be candidates for removal"

    # List all podman images in JSON format, filter by creation time and name prefix
    # Use `podman images --format=json` if available, otherwise fall back to --format
    local images_json

    if ! images_json=$(podman images --format=json 2>/dev/null); then
        log_debug "podman images --format=json failed, trying legacy format"
        return 1
    fi

    # Parse JSON to find tillandsias-* images older than cutoff
    # Expects: [{"ID":"sha256:...", "Names":["tillandsias-forge:..."], "Created":"2026-05-14T..."}]
    echo "$images_json" | jq -r '.[] |
        select(.Names[]? | startswith("tillandsias-")) |
        [.ID, .Created] | @tsv' 2>/dev/null | while read -r image_id created_str; do

        # Parse ISO8601 timestamp to epoch seconds
        created_epoch=$(date -d "$created_str" +%s 2>/dev/null || date -jf "%Y-%m-%dT%H:%M:%S" "$created_str" +%s 2>/dev/null || echo 0)

        if [[ "$created_epoch" -lt "$cutoff_timestamp" ]]; then
            echo "$image_id $created_epoch"
        fi
    done | sort -k2 -n
}

# @trace spec:podman-image-eviction
#
# Delete an image by ID. Returns 0 on success, 1 on error.
# Logs the action and any error.
delete_image() {
    local image_id="$1"

    log_debug "Deleting image: $image_id"

    if ! podman rmi "$image_id" 2>/dev/null; then
        log_debug "Failed to delete image $image_id (may be in use)"
        return 1
    fi

    return 0
}

# @trace spec:podman-image-eviction, spec:disk-usage-detection
#
# Evict old cached images when disk usage exceeds threshold.
# Deletes oldest images first until disk usage is below threshold (or no more candidates).
evict_old_images() {
    local current_percent="$1"
    local freed_size_total=0
    local deleted_count=0

    log_info "Disk usage is ${current_percent}% (threshold: ${DISK_THRESHOLD_PERCENT}%)"

    if [[ "$current_percent" -le "$DISK_THRESHOLD_PERCENT" ]]; then
        log_debug "Disk usage is within threshold; no eviction needed"
        return 0
    fi

    log_info "Disk usage exceeds threshold; starting cache eviction"

    # Get list of old images, oldest first
    local old_images
    old_images=$(get_old_images)

    if [[ -z "$old_images" ]]; then
        log_info "No old cached images to evict (all within ${CACHE_RETENTION_DAYS}-day window)"
        return 0
    fi

    # Evict images one by one until below threshold or no more candidates
    while IFS= read -r image_id created_epoch; do
        # Re-check disk usage after each deletion
        if ! current_percent=$(get_disk_usage_percent "$PODMAN_STORAGE"); then
            log_error "Cannot determine current disk usage; stopping eviction"
            break
        fi

        if [[ "$current_percent" -le "$DISK_THRESHOLD_PERCENT" ]]; then
            log_info "Disk usage now ${current_percent}% (below threshold); stopping eviction"
            break
        fi

        # Get image name for logging
        local image_name
        image_name=$(podman images --format "{{.Repository}}:{{.Tag}}" --no-trunc 2>/dev/null | grep "^${image_id:7:12}" | head -1 || echo "$image_id")

        log_info "Evicting image: $image_name (created: $(date -d @$created_epoch 2>/dev/null || date -r $created_epoch))"

        if delete_image "$image_id"; then
            ((deleted_count++))
            log_debug "Successfully deleted image $image_id"
        fi
    done <<< "$old_images"

    # Final status
    if ! current_percent=$(get_disk_usage_percent "$PODMAN_STORAGE"); then
        log_error "Cannot determine final disk usage"
        return 1
    fi

    log_info "Cache eviction complete: deleted $deleted_count images, disk now at ${current_percent}%"
    return 0
}

# Main entry point
main() {
    log_debug "Checking disk usage for podman storage: $PODMAN_STORAGE"

    # Ensure podman storage directory exists
    if [[ ! -d "$PODMAN_STORAGE" ]]; then
        log_debug "Podman storage directory not yet created; skipping cache check"
        return 0
    fi

    # Check current disk usage
    local current_percent
    if ! current_percent=$(get_disk_usage_percent "$PODMAN_STORAGE"); then
        log_error "Failed to determine disk usage; skipping cache eviction"
        return 1
    fi

    # Evict if needed
    if ! evict_old_images "$current_percent"; then
        log_error "Cache eviction encountered errors"
        return 1
    fi

    return 0
}

# Run if script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
