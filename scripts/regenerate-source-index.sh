#!/usr/bin/env bash

# @tombstone obsolete:cheatsheet-source-layer
# @trace spec:cheatsheets-license-tiered, spec:cheatsheet-source-layer
#
# This script is RETIRED. superseded by build-time fetch-and-bake in scripts/build-image.sh forge.
# The legacy body below is preserved for traceability through the three-release
# retention window (final removal in 0.1.<N+3>.x per methodology.yaml tombstone discipline).
# Calling this script now exits early with a notice — it does NOT execute the legacy logic.
echo "[$(basename "$0")] @tombstone obsolete:cheatsheet-source-layer — script is retired." >&2
echo "  Reason: superseded by build-time fetch-and-bake in scripts/build-image.sh forge" >&2
echo "  See openspec/changes/cheatsheets-license-tiered/ for the replacement." >&2
exit 0

# regenerate-source-index.sh — rebuild cheatsheet-sources/INDEX.json from sidecars.
#
# Usage:
#   scripts/regenerate-source-index.sh           # rewrite cheatsheet-sources/INDEX.json
#   scripts/regenerate-source-index.sh --check   # exit non-zero if rewrite would diff
#
# Walks all cheatsheet-sources/**/*.meta.yaml sidecars and produces a
# deterministic JSON array of objects, one per sidecar. The JSON is
# sorted by the sidecar's local_path field for stable diffs.
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
INDEX_FILE="${SOURCES_DIR}/INDEX.json"

if [[ ! -d "${SOURCES_DIR}" ]]; then
    echo "error: cheatsheet-sources directory not found at ${SOURCES_DIR}" >&2
    exit 2
fi

CHECK_MODE=0
if [[ "${1:-}" == "--check" ]]; then
    CHECK_MODE=1
elif [[ -n "${1:-}" ]]; then
    echo "error: unknown argument: ${1}" >&2
    echo "usage: $(basename "$0") [--check]" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# Build JSON from all *.meta.yaml sidecars using Python (available everywhere).
# ---------------------------------------------------------------------------

TMP_JSON="$(mktemp)"
TMP_FINAL="$(mktemp)"
trap 'rm -f "${TMP_JSON}" "${TMP_FINAL}"' EXIT

python3 - "${SOURCES_DIR}" "${TMP_JSON}" <<'PYEOF'
import sys
import os
import json
import re
import glob

sources_dir = sys.argv[1]
output_path = sys.argv[2]

def parse_simple_yaml(path):
    """
    Parse a simple YAML file (no nesting beyond top-level lists).
    Returns a dict. Not a full YAML parser — handles the specific meta.yaml format.
    """
    fields = {}
    with open(path) as f:
        lines = f.readlines()

    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.rstrip('\n')

        # Skip blank lines and comments.
        if not stripped.strip() or stripped.strip().startswith('#'):
            i += 1
            continue

        # List field: "key:\n  - item\n  - item"
        m = re.match(r'^(\w+):\s*$', stripped)
        if m:
            key = m.group(1)
            items = []
            i += 1
            while i < len(lines):
                sub = lines[i].rstrip('\n')
                m2 = re.match(r'^  - (.+)$', sub)
                if m2:
                    items.append(m2.group(1))
                    i += 1
                elif sub.strip() == '[]':
                    i += 1
                    break
                else:
                    break
            fields[key] = items
            continue

        # Scalar field: "key: value"
        m = re.match(r'^(\w+):\s*(.*)', stripped)
        if m:
            key = m.group(1)
            val = m.group(2).strip()
            # Unquote if quoted.
            if val.startswith('"') and val.endswith('"'):
                val = val[1:-1]
            fields[key] = val
            i += 1
            continue

        i += 1

    return fields

entries = []
pattern = os.path.join(sources_dir, '**', '*.meta.yaml')
for meta_path in sorted(glob.glob(pattern, recursive=True)):
    try:
        fields = parse_simple_yaml(meta_path)
    except Exception as e:
        print(f"warning: could not parse {meta_path}: {e}", file=sys.stderr)
        continue

    # Compute the verbatim file path (remove .meta.yaml suffix).
    verbatim_path = meta_path[:-len('.meta.yaml')]
    rel_verbatim = os.path.relpath(verbatim_path, os.path.dirname(sources_dir))
    rel_meta = os.path.relpath(meta_path, os.path.dirname(sources_dir))

    # Check if the verbatim file exists on disk.
    file_exists = os.path.isfile(verbatim_path)

    entry = {
        "url": fields.get("url", ""),
        "fetch_url": fields.get("fetch_url", fields.get("url", "")),
        "final_redirect": fields.get("final_redirect", ""),
        "local_path": fields.get("local_path", rel_verbatim),
        "meta_path": rel_meta,
        "fetched": fields.get("fetched", ""),
        "fetcher_version": int(fields.get("fetcher_version", 1)),
        "content_sha256": fields.get("content_sha256", ""),
        "content_length": int(fields.get("content_length", 0)) if fields.get("content_length", "0").isdigit() else 0,
        "content_type": fields.get("content_type", ""),
        "http_status": int(fields.get("http_status", 200)) if str(fields.get("http_status", "200")).isdigit() else 200,
        "publisher": fields.get("publisher", ""),
        "license": fields.get("license", ""),
        "license_url": fields.get("license_url", ""),
        "redistribution": fields.get("redistribution", ""),
        "allowlist_match": fields.get("allowlist_match", ""),
        "render": fields.get("render", "static"),
        "cited_by": fields.get("cited_by", []),
        "notes": fields.get("notes", ""),
        "file_present": file_exists,
    }
    entries.append(entry)

# Sort by local_path for deterministic diffs.
entries.sort(key=lambda e: e["local_path"])

index = {
    "_generated_by": "scripts/regenerate-source-index.sh",
    "_do_not_edit": "Regenerated from *.meta.yaml sidecars. Run scripts/regenerate-source-index.sh to refresh.",
    "count": len(entries),
    "entries": entries
}

with open(output_path, 'w') as f:
    json.dump(index, f, indent=2, ensure_ascii=False)
    f.write('\n')

print(f"indexed {len(entries)} sidecar(s)")
PYEOF

# ---------------------------------------------------------------------------
# --check mode vs apply mode.
# ---------------------------------------------------------------------------

if (( CHECK_MODE )); then
    if [[ ! -f "${INDEX_FILE}" ]]; then
        echo "check: ${INDEX_FILE} does not exist" >&2
        exit 1
    fi
    if ! diff -u "${INDEX_FILE}" "${TMP_JSON}" >/dev/null 2>&1; then
        echo "check: ${INDEX_FILE} is out of date — run scripts/regenerate-source-index.sh" >&2
        diff -u "${INDEX_FILE}" "${TMP_JSON}" >&2 || true
        exit 1
    fi
    echo "check: INDEX.json is up to date ($(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d['count'])" "${INDEX_FILE}") entries)"
    exit 0
fi

if [[ -f "${INDEX_FILE}" ]] && diff -u "${INDEX_FILE}" "${TMP_JSON}" >/dev/null 2>&1; then
    echo "INDEX.json unchanged."
else
    cp "${TMP_JSON}" "${INDEX_FILE}"
    echo "INDEX.json regenerated: ${INDEX_FILE}"
fi
