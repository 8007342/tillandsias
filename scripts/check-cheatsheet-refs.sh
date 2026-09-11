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
# @trace spec:cheatsheet-tooling, spec:cheatsheet-mcp-server, spec:spec-traceability

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

# ORDER 799-tb7q — host rg, else the toolbox's, else refuse. This used to exit 2
# with "ripgrep (rg) is required but not on PATH", which is the mis-shaped
# hard-fail-with-a-host-instruction the packet was filed against: the toolbox
# carries rg (ripgrep 15.2.0), so refusing without asking it is refusing work we
# can do.
# shellcheck source=scripts/lib/tool-dispatch.sh
# Resolve the lib by WALKING UP, not by a fixed depth (order 914-ahsy). The
# fixed form `dirname "${BASH_SOURCE[0]}"/lib/...` is correct only for a caller
# sitting directly in scripts/. From scripts/refusal-calibration/ it points at a
# lib that does not exist, the `|| true` swallows the miss, and the tool variable
# silently falls back to the bare name — a conversion that passes review, passes
# the suite, and changes nothing.
_td_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
while [ -n "$_td_dir" ] && [ "$_td_dir" != "/" ] && [ ! -f "$_td_dir/lib/tool-dispatch.sh" ]; do
    _td_dir="$(dirname "$_td_dir")"
done
if [ -f "$_td_dir/lib/tool-dispatch.sh" ]; then
    . "$_td_dir/lib/tool-dispatch.sh" 2>/dev/null || true
fi
if command -v resolve_tool >/dev/null 2>&1; then
    RG="$(resolve_tool rg || printf '')"
else
    RG="$(command -v rg >/dev/null 2>&1 && printf 'rg' || printf '')"
fi
if [ -z "$RG" ]; then
    echo "error: ripgrep (rg) is available neither on this host nor in the" >&2
    echo "       tillandsias-builder toolbox. Install rg, or add it to the" >&2
    echo "       toolbox init set in scripts/with-tillandsias-builder.sh." >&2
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
    $RG --no-heading --line-number --no-messages --only-matching \
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
    # ORDER 1087-h2z9 (windows). DO NOT SPLIT ON THE FIRST COLON. rg emits
    # `<file>:<line>:<match>`, and on Windows `<file>` begins `C:/`, so the
    # drive-letter colon shifts every field by one:
    #
    #   file   = "C"
    #   lineno = "/Users/.../claude-code.md"
    #   match  = "95:agents/openspec.md"      <- resolve_target sees THIS
    #
    # Every reference then fails to resolve. Measured on yolanda 2026-09-06:
    # 491 of 577 reported broken, against 3 on a Linux host, and the targets of
    # the 488 extra all EXIST.
    #
    # AND THE REPORT HIDES IT. The broken line is printed as
    # "${file}:${lineno}: ${path}", which REASSEMBLES the mis-split fields into
    # a string that reads exactly like a correct report — a plausible path, a
    # plausible line number, a plausible target. Nothing in the output says the
    # parse went wrong, which is why this survived in a check nothing runs.
    #
    # Anchor on the LINE NUMBER instead: `:<digits>:` occurs once, after the
    # path, on every platform. A drive letter is never followed by digits and a
    # colon.
    # Parse from the RIGHT, with parameter expansion only. A bash regex
    # anchored as ^(.+):([0-9]+):(.*)$ is correct and BACKTRACKS CATASTROPHICALLY
    # on these lines — measured here: the check went from ~0.3s to still running
    # after seven minutes. The match text is a .md path list produced by
    # [A-Za-z0-9_./-]+, so it can never contain a colon; the last two colons are
    # therefore always the field separators, whatever the path prefix looks like.
    match="${raw##*:}"
    _rest="${raw%:*}"
    lineno="${_rest##*:}"
    file="${_rest%:*}"

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
