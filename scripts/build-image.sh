#!/usr/bin/env bash
# Build container images using Nix inside an ephemeral podman container.
# Usage: scripts/build-image.sh [forge|web|proxy|git|inference|router] [--force]
#                               [--max-age-days N] [--refresh-sources]
#
# This script:
#   1. Checks if sources have changed since last build (staleness detection)
#   2. (forge only) Runs the bundled-tier cheatsheet-source bake:
#      - Invokes scripts/fetch-cheatsheet-source.sh --tier=bundled
#      - Stages the cache-key directory as cheatsheet-sources/ in the build context
#      - Writes per-cheatsheet meta side-channel under .cheatsheets-meta/
#      - On network failure, reuses the previous cache key (graceful degradation)
#   3. Runs `nix build` (or `podman build`) to produce the image
#   4. Loads the resulting tarball into podman and tags the image
#
# No toolbox dependency — works on any system with podman.
#
# Bundled-tier flags (forge only):
#   --max-age-days N      Pass-through to fetcher; flips the cache key when changed.
#                         Default: 30 (local builds). CI passes 7.
#   --refresh-sources     Force re-fetch even if the cache-key directory exists
#                         (blows away the directory before re-running the fetcher).
#
# Environment:
#   TILLANDSIAS_BUILD_VERBOSE=1   Show nix build output
#
# @trace spec:cheatsheets-license-tiered
# @cheatsheet runtime/cheatsheet-tier-system.md

set -euo pipefail

# @trace spec:nix-builder, spec:default-image

# ---------------------------------------------------------------------------
# macOS PATH fix: Finder-launched apps don't inherit shell PATH.
# Ensure common tool directories are reachable (Homebrew, MacPorts, etc.)
# Linux is unaffected — this block is a no-op there.
# ---------------------------------------------------------------------------
if [[ "$(uname -s)" == "Darwin" ]]; then
    for _dir in /opt/homebrew/bin /opt/local/bin /usr/local/bin; do
        [[ -d "$_dir" ]] && [[ ":$PATH:" != *":$_dir:"* ]] && export PATH="$_dir:$PATH"
    done
    unset _dir
fi

# Resolve the podman binary: prefer PODMAN_PATH from Rust caller, then
# check known absolute paths, then fall back to bare "podman" (PATH lookup).
if [[ -n "${PODMAN_PATH:-}" ]] && [[ -x "$PODMAN_PATH" ]]; then
    PODMAN="$PODMAN_PATH"
elif [[ -x /opt/homebrew/bin/podman ]]; then
    PODMAN=/opt/homebrew/bin/podman
elif [[ -x /opt/local/bin/podman ]]; then
    PODMAN=/opt/local/bin/podman
elif [[ -x /usr/local/bin/podman ]]; then
    PODMAN=/usr/local/bin/podman
elif [[ -x /usr/bin/podman ]]; then
    PODMAN=/usr/bin/podman
else
    PODMAN=podman
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Pinned for reproducibility. Update: podman pull docker.io/nixos/nix:<new-version>
NIX_IMAGE="docker.io/nixos/nix:2.34.4"
# Hash file must survive temp dir cleanup. When the app invokes this script,
# $ROOT is a temp dir that gets deleted after the build completes. Store the
# staleness hash in the user's cache dir so it persists across launches.
if [[ -d "$HOME/Library/Caches/tillandsias" ]]; then
    CACHE_DIR="$HOME/Library/Caches/tillandsias/build-hashes"
elif [[ -d "$HOME/.cache/tillandsias" ]]; then
    CACHE_DIR="$HOME/.cache/tillandsias/build-hashes"
else
    CACHE_DIR="$ROOT/.nix-output"
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

_info()  { echo -e "${GREEN}[build-image]${NC} $*"; }
_warn()  { echo -e "${YELLOW}[build-image]${NC} $*"; }
_error() { echo -e "${RED}[build-image]${NC} $*" >&2; }
_step()  { echo -e "${CYAN}[build-image]${NC} $*"; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
IMAGE_NAME="forge"
FLAG_FORCE=false
FLAG_TAG=""
FLAG_BACKEND="fedora"  # Default: Fedora minimal. Use --backend nix for Nix image.
# @trace spec:cheatsheets-license-tiered
FLAG_MAX_AGE_DAYS="30"        # Default for local builds; CI passes 7.
FLAG_REFRESH_SOURCES=false    # --refresh-sources forces re-fetch on cache hit.

while [[ $# -gt 0 ]]; do
    case "$1" in
        forge|web|proxy|git|inference|router)
            IMAGE_NAME="$1"
            ;;
        --force)
            FLAG_FORCE=true
            ;;
        --tag)
            shift
            FLAG_TAG="$1"
            ;;
        --backend)
            shift
            FLAG_BACKEND="$1"
            ;;
        --max-age-days)
            # @trace spec:cheatsheets-license-tiered
            shift
            FLAG_MAX_AGE_DAYS="${1:-}"
            if [[ -z "${FLAG_MAX_AGE_DAYS}" ]]; then
                _error "--max-age-days requires a numeric argument"
                exit 1
            fi
            ;;
        --max-age-days=*)
            # @trace spec:cheatsheets-license-tiered
            FLAG_MAX_AGE_DAYS="${1#--max-age-days=}"
            ;;
        --refresh-sources)
            # @trace spec:cheatsheets-license-tiered
            FLAG_REFRESH_SOURCES=true
            ;;
        --help|-h)
            echo "Usage: scripts/build-image.sh [forge|web|proxy|git|inference|router] [--force] [--tag <tag>] [--backend fedora|nix]"
            echo "                              [--max-age-days N] [--refresh-sources]"
            echo ""
            echo "Build a container image."
            echo ""
            echo "Arguments:"
            echo "  forge              Build the forge (dev environment) image (default)"
            echo "  web                Build the web server image"
            echo "  proxy              Build the enclave proxy image"
            echo "  git                Build the git service image"
            echo "  inference          Build the local LLM inference image"
            echo "  --force            Rebuild even if sources haven't changed"
            echo "  --tag <tag>        Override the image tag (default: tillandsias-<name>:latest)"
            echo "  --backend <type>   Build backend: fedora (default) or nix"
            echo "  --max-age-days N   Bundled-tier cheatsheet-source freshness (default: 30; CI uses 7)"
            echo "  --refresh-sources  Force re-fetch of bundled cheatsheet sources even on cache hit"
            exit 0
            ;;
        *)
            _error "Unknown argument: $1 (try --help)"
            exit 1
            ;;
    esac
    shift
done

if [[ -n "$FLAG_TAG" ]]; then
    IMAGE_TAG="$FLAG_TAG"
else
    IMAGE_TAG="tillandsias-${IMAGE_NAME}:latest"
fi
NIX_ATTR="${IMAGE_NAME}-image"
# Version the hash file with the image tag so each version has independent
# staleness state. Sanitize tag for filename (replace : and / with -).
HASH_SUFFIX="$(echo "$IMAGE_TAG" | tr ':/' '--')"
HASH_FILE="$CACHE_DIR/.last-build-${HASH_SUFFIX}.sha256"

# Verify required files exist based on backend
if [[ "$FLAG_BACKEND" == "nix" ]] && [[ ! -f "$ROOT/flake.nix" ]]; then
    _error "flake.nix not found at $ROOT/"
    _error "When installed, flake.nix should be at ~/.local/share/tillandsias/flake.nix"
    _error "Run './build.sh --install' from the project directory to fix this."
    exit 1
fi

_step "Building image: ${BOLD}${IMAGE_TAG}${NC}"

# ---------------------------------------------------------------------------
# Step 1: Staleness detection
# ---------------------------------------------------------------------------
mkdir -p "$CACHE_DIR"

# Clean up old unversioned hash files (legacy format: .last-build-forge.sha256)
# These carry over across version bumps, creating false "up to date" results.
# @trace spec:forge-staleness
for _old in "$CACHE_DIR/.last-build-forge.sha256" \
            "$CACHE_DIR/.last-build-proxy.sha256" \
            "$CACHE_DIR/.last-build-git.sha256" \
            "$CACHE_DIR/.last-build-inference.sha256" \
            "$CACHE_DIR/.last-build-web.sha256"; do
    if [[ -f "$_old" ]]; then
        _info "Removing legacy hash file: $(basename "$_old")"
        rm -f "$_old"
    fi
done
unset _old

_is_git_repo() {
    git -C "$ROOT" rev-parse --is-inside-work-tree &>/dev/null
}

# @trace spec:nix-builder/git-tracked-files
_check_untracked_image_sources() {
    # Fail early if untracked files exist in image source dirs — they would
    # be silently excluded from the Nix flake build, producing wrong images.
    if ! _is_git_repo; then
        return 0
    fi
    local untracked
    untracked="$(git -C "$ROOT" ls-files --others --exclude-standard -- images/default images/web images/proxy images/git images/inference images/router 2>/dev/null)"
    if [[ -n "$untracked" ]]; then
        _error "Untracked files in image sources (Nix will silently exclude them):"
        while IFS= read -r f; do
            _error "  $f"
        done <<< "$untracked"
        _error "Stage them with: git add <files>"
        exit 1
    fi
}

_compute_hash() {
    # Hash the flake definition, lock file, and image source files.
    # Uses git ls-files to match what Nix flake builds actually see.
    # @trace spec:nix-builder/git-tracked-files
    local files=()

    # Flake files (always relevant)
    [[ -f "$ROOT/flake.nix" ]]  && files+=("$ROOT/flake.nix")
    [[ -f "$ROOT/flake.lock" ]] && files+=("$ROOT/flake.lock")

    # Image source directories — use git ls-files to match Nix's view
    if _is_git_repo; then
        for dir in images/default images/web images/proxy images/git images/inference images/router; do
            while IFS= read -r f; do
                [[ -n "$f" ]] && files+=("$ROOT/$f")
            done < <(git -C "$ROOT" ls-files -- "$dir" 2>/dev/null)
        done
    else
        _warn "Not a git repo — falling back to find (untracked file detection unavailable)"
        for dir in "$ROOT/images/default" "$ROOT/images/web" "$ROOT/images/proxy" "$ROOT/images/git" "$ROOT/images/inference" "$ROOT/images/router"; do
            if [[ -d "$dir" ]]; then
                while IFS= read -r -d '' f; do
                    files+=("$f")
                done < <(find "$dir" -type f -print0 2>/dev/null)
            fi
        done
    fi

    if [[ ${#files[@]} -eq 0 ]]; then
        echo "no-sources"
        return
    fi

    sha256sum "${files[@]}" 2>/dev/null | sha256sum | cut -d' ' -f1
}

_check_untracked_image_sources
CURRENT_HASH="$(_compute_hash)"

if [[ "$FLAG_FORCE" == false ]] && [[ -f "$HASH_FILE" ]]; then
    LAST_HASH="$(cat "$HASH_FILE")"
    if [[ "$CURRENT_HASH" == "$LAST_HASH" ]]; then
        # Verify the image actually exists in podman
        if "$PODMAN" image exists "$IMAGE_TAG" 2>/dev/null; then
            _info "Image ${BOLD}${IMAGE_TAG}${NC} is up to date (sources unchanged)"
            exit 0
        else
            _warn "Hash matches but image not found in podman, rebuilding..."
        fi
    fi
fi

if [[ "$FLAG_FORCE" == true ]]; then
    _info "Force rebuild requested"
fi

# ---------------------------------------------------------------------------
# Step 2: Build image
# ---------------------------------------------------------------------------
BUILD_START="$(date +%s)"

if [[ "$FLAG_BACKEND" == "fedora" ]]; then
    # ── Fedora backend: podman build with Containerfile ────────
    # Route to the correct image directory based on IMAGE_NAME.
    # @trace spec:proxy-container
    case "$IMAGE_NAME" in
        web)       IMAGE_DIR="$ROOT/images/web" ;;
        proxy)     IMAGE_DIR="$ROOT/images/proxy" ;;
        git)       IMAGE_DIR="$ROOT/images/git" ;;
        inference) IMAGE_DIR="$ROOT/images/inference" ;;
        router)    IMAGE_DIR="$ROOT/images/router" ;;
        *)         IMAGE_DIR="$ROOT/images/default" ;;
    esac
    _step "Building ${BOLD}${IMAGE_TAG}${NC} via podman build (Fedora minimal)..."
    CONTAINERFILE="$IMAGE_DIR/Containerfile"
    if [[ ! -f "$CONTAINERFILE" ]]; then
        _error "Containerfile not found at $CONTAINERFILE"
        exit 1
    fi

    # @trace spec:cheatsheets-license-tiered
    # @cheatsheet runtime/cheatsheet-tier-system.md
    # ── Bundled-tier cheatsheet-source bake (forge only) ────────
    # Walks cheatsheets/**/*.md, filters tier: bundled, fetches the union of
    # source_urls into a cache-key-named directory under
    # $XDG_CACHE_HOME/tillandsias/cheatsheet-source-bake/<key>/, then stages
    # that directory into the build context as `.cheatsheet-sources/`. The
    # Containerfile COPYs it into /opt/cheatsheet-sources/ inside the image.
    #
    # Network failures are non-fatal — if the fetcher fails AND a previous
    # cache key directory exists, the most recent one is reused with a WARN.
    # If no previous cache exists, the build proceeds with an empty
    # cheatsheet-sources/ subtree (graceful degradation).
    #
    # See Decision 7 in openspec/changes/cheatsheets-license-tiered/design.md.
    if [[ "$IMAGE_NAME" == "forge" ]] || [[ "$IMAGE_NAME" == "default" ]]; then
        _bundled_tier_bake() {
            local fetcher="$ROOT/scripts/fetch-cheatsheet-source.sh"
            if [[ ! -x "$fetcher" ]]; then
                _warn "fetch-cheatsheet-source.sh not found or not executable; skipping bundled-tier bake"
                return 0
            fi

            # Match the fetcher's CACHE_DIR computation so we can both run the
            # fetcher and inspect/reuse its output directories on failure.
            local bundled_cache_root="${XDG_CACHE_HOME:-$HOME/.cache}/tillandsias/cheatsheet-source-bake"
            mkdir -p "$bundled_cache_root"

            _step "Bundled-tier cheatsheet-source bake (max-age-days=${FLAG_MAX_AGE_DAYS}${FLAG_REFRESH_SOURCES:+, refresh})..."

            # Run the fetcher; capture stdout. The contract is that the LAST
            # TWO lines of stdout are `key=<16hex>` and `dir=<absolute-path>`.
            local fetcher_out
            local fetcher_rc=0
            local fetcher_log
            fetcher_log="$(mktemp)"
            fetcher_out="$("$fetcher" --tier=bundled --max-age-days "$FLAG_MAX_AGE_DAYS" 2>"$fetcher_log")" || fetcher_rc=$?

            # Parse last two stdout lines for key=… and dir=… (contract per
            # bundled_tier_main in fetch-cheatsheet-source.sh).
            local key="" dir=""
            if [[ "$fetcher_rc" -eq 0 ]] && [[ -n "$fetcher_out" ]]; then
                key="$(printf '%s\n' "$fetcher_out" | awk -F= '/^key=/ {k=$2} END {print k}')"
                dir="$(printf '%s\n' "$fetcher_out" | awk -F= '/^dir=/ {sub(/^dir=/,""); d=$0} END {print d}')"
            fi

            if [[ "$fetcher_rc" -ne 0 ]]; then
                _warn "[build-image] WARN: bundled-tier fetch failed (exit $fetcher_rc)"
                # Fall back to the most-recent prior cache-key directory.
                local prev_dir prev_mtime
                prev_dir=""
                prev_mtime=0
                if [[ -d "$bundled_cache_root" ]]; then
                    while IFS= read -r -d '' candidate; do
                        local m
                        m="$(stat -c '%Y' "$candidate" 2>/dev/null || stat -f '%m' "$candidate" 2>/dev/null || echo 0)"
                        if [[ "$m" -gt "$prev_mtime" ]]; then
                            prev_mtime="$m"
                            prev_dir="$candidate"
                        fi
                    done < <(find "$bundled_cache_root" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
                fi
                if [[ -n "$prev_dir" ]]; then
                    local prev_key
                    prev_key="$(basename "$prev_dir")"
                    local prev_date
                    prev_date="$(date -u -d "@$prev_mtime" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
                                 || date -u -r "$prev_mtime" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
                                 || echo unknown)"
                    _warn "[build-image] WARN: reusing previous cache key ${prev_key} from ${prev_date}"
                    dir="$prev_dir"
                    key="$prev_key"
                else
                    _warn "[build-image] WARN: no previous cache key directory available; staging EMPTY cheatsheet-sources/ subtree (graceful degradation)"
                    dir=""
                    key=""
                fi
            fi

            # Optional --refresh-sources: blow away the resolved cache-key
            # directory so the next invocation re-fetches. We do this AFTER
            # the initial run so the meta side-channel still has fresh data.
            # On --refresh-sources we re-invoke the fetcher to repopulate.
            if [[ "$FLAG_REFRESH_SOURCES" == "true" ]] && [[ "$fetcher_rc" -eq 0 ]] && [[ -n "$dir" ]] && [[ -d "$dir" ]]; then
                _step "--refresh-sources: blowing away ${dir} and re-fetching..."
                rm -rf "$dir"
                fetcher_rc=0
                fetcher_out="$("$fetcher" --tier=bundled --max-age-days "$FLAG_MAX_AGE_DAYS" 2>"$fetcher_log")" || fetcher_rc=$?
                if [[ "$fetcher_rc" -eq 0 ]] && [[ -n "$fetcher_out" ]]; then
                    key="$(printf '%s\n' "$fetcher_out" | awk -F= '/^key=/ {k=$2} END {print k}')"
                    dir="$(printf '%s\n' "$fetcher_out" | awk -F= '/^dir=/ {sub(/^dir=/,""); d=$0} END {print d}')"
                else
                    _warn "[build-image] WARN: --refresh-sources fetch failed (exit $fetcher_rc); cache directory was removed and could not be re-populated"
                fi
            fi

            # Surface fetcher stderr only when verbose or on failure (signal-to-noise).
            if [[ "${TILLANDSIAS_BUILD_VERBOSE:-0}" == "1" ]] || [[ "$fetcher_rc" -ne 0 ]]; then
                if [[ -s "$fetcher_log" ]]; then
                    while IFS= read -r line; do
                        _info "  $line"
                    done < "$fetcher_log"
                fi
            fi
            rm -f "$fetcher_log"

            # Stage the cache-key directory as the build context's
            # `.cheatsheet-sources/` subtree. cp -aL would dereference; we want
            # the verbatim file tree (no symlinks expected anyway). Use rsync
            # if available for incremental copies; fall back to cp -a.
            rm -rf "$IMAGE_DIR/.cheatsheet-sources"
            mkdir -p "$IMAGE_DIR/.cheatsheet-sources"
            if [[ -n "$dir" ]] && [[ -d "$dir" ]]; then
                if command -v rsync >/dev/null 2>&1; then
                    rsync -a --delete "$dir/" "$IMAGE_DIR/.cheatsheet-sources/"
                else
                    rm -rf "$IMAGE_DIR/.cheatsheet-sources"
                    cp -a "$dir" "$IMAGE_DIR/.cheatsheet-sources"
                fi
                _info "Staged cheatsheet-sources from cache key ${key:-unknown}"
            elif [[ "$fetcher_rc" -eq 0 ]]; then
                # Fetcher succeeded but produced no key/dir — means there are
                # currently zero tier: bundled cheatsheets to bake. This is
                # benign during migration. Marker file documents the state.
                echo "No tier: bundled cheatsheets configured at build time." \
                    > "$IMAGE_DIR/.cheatsheet-sources/EMPTY.md"
                _info "Staged EMPTY cheatsheet-sources subtree (no bundled cheatsheets)"
            else
                # Network failure AND no prior cache — graceful degradation.
                echo "Bundled cheatsheet sources unavailable at build time (network failure, no prior cache)." \
                    > "$IMAGE_DIR/.cheatsheet-sources/UNAVAILABLE.md"
                _info "Staged EMPTY cheatsheet-sources subtree (no prior cache to fall back on)"
            fi

            # Build the per-cheatsheet meta side-channel under
            # `.cheatsheets-meta/<category>/<name>.frontmatter.json`. For each
            # bundled cheatsheet, look up source_urls[0]'s sidecar (.meta.yaml)
            # in the staged cheatsheet-sources tree, then write a JSON object
            # with image_baked_sha256, structural_drift_fingerprint, fetched_at,
            # and url. populate_hot_paths() reads these at forge launch to
            # inject the SHA into INDEX.md without rewriting the cheatsheet.
            rm -rf "$IMAGE_DIR/.cheatsheets-meta"
            mkdir -p "$IMAGE_DIR/.cheatsheets-meta"
            if [[ -d "$ROOT/cheatsheets" ]] && [[ -d "$IMAGE_DIR/.cheatsheet-sources" ]]; then
                # @trace spec:cheatsheets-license-tiered
                # @cheatsheet runtime/cheatsheet-tier-system.md
                # Inline Python: walk cheatsheets/**/*.md, find tier: bundled
                # entries, look up the first source_url's sidecar, emit JSON.
                python3 - "$ROOT/cheatsheets" "$IMAGE_DIR/.cheatsheet-sources" "$IMAGE_DIR/.cheatsheets-meta" <<'PYMETAEOF' || _warn "meta side-channel injection failed (non-fatal)"
import json
import os
import re
import sys
from urllib.parse import urlsplit

cheatsheets_root = sys.argv[1]
sources_root = sys.argv[2]
meta_root = sys.argv[3]


def parse_frontmatter(path):
    with open(path, encoding='utf-8', errors='replace') as f:
        text = f.read()
    m = re.match(r'^---\n(.*?)\n---\n', text, re.DOTALL)
    if not m:
        return {}
    fm = m.group(1)
    out = {}
    cur_list = None
    for line in fm.splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        m2 = re.match(r'^\s+-\s+(.*)$', line)
        if m2 and cur_list is not None:
            item = m2.group(1).strip().strip('"').strip("'")
            out.setdefault(cur_list, []).append(item)
            continue
        m3 = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*)$', line)
        if m3:
            k = m3.group(1)
            v = m3.group(2).strip()
            if v in ('', '|', '>'):
                cur_list = k
                out.setdefault(k, [])
            else:
                cur_list = None
                out[k] = v.strip('"').strip("'")
    return out


def parse_sidecar(path):
    """Tiny YAML scalar parser — keys are simple `key: value` lines."""
    out = {}
    try:
        with open(path, encoding='utf-8', errors='replace') as f:
            for line in f:
                m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*):\s*(.*)$', line)
                if m:
                    out[m.group(1)] = m.group(2).strip()
    except OSError:
        pass
    return out


def url_to_relpath(url):
    """Mirror compute_dest_path() in fetch-cheatsheet-source.sh."""
    if not url.startswith('https://'):
        return None
    parts = urlsplit(url)
    host = parts.netloc
    path = parts.path
    # GitHub blob → raw rewrite produces raw.githubusercontent.com paths.
    if host == 'github.com' and '/blob/' in path:
        path = path.replace('/blob/', '/', 1)
        host = 'raw.githubusercontent.com'
    # Strip trailing /
    if path.endswith('/'):
        path = path[:-1]
    if not path or path == '/':
        path = '/index.html'
    return f"{host}{path}"


written = 0
skipped = 0
for dirpath, _, files in os.walk(cheatsheets_root):
    for name in files:
        if not name.endswith('.md'):
            continue
        md_path = os.path.join(dirpath, name)
        fm = parse_frontmatter(md_path)
        if fm.get('tier') != 'bundled':
            continue
        urls = fm.get('source_urls') or fm.get('sources') or []
        if isinstance(urls, str):
            urls = [urls]
        canonical = None
        for u in urls:
            if u.startswith('https://'):
                canonical = u
                break
        if not canonical:
            skipped += 1
            continue
        relpath = url_to_relpath(canonical)
        if not relpath:
            skipped += 1
            continue
        # Try several candidate sidecar locations (matches fetcher behaviour).
        sidecar = None
        produced = None
        for cand in (
            os.path.join(sources_root, relpath + '.meta.yaml'),
            os.path.join(sources_root, relpath + '.norepublish.meta.yaml'),
        ):
            if os.path.isfile(cand):
                sidecar = cand
                # Strip the .meta.yaml suffix to get the produced file path.
                produced = cand[:-len('.meta.yaml')]
                break
        if not sidecar:
            # Try .txt variant (IETF rewrite).
            for ext in ('.txt', '.html'):
                alt = relpath + ext
                cand = os.path.join(sources_root, alt + '.meta.yaml')
                if os.path.isfile(cand):
                    sidecar = cand
                    produced = cand[:-len('.meta.yaml')]
                    break
        if not sidecar:
            skipped += 1
            continue
        meta = parse_sidecar(sidecar)
        rel_md = os.path.relpath(md_path, cheatsheets_root)
        category, basename = os.path.split(rel_md)
        out_dir = os.path.join(meta_root, category)
        os.makedirs(out_dir, exist_ok=True)
        out_name = basename[:-3] + '.frontmatter.json'  # strip .md
        # image_baked_sha256: short prefix of content_sha256 (16 hex per spec design).
        sha = meta.get('content_sha256', '')
        image_baked_sha256 = sha[:16] if sha else ''
        payload = {
            'image_baked_sha256': image_baked_sha256,
            'structural_drift_fingerprint': meta.get('structural_drift_fingerprint', 'n/a'),
            'fetched_at': meta.get('fetched', ''),
            'url': meta.get('url', canonical),
        }
        with open(os.path.join(out_dir, out_name), 'w', encoding='utf-8') as f:
            json.dump(payload, f, indent=2, sort_keys=True)
            f.write('\n')
        written += 1

print(f"  meta side-channel: wrote {written} entries, skipped {skipped}")
PYMETAEOF
                _info "Wrote .cheatsheets-meta/ side-channel for bundled cheatsheets"
            fi
        }
        _bundled_tier_bake
    fi

    # @trace spec:agent-cheatsheets, spec:default-image
    # Stage the project-root `cheatsheets/` directory into the forge image's
    # build context as `.cheatsheets/` so the Containerfile can `COPY` it.
    # The cheatsheets are sourced from the repo root (single source of truth)
    # but the build context is the per-image dir; copying is the simplest way
    # to bridge that. The staged copy is gitignored.
    if [[ "$IMAGE_NAME" == "forge" ]] || [[ "$IMAGE_NAME" == "default" ]]; then
        if [[ -d "$ROOT/cheatsheets" ]]; then
            _step "Staging cheatsheets/ into forge build context..."
            rm -rf "$IMAGE_DIR/.cheatsheets"
            cp -r "$ROOT/cheatsheets" "$IMAGE_DIR/.cheatsheets"
        else
            _warn "Project root has no cheatsheets/ dir — forge image will skip the layer"
            mkdir -p "$IMAGE_DIR/.cheatsheets"
            echo "Cheatsheets directory missing at build time" > "$IMAGE_DIR/.cheatsheets/MISSING.md"
        fi
    fi

    # Pass proxy env vars as build args if available.
    # Image builds do NOT go through the proxy — SSL bump requires CA trust
    # that build containers don't have. Proxy is for runtime containers only.
    #
    # @trace spec:opencode-web-session-otp
    # The router image's Containerfile expects a pre-built sidecar binary
    # at `images/router/tillandsias-router-sidecar`. When running from the
    # workspace, refresh it via `scripts/build-sidecar.sh` first; the
    # script is idempotent (cargo skips when up-to-date). When running
    # from the embedded extraction at runtime the binary is already
    # present (extracted from the tray's include_bytes!), so the helper
    # call is a no-op or skipped via an env-flag check.
    if [[ "$IMAGE_NAME" == "router" ]] && [[ -z "${TILLANDSIAS_SKIP_SIDECAR_REBUILD:-}" ]]; then
        if [[ -x "$ROOT/scripts/build-sidecar.sh" ]]; then
            _step "Refreshing tillandsias-router-sidecar binary..."
            "$ROOT/scripts/build-sidecar.sh"
        fi
    fi

    "$PODMAN" build \
        --tag "$IMAGE_TAG" \
        -f "$CONTAINERFILE" \
        "$IMAGE_DIR/"

    # Clean up the staged cheatsheets so they don't accumulate in the build context.
    # @trace spec:cheatsheets-license-tiered
    if [[ "$IMAGE_NAME" == "forge" ]] || [[ "$IMAGE_NAME" == "default" ]]; then
        rm -rf "$IMAGE_DIR/.cheatsheets"
        rm -rf "$IMAGE_DIR/.cheatsheet-sources"
        rm -rf "$IMAGE_DIR/.cheatsheets-meta"
    fi

else
    # ── Nix backend: nix build inside ephemeral container ─────
    # @trace spec:nix-builder/ephemeral-nix-build, knowledge:packaging/nix-flakes
    OUTPUT_DIR="$CACHE_DIR/build-output"
    mkdir -p "$OUTPUT_DIR"
    rm -f "$OUTPUT_DIR/result.tar.gz"

    _step "Running nix build .#${NIX_ATTR} inside ephemeral ${NIX_IMAGE} container..."

    NIX_BUILD_CMD="nix --extra-experimental-features 'nix-command flakes' build /src#${NIX_ATTR} --print-out-paths --no-link 2>&1 | tee /dev/stderr | tail -1 | xargs -I{} cp {} /output/result.tar.gz"

    # --security-opt label=disable bypasses SELinux label checks.
    "$PODMAN" run --rm \
        --security-opt label=disable \
        -v "$ROOT:/src:ro" \
        -v "$OUTPUT_DIR:/output:rw" \
        "$NIX_IMAGE" \
        bash -c "$NIX_BUILD_CMD"

    TARBALL_PATH="$OUTPUT_DIR/result.tar.gz"

    if [[ ! -f "$TARBALL_PATH" ]]; then
        _error "Nix build failed — no tarball produced at $TARBALL_PATH"
        exit 1
    fi

    _info "Tarball: $TARBALL_PATH"

    # Load tarball into podman
    _step "Loading image into podman..."
    LOAD_OUTPUT="$("$PODMAN" load < "$TARBALL_PATH" 2>&1)"
    echo "$LOAD_OUTPUT" | while IFS= read -r line; do
        _info "  $line"
    done

    LOADED_IMAGE="$(echo "$LOAD_OUTPUT" | grep 'Loaded image' | sed 's/.*: //' | tail -1 | tr -d '[:space:]')"

    if [[ -n "$LOADED_IMAGE" ]] && [[ "$LOADED_IMAGE" != "$IMAGE_TAG" ]]; then
        _step "Tagging as ${IMAGE_TAG}..."
        "$PODMAN" tag "$LOADED_IMAGE" "$IMAGE_TAG"
    fi
fi

# Verify the image exists — retry briefly because podman storage may need
# a moment to flush after a build completes (prevents false negatives).
# @trace spec:default-image
_image_found=false
for _attempt in 1 2 3; do
    if "$PODMAN" image exists "$IMAGE_TAG" 2>/dev/null; then
        _image_found=true
        break
    fi
    _warn "Image ${IMAGE_TAG} not found on attempt ${_attempt}/3, retrying..."
    sleep 1
done

if [[ "$_image_found" == false ]]; then
    _error "Image ${IMAGE_TAG} not found after build + 3 retries. Something went wrong."
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 5: Save hash for staleness detection
# ---------------------------------------------------------------------------
echo "$CURRENT_HASH" > "$HASH_FILE"

# Clean up the build output tarball (Nix backend only)
if [[ -n "${TARBALL_PATH:-}" ]]; then
    rm -f "$TARBALL_PATH"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
BUILD_END="$(date +%s)"
BUILD_DURATION=$(( BUILD_END - BUILD_START ))

# Get image size
IMAGE_SIZE="$("$PODMAN" image inspect "$IMAGE_TAG" --format '{{.Size}}' 2>/dev/null || echo "")"
if [[ -n "$IMAGE_SIZE" ]]; then
    SIZE_MB=$(( IMAGE_SIZE / 1024 / 1024 ))
    SIZE_DISPLAY="${SIZE_MB} MB"
else
    SIZE_DISPLAY="unknown"
fi

echo ""
_info "----------------------------------------------"
_info "Image:    ${BOLD}${IMAGE_TAG}${NC}"
_info "Size:     ${SIZE_DISPLAY}"
_info "Time:     ${BUILD_DURATION}s"
_info "----------------------------------------------"
