#!/usr/bin/env bash
# check-cheatsheet-sources.sh — validate cheatsheet ↔ verbatim-source binding.
#
# Usage:
#   scripts/check-cheatsheet-sources.sh [--no-sha]
#
# Checks (per §5 of docs/strategy/cheatsheet-source-layer-plan.md):
#   1. For every cheatsheet's ## Provenance URL: must be in INDEX.json (ERROR if not).
#   2. For every local: path in ## Provenance: file exists OR sidecar has
#      redistribution: do-not-bundle / manual-review-required.
#   3. Orphan detection: every INDEX.json entry must be cited by at least
#      one cheatsheet (WARNING, not ERROR — new fetches may not be cited yet).
#   4. SHA-check: re-hash present files, compare to INDEX.json manifest
#      (skip with --no-sha for speed in pre-commit contexts).
#
# Exits 0 only if all ERROR-level checks pass.
# Warnings are printed but do not cause a non-zero exit.
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
CHEATSHEETS_DIR="${REPO_ROOT}/cheatsheets"
INDEX_FILE="${SOURCES_DIR}/INDEX.json"

NO_SHA=0
if [[ "${1:-}" == "--no-sha" ]]; then
    NO_SHA=1
elif [[ -n "${1:-}" ]]; then
    echo "error: unknown argument: ${1}" >&2
    echo "usage: $(basename "$0") [--no-sha]" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# Sanity: INDEX.json must exist.
# ---------------------------------------------------------------------------

if [[ ! -f "${INDEX_FILE}" ]]; then
    echo "warning: ${INDEX_FILE} does not exist — no sources fetched yet; nothing to validate"
    echo "  Run: scripts/fetch-cheatsheet-source.sh <URL> --cite cheatsheets/<path>"
    exit 0
fi

# ---------------------------------------------------------------------------
# Run validation logic in Python (handles JSON + YAML + regex in one pass).
# ---------------------------------------------------------------------------

EXIT_CODE=0

python3 - "${REPO_ROOT}" "${CHEATSHEETS_DIR}" "${SOURCES_DIR}" "${INDEX_FILE}" "${NO_SHA}" <<'PYEOF'
import sys
import os
import json
import re
import glob
import hashlib

repo_root = sys.argv[1]
cheatsheets_dir = sys.argv[2]
sources_dir = sys.argv[3]
index_file = sys.argv[4]
no_sha = sys.argv[5] == "1"

errors = []
warnings = []

# ---------------------------------------------------------------------------
# Load INDEX.json
# ---------------------------------------------------------------------------

with open(index_file) as f:
    index = json.load(f)

entries = index.get("entries", [])

# Build lookup tables.
# url_to_entry: map from url (and fetch_url) -> entry
url_to_entry = {}
for entry in entries:
    for key in ("url", "fetch_url", "final_redirect"):
        u = entry.get(key, "")
        if u:
            url_to_entry[u] = entry

# local_path_to_entry: map from local_path -> entry
local_path_to_entry = {e["local_path"]: e for e in entries}

# Set of all local_paths cited by INDEX entries.
all_index_local_paths = set(e["local_path"] for e in entries)

# ---------------------------------------------------------------------------
# Helper: extract Provenance URLs and local: paths from a cheatsheet.
# ---------------------------------------------------------------------------

def extract_provenance(filepath):
    """
    Returns (urls: list[str], local_paths: list[str]).
    Parses the ## Provenance section for:
      - <https://...> or https://...  (URL citations)
      - local: `cheatsheet-sources/...`  (local path citations)
    """
    urls = []
    local_paths = []
    in_provenance = False

    with open(filepath) as f:
        lines = f.readlines()

    for line in lines:
        stripped = line.strip()
        if re.match(r'^##\s+Provenance', stripped):
            in_provenance = True
            continue
        if in_provenance and re.match(r'^##\s+', stripped):
            in_provenance = False
            continue
        if not in_provenance:
            continue

        # Extract URLs: <https://...> or bare https://...
        for m in re.finditer(r'<(https://[^>]+)>', stripped):
            urls.append(m.group(1))
        # Bare URLs not in angle brackets.
        for m in re.finditer(r'(?<![<`])(https://\S+?)(?:[,\s>)]|$)', stripped):
            u = m.group(1).rstrip('.,)')
            if u not in urls:
                urls.append(u)

        # local: `path`
        m = re.search(r'local:\s*`([^`]+)`', stripped)
        if m:
            local_paths.append(m.group(1))

    return urls, local_paths

# ---------------------------------------------------------------------------
# Collect all cheatsheet files.
# ---------------------------------------------------------------------------

cheatsheet_files = sorted(glob.glob(
    os.path.join(cheatsheets_dir, '**', '*.md'), recursive=True
))
# Exclude INDEX.md and TEMPLATE.md.
cheatsheet_files = [
    f for f in cheatsheet_files
    if os.path.basename(f) not in ('INDEX.md', 'TEMPLATE.md')
]

# ---------------------------------------------------------------------------
# Check 1 & 2: For each cheatsheet with a Provenance section, validate URLs
# and local: paths.
# ---------------------------------------------------------------------------

cited_local_paths = set()
checked_urls = 0
checked_local = 0

for cs_file in cheatsheet_files:
    rel_cs = os.path.relpath(cs_file, repo_root)
    urls, local_paths = extract_provenance(cs_file)

    for url in urls:
        checked_urls += 1
        if url not in url_to_entry:
            # Not in INDEX — this is a provenance URL that hasn't been fetched yet.
            # Per the design, this is an ERROR once the tool is fully wired in.
            # During migration (chunk 2), many cheatsheets won't have fetched yet.
            # We emit a WARNING for now (not blocking CI until chunk 4).
            warnings.append(
                f"UNFETCHED: {rel_cs}: URL not in INDEX.json: {url}"
            )

    for local_path in local_paths:
        checked_local += 1
        cited_local_paths.add(local_path)
        abs_path = os.path.join(repo_root, local_path)
        meta_path = abs_path + ".meta.yaml"

        if os.path.isfile(abs_path):
            # File exists — good.
            pass
        elif os.path.isfile(meta_path):
            # No verbatim file but sidecar exists — check redistribution.
            # Parse redistribution from sidecar.
            redist = ""
            if os.path.isfile(meta_path):
                with open(meta_path) as f:
                    for line in f:
                        m = re.match(r'^redistribution:\s*(\S+)', line.rstrip())
                        if m:
                            redist = m.group(1)
                            break
            if redist in ("do-not-bundle", "manual-review-required"):
                pass  # Expected; sidecar-only is OK for do-not-bundle.
            else:
                errors.append(
                    f"MISSING FILE: {rel_cs}: local: path has sidecar but no verbatim file "
                    f"and redistribution is '{redist}': {local_path}"
                )
        else:
            errors.append(
                f"MISSING: {rel_cs}: local: path does not exist (no file, no sidecar): {local_path}"
            )

# ---------------------------------------------------------------------------
# Check 3: Orphan detection — INDEX entry cited by no cheatsheet.
# ---------------------------------------------------------------------------

for entry in entries:
    lp = entry["local_path"]
    cited_by = entry.get("cited_by", [])
    # Check both the cited_by list in the sidecar AND cross-reference with
    # any local: paths we found in cheatsheets.
    if lp not in cited_local_paths and not cited_by:
        warnings.append(
            f"ORPHAN: {lp} is in INDEX.json but not cited by any cheatsheet"
        )

# ---------------------------------------------------------------------------
# Check 4: SHA-256 verification of present files.
# ---------------------------------------------------------------------------

sha_errors = 0
sha_ok = 0

if not no_sha:
    for entry in entries:
        lp = entry["local_path"]
        expected_sha = entry.get("content_sha256", "")
        if not expected_sha:
            continue

        abs_path = os.path.join(repo_root, lp)
        if not os.path.isfile(abs_path):
            # File absent (do-not-bundle or not yet fetched) — skip SHA check.
            continue

        with open(abs_path, 'rb') as f:
            actual_sha = hashlib.sha256(f.read()).hexdigest()

        if actual_sha != expected_sha:
            errors.append(
                f"SHA MISMATCH: {lp}: expected {expected_sha[:16]}... "
                f"got {actual_sha[:16]}... (content modified after fetch)"
            )
            sha_errors += 1
        else:
            sha_ok += 1

# ---------------------------------------------------------------------------
# Report.
# ---------------------------------------------------------------------------

print(f"check-cheatsheet-sources: {len(cheatsheet_files)} cheatsheets, "
      f"{len(entries)} INDEX entries, "
      f"{checked_urls} provenance URLs, {checked_local} local: paths checked"
      + (f", {sha_ok} SHA verifications" if not no_sha else " (SHA check skipped)"))

if warnings:
    print(f"\nWarnings ({len(warnings)}):")
    for w in warnings:
        print(f"  WARNING: {w}")

if errors:
    print(f"\nErrors ({len(errors)}):")
    for e in errors:
        print(f"  ERROR: {e}")
    sys.exit(1)

print("OK: all checks passed.")
PYEOF

EXIT_CODE=$?
exit "${EXIT_CODE}"
