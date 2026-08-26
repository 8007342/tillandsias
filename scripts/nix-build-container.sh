#!/usr/bin/env bash
# nix-build-container.sh — nix build with pre-fetched flake inputs
#
# Works around the SSL verification bug in nix's bundled libcurl by
# downloading all flake inputs with system curl (which works) and then
# passing --override-input to nix so it never touches github.com.
#
# This script runs INSIDE the builder container (via with-nix-builder.sh).
# It expects nix, curl, jq to be on PATH.
#
# Usage (host):
#   NIX_BUILD_LANE=container scripts/with-nix-builder.sh \
#       bash scripts/nix-build-container.sh .#tillandsias-x86_64-musl

set -euo pipefail

WORK_DIR="${WORK_DIR:-/work}"
FLAKE_LOCK="$WORK_DIR/flake.lock"

die() { echo "[nix-build-container] FATAL: $*" >&2; exit 1; }

[[ -f "$FLAKE_LOCK" ]] || die "flake.lock not found at $FLAKE_LOCK"

# ── Parse all inputs from flake.lock ───────────────────────────────────────
# Produces TSV: <key>\t<owner>\t<repo>\t<rev>\t<override_path>
_ALL_TSV=$(mktemp)
_FETCH_DIR=$(mktemp -d)
trap 'rm -f "$_ALL_TSV"; rm -rf "$_FETCH_DIR"' EXIT

jq -r '
    .nodes as $N |
    ($N.root.inputs | keys) as $root_keys |

    # Build parent map: node_key -> parent_key
    reduce ($N | to_entries[] |
        select(.key != "root") |
        select(.value.inputs != null) |
        .key as $parent |
        .value.inputs | to_entries[] |
        { key: .value, value: $parent }
    ) as { key: $nk, value: $pk } ({}; .[$nk] = $pk) as $parents |

    # Emit all inputs with locked info and override paths
    $N | to_entries[] |
    select(.key != "root") |
    select(.value.locked != null) |
    select(.value.locked.owner != null) |
    .key as $k |
    .value.locked as $l |

    if ($root_keys | index($k))
    then "\($k)\t\($l.owner)\t\($l.repo)\t\($l.rev)\t\($k)"
    elif ($parents | has($k))
    then
        $parents[$k] as $parent |
        if ($root_keys | index($parent))
        then "\($k)\t\($l.owner)\t\($l.repo)\t\($l.rev)\t\($parent)/\($k)"
        elif ($parents | has($parent))
        then "\($k)\t\($l.owner)\t\($l.repo)\t\($l.rev)\t\($parents[$parent])/\($parent)/\($k)"
        else empty
        end
    else empty
    end
' "$FLAKE_LOCK" > "$_ALL_TSV"

echo "=== Parsed inputs ==="
while IFS=$'\t' read -r key owner repo rev override_path; do
    echo "  ${key} -> ${owner}/${repo}@${rev:0:12} (${override_path})"
done < "$_ALL_TSV"
echo ""

# ── Download all inputs ────────────────────────────────────────────────────
echo "=== Pre-fetching flake inputs ==="
while IFS=$'\t' read -r key owner repo rev override_path; do
    [[ -z "$key" ]] && continue
    url="https://github.com/${owner}/${repo}/archive/${rev}.tar.gz"
    echo "  ${key}: fetching ${owner}/${repo}@${rev:0:12}..."
    curl -fsSL "$url" -o "${_FETCH_DIR}/${key}.tar.gz" \
        || die "download failed: $url"
    mkdir -p "${_FETCH_DIR}/${key}"
    tar xzf "${_FETCH_DIR}/${key}.tar.gz" -C "${_FETCH_DIR}/${key}" --strip-components=1 \
        || die "extract failed: $key"
    rm -f "${_FETCH_DIR}/${key}.tar.gz"
    echo "  ${key}: OK"
done < "$_ALL_TSV"

# ── Build override flags ───────────────────────────────────────────────────
echo ""
echo "=== Building override flags ==="
_OVERRIDES=()
while IFS=$'\t' read -r key owner repo rev override_path; do
    [[ -z "$key" ]] && continue
    [[ -d "${_FETCH_DIR}/${key}" ]] || continue
    _OVERRIDES+=("--override-input" "$override_path" "${_FETCH_DIR}/${key}")
done < "$_ALL_TSV"

echo "Flags: ${_OVERRIDES[*]:-<none>}"

# ── Run nix build ──────────────────────────────────────────────────────────
echo ""
echo "=== Running nix build ==="
nix --extra-experimental-features "nix-command flakes" build \
    "$@" "${_OVERRIDES[@]}"
