#!/usr/bin/env bash
# check-cheatsheet-refs.sh — verify every cheatsheet reference resolves.
#
# Usage:
#   scripts/check-cheatsheet-refs.sh
#
# Walks:
#   - every cheatsheets/**/*.md file for `@cheatsheet <path>` annotations and
#     `## See also` bullets shaped like `- <path>.md — ...` or
#     `- ` + backtick-wrapped + `<path>.md` + backtick + ` — ...`.
#   - src-tauri/src/**/*.rs and images/default/**/*.sh for `@cheatsheet <path>`
#     annotations.
#
# A "<path>" resolves if cheatsheets/<path> exists. Paths may be either
# fully-qualified relative to the repo root (`cheatsheets/runtime/foo.md`) or
# relative to the cheatsheets/ directory (`runtime/foo.md`); both forms are
# accepted.
#
# Exits 0 if every reference resolves; non-zero with a per-broken-ref report
# otherwise. Run from any CWD — repo root is resolved via `git rev-parse`.
#
# OpenSpec change: cheatsheet-tooling-and-mcp
# @trace spec:cheatsheet-tooling, spec:cheatsheet-mcp-server

set -euo pipefail

# ---------------------------------------------------------------------------
# Locate repo root.
# ---------------------------------------------------------------------------

if ! REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi

cd "${REPO_ROOT}"

CHEATSHEETS_DIR="${REPO_ROOT}/cheatsheets"
if [[ ! -d "${CHEATSHEETS_DIR}" ]]; then
    echo "error: cheatsheets directory not found at ${CHEATSHEETS_DIR}" >&2
    exit 2
fi

if ! command -v rg >/dev/null 2>&1; then
    echo "error: ripgrep (rg) is required but not on PATH" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# resolve_target — given a cited path, return 0 if it resolves, 1 otherwise.
# Accepts both "runtime/foo.md" (relative to cheatsheets/) and
# "cheatsheets/runtime/foo.md" (relative to repo root).
# ---------------------------------------------------------------------------

resolve_target() {
    local target="$1"
    # Strip any surrounding whitespace.
    target="${target#"${target%%[![:space:]]*}"}"
    target="${target%"${target##*[![:space:]]}"}"

    # Reject empty / clearly non-paths.
    if [[ -z "$target" || "$target" != *.md ]]; then
        return 1
    fi

    if [[ -f "${CHEATSHEETS_DIR}/${target}" ]]; then
        return 0
    fi
    if [[ -f "${REPO_ROOT}/${target}" ]]; then
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Collect references. Each line on stdout is `<source-file>:<line-no>:<path>`.
# ---------------------------------------------------------------------------

collect_refs() {
    # 1. `@cheatsheet <path>[, <path>]...` annotations across cheatsheets,
    #    Rust source, and shell sources baked into images.
    # `--only-matching` so the printed line is just the captured paths — not
    # the whole prose line. Without -o, ripgrep --replace leaves the rest of
    # the line intact and our comma-split treats the prose as bad refs.
    rg --no-heading --line-number --no-messages --only-matching \
        --glob 'cheatsheets/**/*.md' \
        --glob 'src-tauri/src/**/*.rs' \
        --glob 'images/default/**/*.sh' \
        --glob 'images/default/**/Containerfile*' \
        '@cheatsheet[[:space:]]+([A-Za-z0-9_./-]+\.md(?:[[:space:]]*,[[:space:]]*[A-Za-z0-9_./-]+\.md)*)' \
        --replace '$1' \
        || true

    # 2. `## See also` bullets inside cheatsheets. Match either form:
    #      - <path>.md — ...
    #      - `<path>.md` — ...
    #    We do not enforce the em-dash specifically; some files use plain dash.
    #    We process every cheatsheet markdown file individually so we can scope
    #    the match to the section between `## See also` and the next `## ` heading.
    while IFS= read -r -d '' file; do
        awk -v file="$file" '
            BEGIN { in_section = 0 }
            /^## See also[[:space:]]*$/ { in_section = 1; line = NR; next }
            /^## / && in_section { in_section = 0 }
            in_section {
                # Match  - <path>.md  optionally backtick-wrapped, optional (DRAFT/STALE) marker,
                # followed by " — " or " - " or end of line.
                line_text = $0
                # Try backtick form first.
                if (match(line_text, /^-[[:space:]]+`([A-Za-z0-9_./-]+\.md)`/, m)) {
                    printf "%s:%d:%s\n", file, NR, m[1]
                }
                # Then bare form.
                else if (match(line_text, /^-[[:space:]]+([A-Za-z0-9_./-]+\.md)/, m)) {
                    printf "%s:%d:%s\n", file, NR, m[1]
                }
            }
        ' "$file"
    done < <(find "${CHEATSHEETS_DIR}" -type f -name '*.md' -print0)
}

# ---------------------------------------------------------------------------
# Walk every reference, verify, and report.
# ---------------------------------------------------------------------------

BROKEN=()
TOTAL=0

while IFS= read -r raw; do
    [[ -z "$raw" ]] && continue
    # rg output: <file>:<lineno>:<match-text>
    # When we replaced with $1 the match-text may contain comma-separated paths.
    file="${raw%%:*}"
    rest="${raw#*:}"
    lineno="${rest%%:*}"
    match="${rest#*:}"

    # Split on commas to handle `@cheatsheet foo.md, bar.md` lists.
    IFS=',' read -ra paths <<<"$match"
    for path in "${paths[@]}"; do
        # Trim whitespace.
        path="${path#"${path%%[![:space:]]*}"}"
        path="${path%"${path##*[![:space:]]}"}"
        [[ -z "$path" ]] && continue
        TOTAL=$((TOTAL + 1))
        if ! resolve_target "$path"; then
            BROKEN+=("${file}:${lineno}: ${path}")
        fi
    done
done < <(collect_refs)

if (( ${#BROKEN[@]} > 0 )); then
    echo "Broken cheatsheet references (${#BROKEN[@]} of ${TOTAL} checked):" >&2
    printf '  %s\n' "${BROKEN[@]}" >&2
    exit 1
fi

echo "OK: ${TOTAL} cheatsheet references resolved."
