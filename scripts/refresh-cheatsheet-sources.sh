#!/usr/bin/env bash

# @tombstone obsolete:cheatsheet-source-layer
# @trace spec:cheatsheets-license-tiered, spec:cheatsheet-source-layer
#
# This script is RETIRED. superseded; refresh moves to build-time --refresh-sources for bundled tier and agent-driven materialization for pull-on-demand.
# The legacy body below is preserved for traceability through the three-release
# retention window (final removal in 0.1.<N+3>.x per CLAUDE.md @tombstone discipline).
# Calling this script now exits early with a notice — it does NOT execute the legacy logic.
echo "[$(basename "$0")] @tombstone obsolete:cheatsheet-source-layer — script is retired." >&2
echo "  Reason: superseded; refresh moves to build-time --refresh-sources for bundled tier and agent-driven materialization for pull-on-demand" >&2
echo "  See openspec/changes/cheatsheets-license-tiered/ for the replacement." >&2
exit 0

# refresh-cheatsheet-sources.sh — drift detection for the cheatsheet-source layer.
#
# Usage:
#   scripts/refresh-cheatsheet-sources.sh [--max-age-days N]
#   scripts/refresh-cheatsheet-sources.sh --dry-run [--max-age-days N]
#
# Walks all cheatsheet-sources/**/*.meta.yaml sidecars. For each entry:
#   1. Checks age: if older than --max-age-days (default 90), marks as STALE.
#   2. Re-fetches the URL (unless --dry-run).
#   3. SHA-256 compares old vs new bytes.
#   4. If SHA differs: updates the sidecar with staleness: drift, prints a
#      diff summary line (caller must triage and update the cheatsheet).
#   5. If HTTP 404: sets staleness: gone in the sidecar and marks INDEX [STALE].
#   6. Re-runs regenerate-source-index.sh to update INDEX.json.
#
# Outputs a human-readable drift report to stdout. Exits 0 if no drift found,
# exits 1 if drift or staleness was detected (caller can decide severity).
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
SCRIPTS_DIR="${REPO_ROOT}/scripts"
MAX_AGE_DAYS=90
DRY_RUN=0
USER_AGENT="tillandsias-cheatsheet-fetcher/1 (+https://github.com/8007342/tillandsias)"

# ---------------------------------------------------------------------------
# Argument parsing.
# ---------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --max-age-days)
            shift
            MAX_AGE_DAYS="${1:-90}"
            if ! [[ "${MAX_AGE_DAYS}" =~ ^[0-9]+$ ]]; then
                echo "error: --max-age-days requires a positive integer" >&2
                exit 2
            fi
            ;;
        --dry-run)
            DRY_RUN=1
            ;;
        --*)
            echo "error: unknown option: $1" >&2
            exit 2
            ;;
        *)
            echo "error: unexpected argument: $1" >&2
            exit 2
            ;;
    esac
    shift
done

if [[ ! -d "${SOURCES_DIR}" ]]; then
    echo "warning: cheatsheet-sources directory not found at ${SOURCES_DIR}"
    echo "  Nothing to refresh."
    exit 0
fi

INDEX_FILE="${SOURCES_DIR}/INDEX.json"
if [[ ! -f "${INDEX_FILE}" ]]; then
    echo "warning: INDEX.json not found — no sources have been fetched yet"
    exit 0
fi

# ---------------------------------------------------------------------------
# Collect all .meta.yaml sidecars.
# ---------------------------------------------------------------------------

mapfile -t META_FILES < <(
    find "${SOURCES_DIR}" -name '*.meta.yaml' -type f | sort
)

if [[ "${#META_FILES[@]}" -eq 0 ]]; then
    echo "no .meta.yaml sidecars found; nothing to refresh"
    exit 0
fi

echo "refresh-cheatsheet-sources: checking ${#META_FILES[@]} source(s) (max-age: ${MAX_AGE_DAYS} days, dry-run: ${DRY_RUN})"

# ---------------------------------------------------------------------------
# Per-sidecar refresh using Python.
# ---------------------------------------------------------------------------

DRIFT_COUNT=0
STALE_AGE_COUNT=0
GONE_COUNT=0
OK_COUNT=0

NOW_TS="$(date -u +%s)"

for meta_path in "${META_FILES[@]}"; do
    verbatim_path="${meta_path%.meta.yaml}"
    rel_path="${verbatim_path#${REPO_ROOT}/}"

    # Parse key fields from the sidecar.
    fetch_url=""
    fetched_ts=""
    expected_sha=""
    redistribution=""

    while IFS= read -r line; do
        case "${line}" in
            fetch_url:*)   fetch_url="${line#fetch_url: }" ;;
            url:*)         [[ -z "${fetch_url}" ]] && fetch_url="${line#url: }" ;;
            fetched:*)     fetched_ts="${line#fetched: }" ;;
            content_sha256:*) expected_sha="${line#content_sha256: }" ;;
            redistribution:*) redistribution="${line#redistribution: }" ;;
        esac
    done <"${meta_path}"

    if [[ -z "${fetch_url}" ]]; then
        echo "  SKIP: ${rel_path} — no URL in sidecar"
        continue
    fi

    # Check age.
    age_days=0
    if [[ -n "${fetched_ts}" ]]; then
        fetched_epoch="$(date -u -d "${fetched_ts}" +%s 2>/dev/null || \
                         python3 -c "import sys,datetime; \
                           ts=sys.argv[1].rstrip('Z'); \
                           dt=datetime.datetime.fromisoformat(ts); \
                           print(int(dt.timestamp()))" "${fetched_ts}" 2>/dev/null || echo 0)"
        if [[ "${fetched_epoch}" -gt 0 ]]; then
            age_days=$(( (NOW_TS - fetched_epoch) / 86400 ))
        fi
    fi

    age_label="${age_days}d"
    stale_age=0
    if [[ "${age_days}" -gt "${MAX_AGE_DAYS}" ]]; then
        stale_age=1
        (( STALE_AGE_COUNT++ )) || true
    fi

    if [[ "${DRY_RUN}" -eq 1 ]]; then
        if [[ "${stale_age}" -eq 1 ]]; then
            echo "  STALE-AGE [${age_label}]: ${rel_path} — ${fetch_url}"
        else
            echo "  OK [${age_label}]: ${rel_path}"
            (( OK_COUNT++ )) || true
        fi
        continue
    fi

    # Skip do-not-bundle files (they have no verbatim file to compare).
    if [[ "${redistribution}" == "do-not-bundle" || "${redistribution}" == "manual-review-required" ]]; then
        echo "  SKIP (${redistribution}) [${age_label}]: ${rel_path}"
        continue
    fi

    # Re-fetch.
    TMP_REFETCH="$(mktemp)"
    trap 'rm -f "${TMP_REFETCH}"' EXIT

    HTTP_STATUS="$(curl \
        -L \
        --proto '=https' \
        --tlsv1.2 \
        -A "${USER_AGENT}" \
        --max-time 60 \
        --connect-timeout 15 \
        --silent \
        --write-out '%{http_code}' \
        --output "${TMP_REFETCH}" \
        "${fetch_url}" 2>/dev/null)" || HTTP_STATUS="error"

    if [[ "${HTTP_STATUS}" == "404" || "${HTTP_STATUS}" == "410" ]]; then
        echo "  GONE [${age_label}]: ${rel_path} → HTTP ${HTTP_STATUS}"
        # Mark sidecar as gone.
        python3 - "${meta_path}" "${HTTP_STATUS}" <<'PYEOF'
import sys, re
path, status = sys.argv[1], sys.argv[2]
with open(path) as f:
    content = f.read()
# Update http_status and add staleness field.
content = re.sub(r'^http_status: \d+', f'http_status: {status}', content, flags=re.MULTILINE)
if 'staleness:' in content:
    content = re.sub(r'^staleness: \S+', 'staleness: gone', content, flags=re.MULTILINE)
else:
    content += f'staleness: gone\n'
with open(path, 'w') as f:
    f.write(content)
PYEOF
        (( GONE_COUNT++ )) || true
        continue
    fi

    if [[ "${HTTP_STATUS}" != "200" ]]; then
        echo "  ERROR [${age_label}]: ${rel_path} → HTTP ${HTTP_STATUS} (skipping)"
        continue
    fi

    if [[ ! -s "${TMP_REFETCH}" ]]; then
        echo "  ERROR [${age_label}]: ${rel_path} → empty body (skipping)"
        continue
    fi

    NEW_SHA="$(sha256sum "${TMP_REFETCH}" | awk '{print $1}')"
    NEW_LEN="$(wc -c <"${TMP_REFETCH}")"
    NEW_TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

    if [[ "${NEW_SHA}" == "${expected_sha}" ]]; then
        echo "  OK [${age_label}]: ${rel_path} (SHA unchanged)"
        # Update fetched timestamp only.
        python3 - "${meta_path}" "${NEW_TS}" <<'PYEOF'
import sys, re
path, ts = sys.argv[1], sys.argv[2]
with open(path) as f:
    content = f.read()
content = re.sub(r'^fetched: \S+', f'fetched: {ts}', content, flags=re.MULTILINE)
if 'staleness:' in content:
    content = re.sub(r'^staleness: \S+', 'staleness: current', content, flags=re.MULTILINE)
with open(path, 'w') as f:
    f.write(content)
PYEOF
        (( OK_COUNT++ )) || true
    else
        OLD_LEN="$(wc -c <"${verbatim_path}" 2>/dev/null || echo 0)"
        echo "  DRIFT [${age_label}]: ${rel_path}"
        echo "    old SHA: ${expected_sha:0:16}... (${OLD_LEN} bytes)"
        echo "    new SHA: ${NEW_SHA:0:16}... (${NEW_LEN} bytes)"
        echo "    ACTION: review diff, update cheatsheet, re-run fetch-cheatsheet-source.sh --force"

        # Update the verbatim file and sidecar.
        cp "${TMP_REFETCH}" "${verbatim_path}"

        python3 - "${meta_path}" "${NEW_SHA}" "${NEW_LEN}" "${NEW_TS}" <<'PYEOF'
import sys, re
path, new_sha, new_len, ts = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(path) as f:
    content = f.read()
content = re.sub(r'^content_sha256: \S+', f'content_sha256: {new_sha}', content, flags=re.MULTILINE)
content = re.sub(r'^content_length: \d+', f'content_length: {new_len}', content, flags=re.MULTILINE)
content = re.sub(r'^fetched: \S+', f'fetched: {ts}', content, flags=re.MULTILINE)
content = re.sub(r'^http_status: \d+', 'http_status: 200', content, flags=re.MULTILINE)
if 'staleness:' in content:
    content = re.sub(r'^staleness: \S+', 'staleness: drift', content, flags=re.MULTILINE)
else:
    content += 'staleness: drift\n'
with open(path, 'w') as f:
    f.write(content)
PYEOF
        (( DRIFT_COUNT++ )) || true
    fi
done

# ---------------------------------------------------------------------------
# Summary + INDEX refresh.
# ---------------------------------------------------------------------------

echo ""
echo "refresh summary: ok=${OK_COUNT}, drift=${DRIFT_COUNT}, gone=${GONE_COUNT}, stale-age=${STALE_AGE_COUNT}"

if [[ "${DRY_RUN}" -eq 0 ]] && [[ -x "${SCRIPTS_DIR}/regenerate-source-index.sh" ]]; then
    "${SCRIPTS_DIR}/regenerate-source-index.sh"
fi

if [[ "${DRIFT_COUNT}" -gt 0 ]] || [[ "${GONE_COUNT}" -gt 0 ]]; then
    echo "drift or gone sources detected — review the lines marked DRIFT/GONE above"
    exit 1
fi

exit 0
