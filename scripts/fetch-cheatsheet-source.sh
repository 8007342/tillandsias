#!/usr/bin/env bash
# fetch-cheatsheet-source.sh — verbatim fetcher for the cheatsheet-source layer.
#
# Usage:
#   scripts/fetch-cheatsheet-source.sh <URL> [--cite cheatsheets/<path>]
#   scripts/fetch-cheatsheet-source.sh <URL> [--manual-review]
#   scripts/fetch-cheatsheet-source.sh --tier=bundled [--max-age-days N] [--dry-run]
#
# Fetches the given URL verbatim, stores it under cheatsheet-sources/, writes
# a .meta.yaml sidecar, and (optionally) appends a local-source line to the
# named cheatsheet's ## Provenance section.
#
# Options:
#   --cite <path>      Append a local: line to the cheatsheet's ## Provenance
#                      section. Path must be cheatsheets/<category>/<file>.md
#   --manual-review    Allow fetching from domains not in license-allowlist.toml
#                      (redistribution will be marked "manual-review-required")
#   --force            Re-fetch even if the output file already exists
#   --canonicalize     (opt-in) strip Google Analytics and other tracker params
#                      from the stored copy (NOT implemented in chunk 1; reserved)
#   --tier=bundled     Bake mode: read all cheatsheets/**/*.md frontmatter, filter
#                      to tier: bundled, fetch each cheatsheet's source_urls into
#                      a cache-key-named directory under
#                      $CACHE_DIR/cheatsheet-source-bake/<key>/.
#                      Prints the cache key and directory on stdout.
#   --max-age-days N   (bundled mode) Treated as part of the cache key; callers
#                      pass this so refresh cadence flips the key.
#   --dry-run          (bundled mode) List what would be fetched without
#                      performing any HTTP request.
#
# Algorithm (§4 of docs/strategy/cheatsheet-source-layer-plan.md):
#   1. Validate URL: https only; host on allowlist unless --manual-review.
#   2. Compute deterministic on-disk path from URL.
#   3. Try single-page variants; first 200+non-empty wins.
#      - GitHub blob → rewrite to raw.githubusercontent.com
#      - RFC .txt preferred over .html
#      - Single-page variants tried: ?print=1, /print/, /single-page/
#   4. Fetch with curl using the tillandsias user-agent.
#   5. SHA-256 the bytes.
#   6. Look up host in license-allowlist.toml for license/publisher/redistribution.
#   7. Write verbatim file and .meta.yaml sidecar.
#      - redistribution:do-not-bundle → suffix .norepublish
#   8. If --cite, append local: line to cheatsheet's Provenance (idempotent).
#   9. Regenerate INDEX.json via regenerate-source-index.sh.
#
# Bundled-tier algorithm (Decision 7 of openspec/changes/cheatsheets-license-tiered):
#   1. Walk cheatsheets/**/*.md, parse YAML frontmatter, filter tier: bundled.
#   2. Union all source_urls (preferring source_urls[]; falling back to sources[]).
#   3. Compute cache key:
#        SHA-256( "\n".join(sorted(unique_urls)) + "\n" + "max-age-days=N" )
#      truncated to first 16 hex chars. Same URL set + same N → same key.
#   4. Output directory: $CACHE_DIR/cheatsheet-source-bake/<key>/
#      where $CACHE_DIR defaults to ${XDG_CACHE_HOME:-$HOME/.cache}/tillandsias.
#   5. For each URL: re-invoke this script with CHEATSHEET_SOURCES_DIR=<key-dir>
#      so all the existing fetch logic (GitHub-blob rewrite, IETF .txt, sidecar
#      writing, allowlist lookup) is reused without duplication.
#   6. After each successful fetch, compute structural-drift fingerprint over
#      <h1>+<h2>+<h3> headings (HTML only; non-HTML emits "n/a"). Persist as
#      `structural_drift_fingerprint:` in the per-file .meta.yaml sidecar.
#   7. Print cache key and directory path on stdout (consumed by build-image.sh).
#
# @trace spec:cheatsheet-source-layer, spec:cheatsheets-license-tiered
# @cheatsheet runtime/cheatsheet-tier-system.md
# OpenSpec change: cheatsheet-source-layer, cheatsheets-license-tiered

set -euo pipefail

# ---------------------------------------------------------------------------
# Locate repo root.
# ---------------------------------------------------------------------------

if ! REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi

# SOURCES_DIR is overridable via CHEATSHEET_SOURCES_DIR env so the bundled-tier
# bake mode can redirect output to a per-cache-key directory under
# $CACHE_DIR/cheatsheet-source-bake/<key>/ without duplicating the fetch logic.
# @trace spec:cheatsheets-license-tiered
SOURCES_DIR="${CHEATSHEET_SOURCES_DIR:-${REPO_ROOT}/cheatsheet-sources}"

# License allowlist relocated from cheatsheet-sources/ to cheatsheets/ in the
# cheatsheets-license-tiered change. Prefer the new location, fall back to the
# old one for backward compatibility during migration.
# @trace spec:cheatsheets-license-tiered
if [[ -f "${REPO_ROOT}/cheatsheets/license-allowlist.toml" ]]; then
    ALLOWLIST="${REPO_ROOT}/cheatsheets/license-allowlist.toml"
else
    ALLOWLIST="${REPO_ROOT}/cheatsheet-sources/license-allowlist.toml"
fi
SCRIPTS_DIR="${REPO_ROOT}/scripts"
FETCHER_VERSION=1
USER_AGENT="tillandsias-cheatsheet-fetcher/${FETCHER_VERSION} (+https://github.com/8007342/tillandsias)"

# CACHE_DIR for bundled-tier bake output. Defaults to XDG_CACHE_HOME or ~/.cache.
# @trace spec:cheatsheets-license-tiered
CACHE_DIR="${CACHE_DIR:-${XDG_CACHE_HOME:-${HOME}/.cache}/tillandsias}"

# ---------------------------------------------------------------------------
# Argument parsing.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Helpers (defined early so the bundled-tier dispatch can use them).
# ---------------------------------------------------------------------------

die() {
    echo "error: $*" >&2
    exit 1
}

info() {
    echo "  $*"
}

# ---------------------------------------------------------------------------
# Bundled-tier mode helpers.
# @trace spec:cheatsheets-license-tiered
# ---------------------------------------------------------------------------

# Parse YAML frontmatter from a markdown file, emitting key=value lines for
# scalar fields and key+=item lines for list items. POSIX-friendly: uses
# Python because the cheatsheets repo already requires python3 elsewhere.
parse_frontmatter() {
    local md_file="$1"
    python3 - "${md_file}" <<'PYEOF'
import sys, re

path = sys.argv[1]
with open(path) as f:
    text = f.read()

# Frontmatter is the block between the first two "---" lines.
m = re.match(r'^---\n(.*?)\n---\n', text, re.DOTALL)
if not m:
    sys.exit(0)
fm = m.group(1)

# Very small YAML subset: scalar `key: value` and `key:\n  - item\n  - item`.
current_list_key = None
for line in fm.splitlines():
    if not line.strip() or line.lstrip().startswith('#'):
        continue
    # List item under the most-recent list key.
    m = re.match(r'^\s+-\s+(.*)$', line)
    if m and current_list_key:
        item = m.group(1).strip().strip('"').strip("'")
        print(f"{current_list_key}+={item}")
        continue
    # `key: value` or `key:`
    m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*)$', line)
    if m:
        key = m.group(1)
        value = m.group(2).strip()
        if value == '' or value == '|' or value == '>':
            current_list_key = key
        else:
            current_list_key = None
            value = value.strip('"').strip("'")
            print(f"{key}={value}")
PYEOF
}

# Returns 0 if the cheatsheet's frontmatter declares tier: bundled.
is_bundled_tier() {
    local md_file="$1"
    parse_frontmatter "${md_file}" | grep -qE '^tier=bundled$'
}

# Emit one URL per line for the cheatsheet's source URLs. Prefers the v2 spec
# field `source_urls`, falls back to the v1 legacy field `sources`.
extract_source_urls() {
    local md_file="$1"
    local fm
    fm="$(parse_frontmatter "${md_file}")"
    local urls
    urls="$(printf '%s\n' "${fm}" | sed -n 's/^source_urls+=//p')"
    if [[ -z "${urls}" ]]; then
        urls="$(printf '%s\n' "${fm}" | sed -n 's/^sources+=//p')"
    fi
    # Filter to https:// (the fetcher rejects everything else).
    printf '%s\n' "${urls}" | grep -E '^https://' || true
}

# Compute the bundled-tier cache key:
#   SHA-256( "\n".join(sorted(unique_urls)) + "\n" + "max-age-days=N" )[:16]
# Same URL set + same N → same key → directory reuse → no re-fetch.
# @trace spec:cheatsheets-license-tiered
bundled_cache_key() {
    local max_age="${1:-unset}"
    shift || true
    local urls=("$@")
    {
        printf '%s\n' "${urls[@]}" | sort -u
        printf 'max-age-days=%s\n' "${max_age}"
    } | sha256sum | awk '{print substr($1,1,16)}'
}

# Compute the structural-drift fingerprint for an HTML file:
# SHA-256( "\n".join(text_of_all_h1_h2_h3_in_doc_order) )[:16].
# Uses htmlq if present; otherwise a self-contained Python html.parser helper.
# Non-HTML inputs print "n/a" and return 0.
# @trace spec:cheatsheets-license-tiered
structural_drift_fingerprint() {
    local file="$1"
    local content_type="${2:-}"

    # Fast bail for non-HTML.
    case "${content_type}" in
        text/html*|application/xhtml*) ;;
        '')
            # Sniff: only treat as HTML if file contains an opening <html or <body tag.
            if ! head -c 8192 "${file}" 2>/dev/null | grep -qiE '<(html|body|h1|h2|h3)'; then
                echo "n/a"
                return 0
            fi
            ;;
        *)
            echo "n/a"
            return 0
            ;;
    esac

    if command -v htmlq >/dev/null 2>&1; then
        local headings
        headings="$(htmlq -t 'h1, h2, h3' < "${file}" 2>/dev/null || true)"
        if [[ -z "${headings}" ]]; then
            echo "n/a"
            return 0
        fi
        printf '%s' "${headings}" | sha256sum | awk '{print substr($1,1,16)}'
        return 0
    fi

    # Fallback: tiny Python html.parser helper.
    python3 - "${file}" <<'PYEOF'
import sys, hashlib
from html.parser import HTMLParser

class HeadingExtractor(HTMLParser):
    def __init__(self):
        super().__init__()
        self.in_heading = False
        self.parts = []
        self.current = []
    def handle_starttag(self, tag, attrs):
        if tag in ('h1','h2','h3'):
            self.in_heading = True
            self.current = []
    def handle_endtag(self, tag):
        if tag in ('h1','h2','h3') and self.in_heading:
            self.in_heading = False
            txt = ''.join(self.current).strip()
            if txt:
                self.parts.append(txt)
            self.current = []
    def handle_data(self, data):
        if self.in_heading:
            self.current.append(data)

with open(sys.argv[1], 'rb') as f:
    raw = f.read()
try:
    text = raw.decode('utf-8', errors='replace')
except Exception:
    print("n/a"); sys.exit(0)

p = HeadingExtractor()
try:
    p.feed(text)
except Exception:
    print("n/a"); sys.exit(0)

if not p.parts:
    print("n/a")
else:
    h = hashlib.sha256("\n".join(p.parts).encode("utf-8")).hexdigest()
    print(h[:16])
PYEOF
}

# Append (or update) `structural_drift_fingerprint:` in a sidecar .meta.yaml.
# @trace spec:cheatsheets-license-tiered
sidecar_set_fingerprint() {
    local sidecar="$1"
    local fingerprint="$2"
    [[ -f "${sidecar}" ]] || return 0
    if grep -q '^structural_drift_fingerprint:' "${sidecar}"; then
        # Replace existing line (portable sed; no -i delimiter quirks).
        local tmp
        tmp="$(mktemp)"
        awk -v fp="${fingerprint}" '
            /^structural_drift_fingerprint:/ { print "structural_drift_fingerprint: " fp; next }
            { print }
        ' "${sidecar}" >"${tmp}"
        mv "${tmp}" "${sidecar}"
    else
        printf 'structural_drift_fingerprint: %s\n' "${fingerprint}" >>"${sidecar}"
    fi
}

# Bundled-tier main entry point — invoked from the dispatch block above.
# @trace spec:cheatsheets-license-tiered
bundled_tier_main() {
    local cheatsheets_dir="${REPO_ROOT}/cheatsheets"
    if [[ ! -d "${cheatsheets_dir}" ]]; then
        die "cheatsheets/ directory not found at ${cheatsheets_dir}"
    fi

    info "scanning ${cheatsheets_dir} for tier: bundled cheatsheets"

    local bundled_files=()
    local md_file
    while IFS= read -r -d '' md_file; do
        if is_bundled_tier "${md_file}"; then
            bundled_files+=("${md_file}")
        fi
    done < <(find "${cheatsheets_dir}" -type f -name '*.md' -print0)

    if [[ "${#bundled_files[@]}" -eq 0 ]]; then
        info "no tier: bundled cheatsheets found"
        echo "key="
        echo "dir="
        return 0
    fi

    info "found ${#bundled_files[@]} bundled cheatsheet(s)"

    # Collect the union of source URLs across all bundled cheatsheets.
    local all_urls=()
    local urls_for_file=()
    declare -A FILE_URLS  # file path → newline-joined urls for later iteration
    for md_file in "${bundled_files[@]}"; do
        urls_for_file=()
        local url
        while IFS= read -r url; do
            [[ -z "${url}" ]] && continue
            all_urls+=("${url}")
            urls_for_file+=("${url}")
        done < <(extract_source_urls "${md_file}")
        FILE_URLS["${md_file}"]="$(printf '%s\n' "${urls_for_file[@]:-}")"
    done

    if [[ "${#all_urls[@]}" -eq 0 ]]; then
        info "warning: no source URLs found across bundled cheatsheets"
        echo "key="
        echo "dir="
        return 0
    fi

    # Compute cache key.
    local key
    key="$(bundled_cache_key "${MAX_AGE_DAYS:-unset}" "${all_urls[@]}")"
    local key_dir="${CACHE_DIR}/cheatsheet-source-bake/${key}"

    info "cache key: ${key}"
    info "cache dir: ${key_dir}"

    if [[ "${DRY_RUN}" -eq 1 ]]; then
        info "[dry-run] would fetch the following URLs:"
        printf '%s\n' "${all_urls[@]}" | sort -u | while read -r u; do
            info "  ${u}"
        done
        # Still emit the key + dir so callers can use them in dry-run mode.
        echo "key=${key}"
        echo "dir=${key_dir}"
        return 0
    fi

    mkdir -p "${key_dir}"

    # Re-invoke this script for each URL with CHEATSHEET_SOURCES_DIR pointed
    # at the cache-key directory. This reuses every existing fetch path
    # (GitHub-blob rewrite, IETF .txt preference, allowlist lookup, sidecar
    # writing) without duplicating the logic.
    local self="${BASH_SOURCE[0]}"
    local fetched=0
    local failed=0
    local skipped=0

    # Track URLs we've already fetched in this run (the same URL may be cited
    # by multiple cheatsheets but we only fetch once per cache-key directory).
    declare -A SEEN_URL
    for md_file in "${bundled_files[@]}"; do
        local file_urls="${FILE_URLS[${md_file}]}"
        while IFS= read -r url; do
            [[ -z "${url}" ]] && continue
            if [[ -n "${SEEN_URL[${url}]:-}" ]]; then
                continue
            fi
            SEEN_URL["${url}"]=1
            info "[${fetched}/${#all_urls[@]}] ${url} (cited by ${md_file#${REPO_ROOT}/})"
            if CHEATSHEET_SOURCES_DIR="${key_dir}" \
                "${self}" "${url}" --manual-review >/dev/null 2>&1; then
                fetched=$(( fetched + 1 ))
                # Compute fingerprint over the just-fetched file.
                # Find the produced file (path mirrors URL host structure).
                local host_part="${url#https://}"
                local host="${host_part%%/*}"
                local path_part="${host_part#${host}}"
                path_part="${path_part%\?*}"
                path_part="${path_part%#*}"
                path_part="${path_part%/}"
                [[ -z "${path_part}" || "${path_part}" == "/" ]] && path_part="/index.html"
                local produced="${key_dir}/${host}${path_part}"
                local sidecar=""
                if [[ -f "${produced}.meta.yaml" ]]; then
                    sidecar="${produced}.meta.yaml"
                elif [[ -f "${produced}.norepublish.meta.yaml" ]]; then
                    sidecar="${produced}.norepublish.meta.yaml"
                    produced="${produced}.norepublish"
                fi
                if [[ -n "${sidecar}" && -f "${produced}" ]]; then
                    local ctype=""
                    ctype="$(grep '^content_type:' "${sidecar}" | cut -d' ' -f2- || true)"
                    local fp
                    fp="$(structural_drift_fingerprint "${produced}" "${ctype}")"
                    sidecar_set_fingerprint "${sidecar}" "${fp}"
                    info "  fingerprint: ${fp}"
                fi
            else
                failed=$(( failed + 1 ))
                info "  warning: fetch failed for ${url} (continuing)"
            fi
        done <<< "${file_urls}"
    done

    info "bundled-tier bake complete: fetched=${fetched} failed=${failed} skipped=${skipped}"
    echo "key=${key}"
    echo "dir=${key_dir}"
}

URL=""
CITE_PATH=""
MANUAL_REVIEW=0
FORCE=0
TIER_MODE=""              # "" or "bundled" — @trace spec:cheatsheets-license-tiered
MAX_AGE_DAYS=""           # cache-key input for bundled mode
DRY_RUN=0                 # bundled mode only: list, do not fetch

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cite)
            shift
            CITE_PATH="${1:-}"
            if [[ -z "${CITE_PATH}" ]]; then
                echo "error: --cite requires a path argument" >&2
                exit 2
            fi
            ;;
        --manual-review)
            MANUAL_REVIEW=1
            ;;
        --force)
            FORCE=1
            ;;
        --canonicalize)
            # Reserved for chunk 2; silently accepted.
            ;;
        --tier=*)
            # @trace spec:cheatsheets-license-tiered
            TIER_MODE="${1#--tier=}"
            if [[ "${TIER_MODE}" != "bundled" ]]; then
                echo "error: --tier=${TIER_MODE} not supported (only 'bundled' for now)" >&2
                exit 2
            fi
            ;;
        --max-age-days)
            # @trace spec:cheatsheets-license-tiered
            shift
            MAX_AGE_DAYS="${1:-}"
            if [[ -z "${MAX_AGE_DAYS}" ]]; then
                echo "error: --max-age-days requires a numeric argument" >&2
                exit 2
            fi
            ;;
        --max-age-days=*)
            # @trace spec:cheatsheets-license-tiered
            MAX_AGE_DAYS="${1#--max-age-days=}"
            ;;
        --dry-run)
            # @trace spec:cheatsheets-license-tiered
            DRY_RUN=1
            ;;
        --*)
            echo "error: unknown option: $1" >&2
            exit 2
            ;;
        *)
            if [[ -z "${URL}" ]]; then
                URL="$1"
            else
                echo "error: unexpected argument: $1" >&2
                exit 2
            fi
            ;;
    esac
    shift
done

# Bundled-tier dispatch: takes over the script's main flow.
# @trace spec:cheatsheets-license-tiered
if [[ -n "${TIER_MODE}" ]]; then
    if [[ -n "${URL}" ]]; then
        echo "error: --tier=${TIER_MODE} does not accept a positional URL argument" >&2
        exit 2
    fi
    bundled_tier_main
    exit 0
fi

if [[ -z "${URL}" ]]; then
    echo "usage: $(basename "$0") <URL> [--cite cheatsheets/<path>] [--manual-review] [--force]" >&2
    echo "   or: $(basename "$0") --tier=bundled [--max-age-days N] [--dry-run]" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# URL validation — https only.
# (die / info helpers defined above so the bundled-tier dispatch can use them.)
# ---------------------------------------------------------------------------

if [[ "${URL}" != https://* ]]; then
    die "only https:// URLs are allowed (got: ${URL})"
fi

# Strip the scheme for path computation.
URL_NO_SCHEME="${URL#https://}"
# Extract host (everything up to the first / or end of string).
RAW_HOST="${URL_NO_SCHEME%%/*}"
# The path portion (everything after the host).
URL_PATH="${URL_NO_SCHEME#${RAW_HOST}}"

# ---------------------------------------------------------------------------
# GitHub blob → raw rewrite.
# ---------------------------------------------------------------------------
#
# https://github.com/ollama/ollama/blob/main/docs/api.md
# → https://raw.githubusercontent.com/ollama/ollama/main/docs/api.md

ORIGINAL_URL="${URL}"
if [[ "${RAW_HOST}" == "github.com" && "${URL_PATH}" == */blob/* ]]; then
    # Replace host + /blob/ with raw.githubusercontent.com (no /blob/).
    RAW_PATH="${URL_PATH/\/blob\//\/}"
    URL="https://raw.githubusercontent.com${RAW_PATH}"
    URL_NO_SCHEME="${URL#https://}"
    RAW_HOST="${URL_NO_SCHEME%%/*}"
    URL_PATH="${URL_NO_SCHEME#${RAW_HOST}}"
    info "GitHub blob → raw rewrite: ${URL}"
fi

# ---------------------------------------------------------------------------
# Allowlist lookup.
# The TOML key is the longest matching prefix of "<host>[<path-prefix>]".
# We try the most-specific match first (host + path prefix), then host-only.
# ---------------------------------------------------------------------------

lookup_allowlist() {
    local host="$1" path="$2"
    # Build a series of candidates from most-specific to least-specific.
    # e.g. raw.githubusercontent.com/ollama/ollama, raw.githubusercontent.com
    local candidates=()
    local parts
    IFS='/' read -ra parts <<< "${host}${path}"
    local accumulated=""
    for part in "${parts[@]}"; do
        if [[ -n "${accumulated}" ]]; then
            accumulated="${accumulated}/${part}"
        else
            accumulated="${part}"
        fi
        candidates+=("${accumulated}")
    done

    # Reverse for most-specific-first.
    local reversed=()
    for (( i=${#candidates[@]}-1 ; i>=0 ; i-- )); do
        reversed+=("${candidates[i]}")
    done

    # Search the TOML for each candidate key.
    # TOML key format: [domains."<key>"]
    for candidate in "${reversed[@]}"; do
        if grep -qF "[domains.\"${candidate}\"]" "${ALLOWLIST}" 2>/dev/null; then
            # Extract publisher, license, redistribution from the following lines.
            python3 - "${ALLOWLIST}" "${candidate}" <<'PYEOF'
import sys, re

allowlist_path = sys.argv[1]
key = sys.argv[2]

with open(allowlist_path) as f:
    content = f.read()

# Find the section header and extract fields until the next [
pattern = re.compile(
    r'\[domains\."' + re.escape(key) + r'"\]\n(.*?)(?=\n\[|\Z)',
    re.DOTALL
)
m = pattern.search(content)
if not m:
    sys.exit(1)

section = m.group(1)
fields = {}
for line in section.splitlines():
    line = line.strip()
    if '=' in line and not line.startswith('#'):
        k, _, v = line.partition('=')
        v = v.strip().strip('"')
        fields[k.strip()] = v

print(fields.get('publisher', ''))
print(fields.get('license', ''))
print(fields.get('redistribution', 'do-not-bundle'))
print(fields.get('license_url', ''))
PYEOF
            return 0
        fi
    done
    return 1
}

PUBLISHER=""
LICENSE=""
REDISTRIBUTION=""
LICENSE_URL=""
ALLOWLIST_MATCH=""

if [[ -f "${ALLOWLIST}" ]]; then
    # Try progressively shorter path prefixes.
    match_path="${URL_PATH}"
    found=0
    # First try host+path combos, then host alone.
    for depth in 3 2 1 0; do
        # Build candidate: host + first $depth path segments.
        candidate="${RAW_HOST}"
        if [[ "${depth}" -gt 0 && -n "${URL_PATH}" ]]; then
            path_parts_tmp="${URL_PATH#/}"
            seg_count=0
            seg_accum=""
            while IFS='/' read -r seg && [[ "${seg_count}" -lt "${depth}" ]]; do
                [[ -z "${seg}" ]] && continue
                if [[ -n "${seg_accum}" ]]; then
                    seg_accum="${seg_accum}/${seg}"
                else
                    seg_accum="${seg}"
                fi
                (( seg_count++ )) || true
            done < <(tr '/' '\n' <<< "${path_parts_tmp}")
            if [[ -n "${seg_accum}" ]]; then
                candidate="${RAW_HOST}/${seg_accum}"
            fi
        fi
        if grep -qF "[domains.\"${candidate}\"]" "${ALLOWLIST}" 2>/dev/null; then
            # Read each field on its own line to preserve spaces (e.g. "IETF / RFC Editor").
            TMP_FIELDS="$(python3 - "${ALLOWLIST}" "${candidate}" <<'PYEOF'
import sys, re

allowlist_path = sys.argv[1]
key = sys.argv[2]

with open(allowlist_path) as f:
    content = f.read()

pattern = re.compile(
    r'\[domains\."' + re.escape(key) + r'"\]\n(.*?)(?=\n\[|\Z)',
    re.DOTALL
)
m = pattern.search(content)
if not m:
    sys.exit(1)

section = m.group(1)
fields = {}
for line in section.splitlines():
    line = line.strip()
    if '=' in line and not line.startswith('#'):
        k, _, v = line.partition('=')
        v = v.strip().strip('"')
        fields[k.strip()] = v

# Output one value per line in a fixed order; empty line if missing.
print(fields.get('publisher', ''))
print(fields.get('license', ''))
print(fields.get('redistribution', 'do-not-bundle'))
print(fields.get('license_url', ''))
PYEOF
            )" || true
            if [[ -n "${TMP_FIELDS}" ]]; then
                PUBLISHER="$(printf '%s' "${TMP_FIELDS}" | sed -n '1p')"
                LICENSE="$(printf '%s' "${TMP_FIELDS}" | sed -n '2p')"
                REDISTRIBUTION="$(printf '%s' "${TMP_FIELDS}" | sed -n '3p')"
                LICENSE_URL="$(printf '%s' "${TMP_FIELDS}" | sed -n '4p')"
            fi
            ALLOWLIST_MATCH="${candidate}"
            found=1
            break
        fi
    done

    if [[ "${found}" -eq 0 ]]; then
        if [[ "${MANUAL_REVIEW}" -eq 0 ]]; then
            die "host '${RAW_HOST}' is not in the license allowlist.
Pass --manual-review to fetch anyway (redistribution will be marked 'manual-review-required').
Add the domain to ${ALLOWLIST} to suppress this warning."
        fi
        PUBLISHER="unknown"
        LICENSE="unknown"
        REDISTRIBUTION="manual-review-required"
        LICENSE_URL=""
        ALLOWLIST_MATCH=""
        info "warning: domain not in allowlist; proceeding with --manual-review"
    fi
else
    die "allowlist not found at ${ALLOWLIST}"
fi

# ---------------------------------------------------------------------------
# Determine URL candidates to try — RFC .txt preference, single-page variants.
# ---------------------------------------------------------------------------

build_url_candidates() {
    local base_url="$1"
    local candidates=()

    # RFC: prefer .txt over .html (only rewrite if URL ends in .html/.htm, not already .txt)
    if [[ "${RAW_HOST}" == *"rfc-editor.org"* || "${RAW_HOST}" == *"ietf.org"* ]]; then
        if [[ "${base_url}" == *.html || "${base_url}" == *.htm ]]; then
            local txt_url
            txt_url="${base_url%.html}.txt"
            txt_url="${txt_url%.htm}.txt"
            candidates+=("${txt_url}")
        fi
        # If already .txt, it goes directly into the candidates list below as the base URL.
    fi

    # The URL as given.
    candidates+=("${base_url}")

    # Single-page variants (try in order; skip if already tried).
    local seen=()
    local final=()
    for u in "${candidates[@]}"; do
        local already=0
        for s in "${seen[@]:-}"; do
            [[ "${s}" == "${u}" ]] && already=1 && break
        done
        if [[ "${already}" -eq 0 ]]; then
            final+=("${u}")
            seen+=("${u}")
        fi
    done

    # Now add single-page variants for the base URL.
    local base_stripped
    base_stripped="${base_url%\?*}"  # strip existing query
    for variant in "${base_stripped}?print=1" "${base_stripped%/}/print/" "${base_stripped%/}/single-page/"; do
        local already=0
        for s in "${seen[@]:-}"; do
            [[ "${s}" == "${variant}" ]] && already=1 && break
        done
        if [[ "${already}" -eq 0 ]]; then
            final+=("${variant}")
            seen+=("${variant}")
        fi
    done

    printf '%s\n' "${final[@]}"
}

# ---------------------------------------------------------------------------
# Compute deterministic on-disk path from URL.
# Format: cheatsheet-sources/<host>/<path>/<basename>.<ext>
# ---------------------------------------------------------------------------

compute_dest_path() {
    local url="$1"
    local u_no_scheme="${url#https://}"
    local host="${u_no_scheme%%/*}"
    local path="${u_no_scheme#${host}}"

    # Remove query string for path computation.
    path="${path%\?*}"
    # Remove fragment (do this before trailing-slash strip so that
    # URLs like /foo/bar/#section → /foo/bar/ → /foo/bar are handled correctly).
    path="${path%#*}"
    # Remove trailing slash (after fragment strip, a fragment-anchored URL like
    # /regex/latest/regex/#syntax leaves /regex/latest/regex/ after fragment removal).
    path="${path%/}"

    if [[ -z "${path}" || "${path}" == "/" ]]; then
        path="/index.html"
    fi

    echo "${SOURCES_DIR}/${host}${path}"
}

DEST_PATH="$(compute_dest_path "${URL}")"
DEST_DIR="$(dirname "${DEST_PATH}")"

# ---------------------------------------------------------------------------
# Check if we already have this file (and --force not set).
# ---------------------------------------------------------------------------

if [[ -f "${DEST_PATH}" || -f "${DEST_PATH}.norepublish" ]] && [[ "${FORCE}" -eq 0 ]]; then
    info "already fetched: ${DEST_PATH} (use --force to re-fetch)"
    # Still re-run the --cite and index steps.
    SKIP_FETCH=1
else
    SKIP_FETCH=0
fi

# ---------------------------------------------------------------------------
# Fetch step.
# ---------------------------------------------------------------------------

FETCH_URL="${URL}"
FINAL_URL="${URL}"
HTTP_STATUS=0
CONTENT_TYPE=""

if [[ "${SKIP_FETCH}" -eq 0 ]]; then
    echo "fetching: ${URL}"

    TMP_BODY="$(mktemp)"
    TMP_HEADERS="$(mktemp)"
    trap 'rm -f "${TMP_BODY}" "${TMP_HEADERS}"' EXIT

    # Try URL candidates in order.
    TRIED_URLS=()
    mapfile -t URL_CANDIDATES < <(build_url_candidates "${URL}")

    for candidate_url in "${URL_CANDIDATES[@]}"; do
        TRIED_URLS+=("${candidate_url}")
        info "trying: ${candidate_url}"

        # Use curl's write-out to capture metadata.
        HTTP_STATUS="$(curl \
            -L \
            --proto '=https' \
            --tlsv1.2 \
            -A "${USER_AGENT}" \
            --max-time 60 \
            --connect-timeout 15 \
            --max-redirs 5 \
            --write-out '%{http_code}\n%{url_effective}\n%{content_type}' \
            --silent \
            --output "${TMP_BODY}" \
            --dump-header "${TMP_HEADERS}" \
            "${candidate_url}" 2>&1)" || {
                info "curl failed for ${candidate_url}; trying next"
                continue
            }

        # write-out emits 3 trailing lines: http_code, url_effective, content_type.
        # Split them from the status output.
        STATUS_LINE="$(printf '%s' "${HTTP_STATUS}" | tail -n3 | head -n1)"
        EFFECTIVE_URL="$(printf '%s' "${HTTP_STATUS}" | tail -n2 | head -n1)"
        CONTENT_TYPE="$(printf '%s' "${HTTP_STATUS}" | tail -n1)"
        HTTP_STATUS="${STATUS_LINE}"

        if [[ "${HTTP_STATUS}" == "200" ]] && [[ -s "${TMP_BODY}" ]]; then
            FETCH_URL="${candidate_url}"
            FINAL_URL="${EFFECTIVE_URL}"
            info "fetched ${HTTP_STATUS}: ${FINAL_URL} ($(wc -c <"${TMP_BODY}") bytes)"
            break
        else
            info "  → HTTP ${HTTP_STATUS} or empty body; trying next"
        fi
    done

    if [[ "${HTTP_STATUS}" != "200" ]] || [[ ! -s "${TMP_BODY}" ]]; then
        die "all URL candidates failed or returned empty body for ${URL}
Tried: ${TRIED_URLS[*]:-}"
    fi

    # Recompute dest for the URL that actually succeeded (e.g. .txt vs .html).
    DEST_PATH="$(compute_dest_path "${FETCH_URL}")"
    DEST_DIR="$(dirname "${DEST_PATH}")"

    mkdir -p "${DEST_DIR}"

    # If redistribution=do-not-bundle, suffix with .norepublish.
    if [[ "${REDISTRIBUTION}" == "do-not-bundle" || "${REDISTRIBUTION}" == "manual-review-required" ]]; then
        DEST_PATH="${DEST_PATH}.norepublish"
    fi

    cp "${TMP_BODY}" "${DEST_PATH}"
    info "stored: ${DEST_PATH}"
else
    # Even in skip-fetch mode, figure out the actual file on disk.
    if [[ -f "${DEST_PATH}.norepublish" ]]; then
        DEST_PATH="${DEST_PATH}.norepublish"
    fi
    FETCH_URL="${URL}"
    FINAL_URL="${URL}"
    # Read existing metadata if available.
    if [[ -f "${DEST_PATH}.meta.yaml" ]]; then
        HTTP_STATUS="$(grep '^http_status:' "${DEST_PATH}.meta.yaml" | awk '{print $2}' || echo 200)"
        CONTENT_TYPE="$(grep '^content_type:' "${DEST_PATH}.meta.yaml" | cut -d' ' -f2- | xargs || echo "")"
    else
        HTTP_STATUS=200
        CONTENT_TYPE=""
    fi
fi

# ---------------------------------------------------------------------------
# SHA-256 the stored bytes.
# ---------------------------------------------------------------------------

CONTENT_SHA256=""
CONTENT_LENGTH=0
if [[ -f "${DEST_PATH}" ]]; then
    CONTENT_SHA256="$(sha256sum "${DEST_PATH}" | awk '{print $1}')"
    CONTENT_LENGTH="$(wc -c <"${DEST_PATH}")"
fi

# ---------------------------------------------------------------------------
# Write .meta.yaml sidecar (always alongside the verbatim file).
# ---------------------------------------------------------------------------

FETCH_TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

META_PATH="${DEST_PATH}.meta.yaml"

# Read existing cited_by if sidecar already exists (idempotent).
EXISTING_CITED_BY=""
if [[ -f "${META_PATH}" ]]; then
    # Extract cited_by block (multi-line YAML list).
    EXISTING_CITED_BY="$(python3 - "${META_PATH}" <<'PYEOF'
import sys, re
with open(sys.argv[1]) as f:
    content = f.read()
m = re.search(r'^cited_by:\n((?:  - .+\n)*)', content, re.MULTILINE)
if m:
    items = re.findall(r'  - (.+)', m.group(1))
    print('\n'.join(items))
PYEOF
)" || true
fi

# Merge new cite path if provided.
NEW_CITED_BY_LIST=()
if [[ -n "${EXISTING_CITED_BY}" ]]; then
    while IFS= read -r line; do
        [[ -n "${line}" ]] && NEW_CITED_BY_LIST+=("${line}")
    done <<< "${EXISTING_CITED_BY}"
fi

if [[ -n "${CITE_PATH}" ]]; then
    # Normalise to repo-relative form.
    CITE_NORM="${CITE_PATH#${REPO_ROOT}/}"
    already_cited=0
    for existing in "${NEW_CITED_BY_LIST[@]:-}"; do
        [[ "${existing}" == "${CITE_NORM}" ]] && already_cited=1 && break
    done
    if [[ "${already_cited}" -eq 0 ]]; then
        NEW_CITED_BY_LIST+=("${CITE_NORM}")
    fi
fi

# Build YAML cited_by block.
CITED_BY_YAML="cited_by:"
if [[ "${#NEW_CITED_BY_LIST[@]}" -gt 0 ]]; then
    for item in "${NEW_CITED_BY_LIST[@]}"; do
        CITED_BY_YAML="${CITED_BY_YAML}
  - ${item}"
    done
else
    CITED_BY_YAML="${CITED_BY_YAML}
  []"
fi

# Determine render type.
RENDER="static"
if [[ "${DEST_PATH}" == *.norepublish ]]; then
    RENDER="static"
fi

# local_path relative to repo root.
LOCAL_PATH="${DEST_PATH#${REPO_ROOT}/}"

cat >"${META_PATH}" <<METAEOF
url: ${ORIGINAL_URL}
fetch_url: ${FETCH_URL}
final_redirect: ${FINAL_URL}
fetched: ${FETCH_TS}
fetcher_version: ${FETCHER_VERSION}
content_sha256: ${CONTENT_SHA256}
content_length: ${CONTENT_LENGTH}
content_type: ${CONTENT_TYPE}
http_status: ${HTTP_STATUS}
publisher: ${PUBLISHER}
license: ${LICENSE}
license_url: ${LICENSE_URL}
redistribution: ${REDISTRIBUTION}
allowlist_match: ${ALLOWLIST_MATCH}
render: ${RENDER}
local_path: ${LOCAL_PATH}
${CITED_BY_YAML}
notes: ""
METAEOF

info "sidecar: ${META_PATH}"

# ---------------------------------------------------------------------------
# --cite: append local: line to the cheatsheet's ## Provenance section.
# ---------------------------------------------------------------------------

if [[ -n "${CITE_PATH}" ]]; then
    # Resolve path.
    if [[ "${CITE_PATH}" == /* ]]; then
        CHEATSHEET_ABS="${CITE_PATH}"
    elif [[ "${CITE_PATH}" == cheatsheets/* ]]; then
        CHEATSHEET_ABS="${REPO_ROOT}/${CITE_PATH}"
    else
        CHEATSHEET_ABS="${REPO_ROOT}/cheatsheets/${CITE_PATH}"
    fi

    if [[ ! -f "${CHEATSHEET_ABS}" ]]; then
        echo "warning: cheatsheet not found at ${CHEATSHEET_ABS}; skipping --cite" >&2
    else
        LOCAL_CITE_PATH="${DEST_PATH#${REPO_ROOT}/}"
        SOURCE_URL="${FETCH_URL}"

        # Check if the local: line is already present (idempotent).
        if grep -qF "local: \`${LOCAL_CITE_PATH}" "${CHEATSHEET_ABS}" 2>/dev/null; then
            info "already cited in ${CHEATSHEET_ABS}"
        else
            # We need to insert the local: line after the matching URL line in
            # ## Provenance, or append before the "**Last updated:**" line.
            python3 - "${CHEATSHEET_ABS}" "${SOURCE_URL}" "${ORIGINAL_URL}" "${LOCAL_CITE_PATH}" "${LICENSE}" "${PUBLISHER}" <<'PYEOF'
import sys, re

cheatsheet_path = sys.argv[1]
source_url = sys.argv[2]
original_url = sys.argv[3]
local_path = sys.argv[4]
license_str = sys.argv[5]
publisher = sys.argv[6]

with open(cheatsheet_path) as f:
    content = f.read()

local_line = f"  local: `{local_path}`"
# License and publisher are recorded in the sidecar (.meta.yaml) — not duplicated inline.

# Strategy: find the URL reference (both source_url and original_url),
# insert the local: line after the line containing it (if not already present).
# If neither found, append before **Last updated:** in ## Provenance.

inserted = False
lines = content.splitlines(keepends=True)
new_lines = []

# Check if local_line already present
if any(f"local: `{local_path}`" in line for line in lines):
    print(content, end='')
    sys.exit(0)

# Try to find the URL in the provenance section.
in_provenance = False
for i, line in enumerate(lines):
    new_lines.append(line)
    if re.match(r'^##\s+Provenance', line):
        in_provenance = True
        continue
    if in_provenance and re.match(r'^##\s+', line):
        in_provenance = False
        continue
    if in_provenance and not inserted:
        stripped = line.strip()
        # Match lines containing either the fetch URL or the original URL.
        if source_url in stripped or original_url in stripped:
            # Insert local: line after this line.
            new_lines.append(local_line + "\n")
            inserted = True

if not inserted and in_provenance:
    # Provenance section was last; append before **Last updated:**.
    out = []
    for line in new_lines:
        if '**Last updated:**' in line and not inserted:
            out.append(local_line + "\n")
            inserted = True
        out.append(line)
    new_lines = out

if not inserted:
    # Fallback: append before **Last updated:** anywhere in provenance.
    out = []
    in_prov = False
    for line in new_lines:
        if re.match(r'^##\s+Provenance', line):
            in_prov = True
        if in_prov and '**Last updated:**' in line and not inserted:
            out.append(local_line + "\n")
            inserted = True
        out.append(line)
    new_lines = out

with open(cheatsheet_path, 'w') as f:
    f.write(''.join(new_lines))

if inserted:
    print(f"  → inserted local: line into {cheatsheet_path}", file=sys.stderr)
else:
    print(f"  warning: could not find insertion point in {cheatsheet_path}; please add manually:", file=sys.stderr)
    print(f"  {local_line}", file=sys.stderr)
PYEOF
            info "updated provenance in: ${CHEATSHEET_ABS}"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Regenerate INDEX.json.
# ---------------------------------------------------------------------------

if [[ -x "${SCRIPTS_DIR}/regenerate-source-index.sh" ]]; then
    "${SCRIPTS_DIR}/regenerate-source-index.sh"
else
    info "warning: regenerate-source-index.sh not found or not executable; INDEX.json not updated"
fi

echo "done: ${URL}"
