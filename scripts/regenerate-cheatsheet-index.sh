#!/usr/bin/env bash
# regenerate-cheatsheet-index.sh — rebuild cheatsheets/INDEX.md from frontmatter.
#
# Usage:
#   scripts/regenerate-cheatsheet-index.sh           # rewrite cheatsheets/INDEX.md
#   scripts/regenerate-cheatsheet-index.sh --check   # exit non-zero if rewrite would diff
#
# Walks `cheatsheets/<category>/*.md` and one level deeper (e.g.
# `cheatsheets/languages/java/*.md`). For each file it parses YAML frontmatter
# (between the leading `---` markers), the first `# ` heading, and the body
# `**Use when**:` line (or the second non-empty body line) to assemble a
# one-line description.
#
# Status markers in the rendered index:
#   status: current     -> "<path> — <desc>"
#   status: draft       -> "<path> — [DRAFT] <desc>"
#   status: stale       -> "<path> — [STALE] <desc>"
#   status: deprecated  -> hidden from the default index
#   no frontmatter      -> "<path> — [DRAFT] <desc>"  (legacy files)
#
# WARNING: do not hand-edit cheatsheets/INDEX.md after this script lands —
# every run rewrites the file from scratch from the per-file frontmatter.
# Manual edits will be silently overwritten on the next pre-commit run.
#
# OpenSpec change: cheatsheet-tooling-and-mcp
# @trace spec:cheatsheet-tooling

set -euo pipefail

# ---------------------------------------------------------------------------
# Locate repo root + the cheatsheets tree.
# ---------------------------------------------------------------------------

if ! REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi

CHEATSHEETS_DIR="${REPO_ROOT}/cheatsheets"
INDEX_FILE="${CHEATSHEETS_DIR}/INDEX.md"

if [[ ! -d "${CHEATSHEETS_DIR}" ]]; then
    echo "error: cheatsheets directory not found at ${CHEATSHEETS_DIR}" >&2
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
# parse_cheatsheet — pure-awk frontmatter / body parser.
# Emits one tab-separated line: <status>\t<title>\t<description>
# Status is one of: current | draft | stale | deprecated | none
# (none = no frontmatter at all; treated as draft when rendering.)
# ---------------------------------------------------------------------------

parse_cheatsheet() {
    local file="$1"
    awk '
        BEGIN {
            in_fm = 0
            saw_fm_open = 0
            saw_fm_close = 0
            status = "none"
            title = ""
            description = ""
            second_line = ""
            use_when_next = 0
            nonempty_body_count = 0
            line_no = 0
        }
        {
            line_no++

            # Frontmatter open: only if --- is on line 1.
            if (line_no == 1 && $0 == "---") {
                in_fm = 1
                saw_fm_open = 1
                next
            }
            # Frontmatter close.
            if (in_fm && $0 == "---") {
                in_fm = 0
                saw_fm_close = 1
                next
            }
            if (in_fm) {
                if (match($0, /^status:[[:space:]]*([A-Za-z]+)/, m)) {
                    status = tolower(m[1])
                }
                next
            }

            # Body parsing.

            # First H1 -> title.
            if (title == "" && match($0, /^#[[:space:]]+(.*)/, m)) {
                title = m[1]
                next
            }

            if (description == "") {
                # Inline form: `**Use when**: blah`
                if (match($0, /^\*\*Use when\*\*:[[:space:]]*(.+)/, m)) {
                    description = m[1]
                }
                # Heading form: `## Use when` -> next non-empty line is desc.
                else if (match($0, /^##[[:space:]]+Use when[[:space:]]*$/)) {
                    use_when_next = 1
                }
                else if (use_when_next && $0 !~ /^[[:space:]]*$/) {
                    description = $0
                    use_when_next = 0
                }
            }

            # Track second non-empty body line as fallback description.
            if ($0 !~ /^[[:space:]]*$/) {
                nonempty_body_count++
                if (nonempty_body_count == 2 && second_line == "") {
                    second_line = $0
                }
            }
        }
        END {
            if (description == "") {
                description = second_line
            }
            sub(/^[[:space:]]+/, "", description)
            sub(/[[:space:]]+$/, "", description)

            if (saw_fm_open && !saw_fm_close) { status = "none" }
            if (!saw_fm_open) { status = "none" }

            printf "%s\x1f%s\x1f%s\n", status, title, description
        }
    ' "$file"
}

# ---------------------------------------------------------------------------
# truncate_desc — collapse whitespace, strip leading bold marker, cap at N.
# ---------------------------------------------------------------------------

truncate_desc() {
    local s="$1" max="$2"
    awk -v s="$s" -v max="$max" 'BEGIN {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
        sub(/^\*\*[^*]+\*\*:[[:space:]]*/, "", s)
        gsub(/[[:space:]]+/, " ", s)
        if (length(s) > max) {
            s = substr(s, 1, max - 1) "…"
        }
        print s
    }'
}

# ---------------------------------------------------------------------------
# process_file — emits "<rel-path>\t<marker>\t<desc>" for one cheatsheet.
# ---------------------------------------------------------------------------

process_file() {
    local file="$1" sub="$2"
    local fname rel parsed status title description marker desc

    fname="$(basename "$file")"
    if [[ -n "$sub" ]]; then
        rel="${sub}/${fname}"
    else
        rel="${fname}"
    fi

    parsed="$(parse_cheatsheet "$file")"
    # Use $'\x1f' (unit separator) since `read` collapses empty whitespace
    # IFS fields like '\t'. Unit separator is safe — won't appear in markdown.
    status="$(printf '%s' "$parsed" | awk -F$'\x1f' '{print $1}')"
    title="$(printf '%s' "$parsed" | awk -F$'\x1f' '{print $2}')"
    description="$(printf '%s' "$parsed" | awk -F$'\x1f' '{print $3}')"

    if [[ "$status" == "deprecated" ]]; then
        return 0
    fi

    case "$status" in
        current) marker="" ;;
        stale)   marker="[STALE]" ;;
        draft|none|*) marker="[DRAFT]" ;;
    esac

    if [[ -z "$description" ]]; then
        description="$title"
    fi
    desc="$(truncate_desc "$description" 80)"

    printf '%s\x1f%s\x1f%s\n' "$rel" "$marker" "$desc"
}

# ---------------------------------------------------------------------------
# Build the regenerated INDEX into a temp file.
# ---------------------------------------------------------------------------

TMP_OUT="$(mktemp)"
TMP_ROWS="$(mktemp)"
TMP_FINAL="$(mktemp)"
trap 'rm -f "${TMP_OUT}" "${TMP_ROWS}" "${TMP_FINAL}"' EXIT

# Fixed header — replaces whatever was in the file before.
cat >"${TMP_OUT}" <<'HEADER_EOF'
# Cheatsheets Index

@trace spec:agent-cheatsheets, spec:cheatsheet-tooling

> AUTO-GENERATED by `scripts/regenerate-cheatsheet-index.sh`. Do NOT hand-edit.
> Source of truth = the YAML frontmatter on each cheatsheet file.
> To refresh: `scripts/regenerate-cheatsheet-index.sh`.

Curated reference for tools, languages, and runtimes shipped with the Tillandsias forge. Optimised for `cat | rg`: one line per cheatsheet, `<filename> — <one-line description>`.

**Discovery**: agents inside the forge find cheatsheets at `$TILLANDSIAS_CHEATSHEETS/INDEX.md` (resolves to `/opt/cheatsheets/INDEX.md`). Humans read them on GitHub.

**Authoring**: copy `cheatsheets/TEMPLATE.md` into the right category subdirectory, fill the YAML frontmatter (`tags`, `since`, `last_verified`, `sources`, `authority`, `status`), then run `scripts/regenerate-cheatsheet-index.sh` to refresh this file.

HEADER_EOF

# Walk categories (= immediate subdirectories of cheatsheets/).
mapfile -t CATEGORIES < <(
    find "${CHEATSHEETS_DIR}" -mindepth 1 -maxdepth 1 -type d \
        -printf '%f\n' | sort
)

for category in "${CATEGORIES[@]}"; do
    : >"${TMP_ROWS}"

    # Files directly under cheatsheets/<category>/
    while IFS= read -r -d '' file; do
        process_file "$file" "" >>"${TMP_ROWS}" || true
    done < <(find "${CHEATSHEETS_DIR}/${category}" -mindepth 1 -maxdepth 1 \
        -type f -name '*.md' -print0 | sort -z)

    # Files one level deeper: cheatsheets/<category>/<sub>/*.md
    while IFS= read -r -d '' subdir; do
        sub="$(basename "$subdir")"
        while IFS= read -r -d '' file; do
            process_file "$file" "$sub" >>"${TMP_ROWS}" || true
        done < <(find "$subdir" -mindepth 1 -maxdepth 1 -type f -name '*.md' \
            -print0 | sort -z)
    done < <(find "${CHEATSHEETS_DIR}/${category}" -mindepth 1 -maxdepth 1 \
        -type d -print0 | sort -z)

    {
        echo "## ${category}"
        echo
        if [[ -s "${TMP_ROWS}" ]]; then
            # Compute longest "<path> [MARKER]" so descriptions align.
            max_left=0
            while IFS=$'\x1f' read -r path marker _desc; do
                if [[ -n "$marker" ]]; then
                    width=$(( ${#path} + 1 + ${#marker} ))
                else
                    width=${#path}
                fi
                if (( width > max_left )); then
                    max_left=$width
                fi
            done <"${TMP_ROWS}"
            if (( max_left < 32 )); then
                max_left=32
            fi

            while IFS=$'\x1f' read -r path marker desc; do
                if [[ -n "$marker" ]]; then
                    left="${path} ${marker}"
                else
                    left="${path}"
                fi
                printf -- '- %-*s — %s\n' "$max_left" "$left" "$desc"
            done <"${TMP_ROWS}"
        else
            echo "(empty)"
        fi
        echo
    } >>"${TMP_OUT}"
done

# Canonicalise: collapse runs of blank lines, ensure exactly one trailing \n.
awk 'BEGIN { blank=0 }
     /^$/ { blank++; next }
     { while (blank-- > 0) print ""; blank=0; print }
     END { print "" }' "${TMP_OUT}" >"${TMP_FINAL}"

# ---------------------------------------------------------------------------
# --check mode vs apply mode.
# ---------------------------------------------------------------------------

if (( CHECK_MODE )); then
    if [[ ! -f "${INDEX_FILE}" ]]; then
        echo "check: ${INDEX_FILE} does not exist" >&2
        exit 1
    fi
    if ! diff -u "${INDEX_FILE}" "${TMP_FINAL}" >/dev/null; then
        echo "check: ${INDEX_FILE} is out of date — run scripts/regenerate-cheatsheet-index.sh" >&2
        diff -u "${INDEX_FILE}" "${TMP_FINAL}" >&2 || true
        exit 1
    fi
    exit 0
fi

if [[ -f "${INDEX_FILE}" ]] && diff -u "${INDEX_FILE}" "${TMP_FINAL}" >/dev/null; then
    echo "INDEX.md unchanged."
else
    cp "${TMP_FINAL}" "${INDEX_FILE}"
    echo "INDEX.md regenerated: ${INDEX_FILE}"
fi
