#!/usr/bin/env bash
# audit-cheatsheet-sources.sh — CSV migration triage for the cheatsheet-source layer.
#
# Usage:
#   scripts/audit-cheatsheet-sources.sh [> /tmp/audit.csv]
#
# Outputs a CSV with columns:
#   cheatsheet_path, source_url, in_index_json, license_allowlisted, sha256_present
#
# Designed for the bulk-migration step (Chunk 2) to identify which cheatsheets'
# Provenance URLs have already been fetched, which domains are allowlisted, and
# which are missing SHA-256 coverage.
#
# Exit code: always 0. Errors are reported in the csv as values.
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
ALLOWLIST="${SOURCES_DIR}/license-allowlist.toml"
INDEX_FILE="${SOURCES_DIR}/INDEX.json"

# ---------------------------------------------------------------------------
# Run the audit in Python.
# ---------------------------------------------------------------------------

python3 - "${REPO_ROOT}" "${CHEATSHEETS_DIR}" "${SOURCES_DIR}" "${ALLOWLIST}" "${INDEX_FILE}" <<'PYEOF'
import sys
import os
import json
import re
import glob
import csv

repo_root = sys.argv[1]
cheatsheets_dir = sys.argv[2]
sources_dir = sys.argv[3]
allowlist_path = sys.argv[4]
index_file = sys.argv[5]

# ---------------------------------------------------------------------------
# Load INDEX.json.
# ---------------------------------------------------------------------------

url_to_entry = {}
sha_by_local_path = {}

if os.path.isfile(index_file):
    with open(index_file) as f:
        index = json.load(f)
    for entry in index.get("entries", []):
        for key in ("url", "fetch_url", "final_redirect"):
            u = entry.get(key, "")
            if u:
                url_to_entry[u] = entry
        lp = entry.get("local_path", "")
        sha = entry.get("content_sha256", "")
        if lp and sha:
            sha_by_local_path[lp] = sha

# ---------------------------------------------------------------------------
# Load allowlist domains.
# ---------------------------------------------------------------------------

allowlisted_domains = set()
if os.path.isfile(allowlist_path):
    with open(allowlist_path) as f:
        for line in f:
            m = re.match(r'\[domains\."([^"]+)"\]', line.strip())
            if m:
                allowlisted_domains.add(m.group(1))

def is_allowlisted(url):
    """Return the matching allowlist entry key, or '' if not found."""
    # Strip scheme.
    u = url
    if u.startswith("https://"):
        u = u[8:]
    elif u.startswith("http://"):
        u = u[7:]
    host = u.split('/')[0]
    path_parts = u[len(host):].lstrip('/').split('/')

    # Try host + progressively shorter path segments.
    for depth in range(min(3, len(path_parts)), -1, -1):
        if depth > 0:
            candidate = host + '/' + '/'.join(path_parts[:depth])
        else:
            candidate = host
        if candidate in allowlisted_domains:
            return candidate
    return ''

# ---------------------------------------------------------------------------
# Helper: extract Provenance URLs.
# ---------------------------------------------------------------------------

def extract_provenance_urls(filepath):
    urls = []
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
        # Skip "last updated" line.
        if '**Last updated:**' in stripped:
            continue
        # Extract URLs: <https://...> or bare https://...
        for m in re.finditer(r'<(https://[^>]+)>', stripped):
            u = m.group(1)
            if u not in urls:
                urls.append(u)
        for m in re.finditer(r'(?<![<`])(https://\S+?)(?:[,\s>)]|$)', stripped):
            u = m.group(1).rstrip('.,)')
            if u not in urls:
                urls.append(u)
    return urls

# ---------------------------------------------------------------------------
# Walk cheatsheets.
# ---------------------------------------------------------------------------

cheatsheet_files = sorted(glob.glob(
    os.path.join(cheatsheets_dir, '**', '*.md'), recursive=True
))
cheatsheet_files = [
    f for f in cheatsheet_files
    if os.path.basename(f) not in ('INDEX.md', 'TEMPLATE.md')
]

writer = csv.writer(sys.stdout)
writer.writerow([
    "cheatsheet_path",
    "source_url",
    "in_index_json",
    "license_allowlisted",
    "allowlist_key",
    "sha256_present",
    "local_path_if_fetched",
])

for cs_file in cheatsheet_files:
    rel_cs = os.path.relpath(cs_file, repo_root)
    urls = extract_provenance_urls(cs_file)

    if not urls:
        # Cheatsheet has no Provenance URLs — emit a no-url row.
        writer.writerow([rel_cs, "(no provenance URLs)", "N/A", "N/A", "", "N/A", ""])
        continue

    for url in urls:
        in_index = url in url_to_entry
        allowlist_key = is_allowlisted(url)
        allowlisted = bool(allowlist_key)

        # If in index, find its local_path and check for sha256.
        local_path = ""
        sha_present = False
        if in_index:
            entry = url_to_entry[url]
            local_path = entry.get("local_path", "")
            sha = entry.get("content_sha256", "")
            sha_present = bool(sha)

        writer.writerow([
            rel_cs,
            url,
            "yes" if in_index else "no",
            "yes" if allowlisted else "no",
            allowlist_key,
            "yes" if sha_present else "no",
            local_path,
        ])

PYEOF
