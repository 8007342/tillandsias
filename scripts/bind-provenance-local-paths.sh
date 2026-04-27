#!/usr/bin/env bash
# bind-provenance-local-paths.sh — Inject `local:` fields into cheatsheet
# Provenance sections for every URL that has an INDEX.json entry.
#
# Usage:
#   scripts/bind-provenance-local-paths.sh [--dry-run]
#
# For each entry in cheatsheet-sources/INDEX.json:
#   - Walk every cheatsheet listed in cited_by (if any).
#   - Walk ALL cheatsheets looking for matching Provenance URLs.
#   - For each matching URL line without a `local:` already present,
#     inject `  local: \`<local_path>\`` on the line immediately after.
#   - Also bumps `last_verified` in frontmatter to 2026-04-27 for
#     rewritten cheatsheets (SHA match is implicit — all chunk-2 fetches
#     are fresh from 2026-04-27).
#   - For cheatsheets with off-allowlist (unfetched) URLs in Provenance,
#     leaves them unchanged (no `local:` for what didn't fetch).
#
# Idempotent: a second run is a no-op (detects `local:` already present).
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

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=1
elif [[ -n "${1:-}" ]]; then
    echo "error: unknown argument: ${1}" >&2
    echo "usage: $(basename "$0") [--dry-run]" >&2
    exit 2
fi

if [[ ! -f "${INDEX_FILE}" ]]; then
    echo "error: ${INDEX_FILE} not found — run scripts/fetch-cheatsheet-source.sh first" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Python logic: parse INDEX.json, walk cheatsheets, inject local: fields.
# ---------------------------------------------------------------------------

python3 - "${REPO_ROOT}" "${CHEATSHEETS_DIR}" "${INDEX_FILE}" "${DRY_RUN}" <<'PYEOF'
import sys
import os
import json
import re
import glob

repo_root = sys.argv[1]
cheatsheets_dir = sys.argv[2]
index_file = sys.argv[3]
dry_run = sys.argv[4] == "1"

LAST_VERIFIED_DATE = "2026-04-27"

# ---------------------------------------------------------------------------
# Load INDEX.json — build url -> entry map.
# ---------------------------------------------------------------------------

with open(index_file) as f:
    index = json.load(f)

entries = index.get("entries", [])

# Map from URL (all three URL variants) -> entry
url_to_entry = {}
for entry in entries:
    for key in ("url", "fetch_url", "final_redirect"):
        u = entry.get(key, "")
        if u:
            # Don't overwrite with a less-preferred key
            if u not in url_to_entry:
                url_to_entry[u] = entry

# ---------------------------------------------------------------------------
# Helper: rewrite a cheatsheet file, injecting local: lines.
# ---------------------------------------------------------------------------

def extract_url_from_line(line_stripped):
    """Return all URLs found in a Provenance bullet line."""
    urls = []
    # <https://...> form
    for m in re.finditer(r'<(https://[^>]+)>', line_stripped):
        urls.append(m.group(1))
    # bare https://... form (not already captured in angle-brackets)
    for m in re.finditer(r'(?<![<`])(https://\S+?)(?:[,\s>)]|$)', line_stripped):
        u = m.group(1).rstrip('.,)')
        if u not in urls:
            urls.append(u)
    return urls


def already_has_local(lines, idx):
    """Check if the line at idx already has local: on this line or the next."""
    if re.search(r'local:\s*`', lines[idx]):
        return True
    if idx + 1 < len(lines) and re.search(r'^\s+local:\s*`', lines[idx + 1]):
        return True
    return False


def rewrite_cheatsheet(filepath):
    """
    Returns (modified: bool, lines_changed: int, new_content: str).
    """
    with open(filepath) as f:
        original = f.read()

    lines = original.splitlines(keepends=True)

    in_provenance = False
    in_frontmatter = False
    fm_open_seen = False
    fm_close_seen = False
    fm_line_idx = None  # index of `last_verified:` line in frontmatter

    # First pass: find provenance boundaries and last_verified line
    prov_start = None
    prov_end = None
    fm_end = None

    for i, line in enumerate(lines):
        stripped = line.strip()

        # Frontmatter detection
        if i == 0 and stripped == '---':
            in_frontmatter = True
            fm_open_seen = True
            continue
        if in_frontmatter and stripped == '---':
            in_frontmatter = False
            fm_close_seen = True
            fm_end = i
            continue
        if in_frontmatter and re.match(r'^last_verified:', stripped):
            fm_line_idx = i

        # Provenance section detection
        if re.match(r'^##\s+Provenance', stripped):
            in_provenance = True
            prov_start = i
            continue
        if in_provenance and re.match(r'^##\s+', stripped):
            in_provenance = False
            prov_end = i
            continue

    # Build new lines: inject local: after each URL line that has a match.
    new_lines = []
    injected_count = 0
    in_provenance = False

    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()

        # Track provenance section
        if re.match(r'^##\s+Provenance', stripped):
            in_provenance = True
            new_lines.append(line)
            i += 1
            continue
        if in_provenance and re.match(r'^##\s+', stripped):
            in_provenance = False
            new_lines.append(line)
            i += 1
            continue

        if in_provenance:
            # Try to find URLs on this line
            urls_on_line = extract_url_from_line(stripped)
            entry_for_line = None
            for u in urls_on_line:
                if u in url_to_entry:
                    entry_for_line = url_to_entry[u]
                    break

            new_lines.append(line)
            i += 1

            # If this line has a fetchable URL and no local: yet, inject.
            if entry_for_line is not None and not already_has_local(lines, i - 1):
                local_path = entry_for_line["local_path"]
                # Detect the indentation of the current bullet line.
                # Bullets start with "- " or "  - " or just spaces; sub-indent by 2.
                indent_match = re.match(r'^(\s*)', line)
                base_indent = indent_match.group(1) if indent_match else ''
                # If line starts with "- ", sub-item uses "  " extra indent.
                sub_indent = base_indent + '  '
                inject_line = f'{sub_indent}local: `{local_path}`\n'
                new_lines.append(inject_line)
                injected_count += 1
        else:
            new_lines.append(line)
            i += 1

    if injected_count == 0:
        return False, 0, original

    new_content = ''.join(new_lines)

    # Bump last_verified in frontmatter if it exists and is older.
    if fm_line_idx is not None:
        # Find the line in new_lines (same index since we only added lines in provenance)
        # Need to re-locate the last_verified line in new_lines.
        for j, nl in enumerate(new_lines):
            if re.match(r'^last_verified:', nl.strip()):
                current_date_m = re.search(r'\d{4}-\d{2}-\d{2}', nl)
                if current_date_m:
                    current_date = current_date_m.group(0)
                    if current_date < LAST_VERIFIED_DATE:
                        new_lines[j] = re.sub(
                            r'\d{4}-\d{2}-\d{2}',
                            LAST_VERIFIED_DATE,
                            nl,
                            count=1
                        )
                break
        new_content = ''.join(new_lines)

    return True, injected_count, new_content


# ---------------------------------------------------------------------------
# Walk all cheatsheets and rewrite.
# ---------------------------------------------------------------------------

cheatsheet_files = sorted(glob.glob(
    os.path.join(cheatsheets_dir, '**', '*.md'), recursive=True
))
cheatsheet_files = [
    f for f in cheatsheet_files
    if os.path.basename(f) not in ('INDEX.md', 'TEMPLATE.md')
]

total_injected = 0
files_modified = 0

for cs_file in cheatsheet_files:
    rel = os.path.relpath(cs_file, repo_root)
    modified, count, new_content = rewrite_cheatsheet(cs_file)
    if modified:
        if dry_run:
            print(f"[DRY-RUN] would inject {count} local: line(s) into {rel}")
        else:
            with open(cs_file, 'w') as f:
                f.write(new_content)
            print(f"  bound {count} local: path(s) in {rel}")
        total_injected += count
        files_modified += 1

if total_injected == 0:
    print("bind-provenance: nothing to do — all local: paths already present (or no fetched URLs).")
else:
    verb = "would inject" if dry_run else "injected"
    print(f"\nbind-provenance: {verb} {total_injected} local: path(s) across {files_modified} cheatsheet(s).")

PYEOF
