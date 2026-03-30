#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
MANIFEST="$SCRIPT_DIR/debug-sources.toml"
VENDOR_DIR="$PROJECT_ROOT/vendor/debug"

# --- helpers ---

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

list_sources() {
    printf 'Available debug sources (from %s):\n\n' "$MANIFEST"
    local current_name=""
    while IFS= read -r line; do
        if [[ "$line" =~ ^\[([a-zA-Z0-9_-]+)\]$ ]]; then
            current_name="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^default_tag[[:space:]]*=[[:space:]]*\"(.+)\"$ ]] && [[ -n "$current_name" ]]; then
            printf '  %-20s (default: %s)\n' "$current_name" "${BASH_REMATCH[1]}"
            current_name=""
        fi
    done < "$MANIFEST"
    printf '\nUsage: %s <name> [tag]\n' "$(basename "$0")"
    printf 'Example: %s crun 1.19\n' "$(basename "$0")"
}

read_field() {
    local section="$1" field="$2"
    local in_section=false
    while IFS= read -r line; do
        if [[ "$line" =~ ^\[([a-zA-Z0-9_-]+)\]$ ]]; then
            [[ "${BASH_REMATCH[1]}" == "$section" ]] && in_section=true || in_section=false
        elif $in_section && [[ "$line" =~ ^${field}[[:space:]]*=[[:space:]]*\"(.+)\"$ ]]; then
            printf '%s' "${BASH_REMATCH[1]}"
            return 0
        fi
    done < "$MANIFEST"
    return 1
}

# --- main ---

[[ ! -f "$MANIFEST" ]] && die "manifest not found: $MANIFEST"

if [[ $# -eq 0 ]]; then
    list_sources
    exit 0
fi

NAME="$1"
TAG="${2:-}"

REPO=$(read_field "$NAME" "repo") || die "unknown source: $NAME"

if [[ -z "$TAG" ]]; then
    TAG=$(read_field "$NAME" "default_tag") || die "no default tag for $NAME and none specified"
fi

DEST="$VENDOR_DIR/$NAME"

if [[ -d "$DEST" ]]; then
    printf 'Removing existing checkout: %s\n' "$DEST"
    rm -rf "$DEST"
fi

mkdir -p "$VENDOR_DIR"

printf 'Cloning %s @ %s into %s\n' "$REPO" "$TAG" "$DEST"
git clone --depth 1 --branch "$TAG" "$REPO" "$DEST"

printf 'Done. Source available at %s\n' "$DEST"
