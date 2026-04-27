#!/usr/bin/env bash
# fetch-cheatsheet-source.sh — verbatim fetcher for the cheatsheet-source layer.
#
# Usage:
#   scripts/fetch-cheatsheet-source.sh <URL> [--cite cheatsheets/<path>]
#   scripts/fetch-cheatsheet-source.sh <URL> [--manual-review]
#
# Fetches the given URL verbatim, stores it under cheatsheet-sources/, writes
# a .meta.yaml sidecar, and (optionally) appends a local-source line to the
# named cheatsheet's ## Provenance section.
#
# Options:
#   --cite <path>     Append a local: line to the cheatsheet's ## Provenance
#                     section. Path must be cheatsheets/<category>/<file>.md
#   --manual-review   Allow fetching from domains not in license-allowlist.toml
#                     (redistribution will be marked "manual-review-required")
#   --force           Re-fetch even if the output file already exists
#   --canonicalize    (opt-in) strip Google Analytics and other tracker params
#                     from the stored copy (NOT implemented in chunk 1; reserved)
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
# @trace spec:cheatsheet-source-layer
# OpenSpec change: cheatsheet-source-layer

set -euo pipefail

# ---------------------------------------------------------------------------
# Locate repo root.
# ---------------------------------------------------------------------------

if ! REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi

SOURCES_DIR="${REPO_ROOT}/cheatsheet-sources"
ALLOWLIST="${SOURCES_DIR}/license-allowlist.toml"
SCRIPTS_DIR="${REPO_ROOT}/scripts"
FETCHER_VERSION=1
USER_AGENT="tillandsias-cheatsheet-fetcher/${FETCHER_VERSION} (+https://github.com/8007342/tillandsias)"

# ---------------------------------------------------------------------------
# Argument parsing.
# ---------------------------------------------------------------------------

URL=""
CITE_PATH=""
MANUAL_REVIEW=0
FORCE=0

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

if [[ -z "${URL}" ]]; then
    echo "usage: $(basename "$0") <URL> [--cite cheatsheets/<path>] [--manual-review] [--force]" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------

die() {
    echo "error: $*" >&2
    exit 1
}

info() {
    echo "  $*"
}

# ---------------------------------------------------------------------------
# URL validation — https only.
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
