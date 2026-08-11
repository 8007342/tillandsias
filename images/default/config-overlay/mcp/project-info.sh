#!/usr/bin/env bash
# MCP Server: Project Info for Tillandsias forge containers
# @trace spec:layered-tools-overlay, spec:forge-environment-discoverability
# Communicates via JSON-RPC over stdin/stdout (MCP stdio transport)
#
# Tools: project_structure, file_summary, search_code, project_list, project_info,
#        project_type, project_metadata, find_files, grep_code, git_status,
#        read_file, plan_query, project_answer
#
# Run with the single argument `capabilities` to print this engine's embedded
# capability manifest and exit (order 569 pattern; see the manifest block below
# and images/default/lib-project-engine-capability.sh for the skew probe).

set -euo pipefail

# ── Project type detection ──────────────────────────────────────
# @trace spec:forge-environment-discoverability
# Detects project type by examining canonical marker files.
# Returns a list of detected types (may be multiple for polyglot projects).
detect_project_types() {
    local project_dir="${1:-.}"
    local types=""

    # Detect by marker files (order matters for common polyglots)
    [ -f "$project_dir/Cargo.toml" ] && types="$types rust"
    [ -f "$project_dir/Cargo.lock" ] && types="$types rust-workspace"
    [ -f "$project_dir/go.mod" ] && types="$types go"
    [ -f "$project_dir/go.sum" ] && types="$types go"
    [ -f "$project_dir/package.json" ] && types="$types node"
    [ -f "$project_dir/package-lock.json" ] && types="$types node-npm"
    [ -f "$project_dir/yarn.lock" ] && types="$types node-yarn"
    [ -f "$project_dir/pnpm-lock.yaml" ] && types="$types node-pnpm"
    [ -f "$project_dir/bun.lockb" ] && types="$types node-bun"
    [ -f "$project_dir/requirements.txt" ] && types="$types python"
    [ -f "$project_dir/setup.py" ] && types="$types python"
    [ -f "$project_dir/setup.cfg" ] && types="$types python"
    [ -f "$project_dir/pyproject.toml" ] && types="$types python-pyproject"
    [ -f "$project_dir/poetry.lock" ] && types="$types python-poetry"
    [ -f "$project_dir/Pipfile" ] && types="$types python-pipenv"
    [ -f "$project_dir/pom.xml" ] && types="$types java-maven"
    [ -f "$project_dir/build.gradle" ] || [ -f "$project_dir/build.gradle.kts" ] && types="$types java-gradle"
    [ -f "$project_dir/CMakeLists.txt" ] && types="$types cmake"
    [ -f "$project_dir/Makefile" ] && types="$types make"
    [ -f "$project_dir/Dockerfile" ] && types="$types docker"
    [ -f "$project_dir/flake.nix" ] && types="$types nix"
    [ -f "$project_dir/pubspec.yaml" ] && types="$types dart-flutter"
    # @trace spec:forge-environment-discoverability, gap:multi-workdir-git-worktree-handling
    # Use [ -e ] instead of [ -d ] to support git worktrees, which have .git as a file (pointing to parent worktree) not a directory
    [ -e "$project_dir/.git" ] && types="$types git"

    # Trim leading/trailing whitespace and deduplicate
    echo "$types" | xargs | tr ' ' '\n' | sort -u | tr '\n' ',' | sed 's/,$//'
}

# ── Project metadata extraction ──────────────────────────────────
# @trace spec:forge-environment-discoverability
# Extracts structured metadata about a project.
get_project_metadata() {
    local project_dir="${1:-.}"
    local project_name="${2:-$(basename "$project_dir")}"

    # Description from README
    local description=""
    if [ -f "$project_dir/README.md" ]; then
        description=$(head -1 "$project_dir/README.md" | sed 's/^# //' | sed 's/^## //' | head -c 100)
    fi

    # Project type
    local project_type
    project_type=$(detect_project_types "$project_dir")

    # Is Tillandsias-managed
    local is_managed="false"
    [ -f "$project_dir/.tillandsias/config.toml" ] && is_managed="true"

    # Output as structured JSON
    cat <<EOF
{
  "name": "$project_name",
  "path": "$project_dir",
  "description": "$description",
  "types": "$project_type",
  "managed": $is_managed,
  "has_readme": $([ -f "$project_dir/README.md" ] && echo "true" || echo "false"),
  "has_git": $([ -d "$project_dir/.git" ] && echo "true" || echo "false"),
  "has_config": $([ -f "$project_dir/.tillandsias/config.toml" ] && echo "true" || echo "false")
}
EOF
}

# ── Generic index enrichment: the deterministic subset (order 669-egjn) ─────
# @trace spec:forge-environment-discoverability, order:669-egjn
#
# The design's deterministic subset (C2/C5) is type, status, commands, layout,
# actions. Before this order the generic index carried only path/types/meta,
# so commands/layout/actions had NOTHING to answer from off-Tillandsias — the
# C2 refusal copy advertised an index richer than the one that existed.
#
# Each derivation below returns one JSON document
#   { "answer": <prose|null>, "citations": [Citation...], "reason": <string?> }
# where every citation is the RATIFIED struct {path, line_start, line_end,
# kind, authority} and authority.key is text that appears BOTH in the cited
# span and in the answer — verify-answer's rule that a citation may never be
# decorative. When nothing citable exists, citations stay [] and `reason`
# carries the typed-refusal text; this lane never guesses.

# commands — derived from marker files; the marker file:line is the citable
# span. package.json's "scripts" block, Cargo.toml's [package]/[workspace]
# header, and Makefile target lines.
_gi_commands_json() {
    _gic_dir="${1:-.}"
    _gic_parts=""
    _gic_cits='[]'
    if [ -f "$_gic_dir/package.json" ]; then
        _gic_s=$(grep -nF '"scripts"' "$_gic_dir/package.json" 2>/dev/null | head -1 | cut -d: -f1 || true)
        if [ -n "$_gic_s" ]; then
            _gic_e=$(awk -v s="$_gic_s" 'NR>=s && index($0,"}") {print NR; exit}' "$_gic_dir/package.json" 2>/dev/null || true)
            [ -n "$_gic_e" ] || _gic_e="$_gic_s"
            _gic_scripts=$(jq -r '[(.scripts // {}) | to_entries[] | "npm run \(.key) -> \(.value)"] | join("; ")' "$_gic_dir/package.json" 2>/dev/null || true)
            if [ -n "$_gic_scripts" ]; then
                _gic_parts="${_gic_parts}package.json \"scripts\": ${_gic_scripts}. "
                _gic_cits=$(printf '%s' "$_gic_cits" | jq \
                    --argjson s "$_gic_s" --argjson e "$_gic_e" \
                    '. + [{path: "package.json", line_start: $s, line_end: $e, kind: "code",
                           authority: {key: "\"scripts\"", source: "package.json"}}]')
            fi
        fi
    fi
    if [ -f "$_gic_dir/Cargo.toml" ]; then
        _gic_hdr=""
        _gic_hn=""
        for _gic_h in '[package]' '[workspace]'; do
            _gic_hn=$(grep -nF "$_gic_h" "$_gic_dir/Cargo.toml" 2>/dev/null | head -1 | cut -d: -f1 || true)
            if [ -n "$_gic_hn" ]; then
                _gic_hdr="$_gic_h"
                break
            fi
        done
        if [ -n "$_gic_hdr" ]; then
            _gic_parts="${_gic_parts}Cargo.toml ${_gic_hdr}: cargo build; cargo test; cargo run. "
            _gic_cits=$(printf '%s' "$_gic_cits" | jq \
                --argjson n "$_gic_hn" --arg k "$_gic_hdr" \
                '. + [{path: "Cargo.toml", line_start: $n, line_end: $n, kind: "code",
                       authority: {key: $k, source: "Cargo.toml"}}]')
        fi
    fi
    if [ -f "$_gic_dir/Makefile" ]; then
        # Target lines: name at column 0 followed by ':'. Excludes special
        # targets (leading '.'), pattern rules (leading '%'), and ':='
        # variable assignments.
        _gic_tgt=$(grep -nE '^[A-Za-z0-9][A-Za-z0-9_./-]*[[:space:]]*:' "$_gic_dir/Makefile" 2>/dev/null | grep -v ':=' || true)
        if [ -n "$_gic_tgt" ]; then
            _gic_f=$(printf '%s\n' "$_gic_tgt" | head -1 | cut -d: -f1)
            _gic_l=$(printf '%s\n' "$_gic_tgt" | tail -1 | cut -d: -f1)
            _gic_first=$(printf '%s\n' "$_gic_tgt" | head -1 | cut -d: -f2 | sed 's/[[:space:]]*$//')
            _gic_names=$(printf '%s\n' "$_gic_tgt" | cut -d: -f2 | sed 's/[[:space:]]*$//' | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')
            _gic_parts="${_gic_parts}Makefile targets: make {${_gic_names}}. "
            _gic_cits=$(printf '%s' "$_gic_cits" | jq \
                --argjson s "$_gic_f" --argjson e "$_gic_l" --arg k "$_gic_first" \
                '. + [{path: "Makefile", line_start: $s, line_end: $e, kind: "code",
                       authority: {key: $k, source: "Makefile"}}]')
        fi
    fi
    if [ "$(printf '%s' "$_gic_cits" | jq 'length' 2>/dev/null || echo 0)" -gt 0 ]; then
        jq -cn --arg a "Commands (from marker files): ${_gic_parts% }" --argjson c "$_gic_cits" \
            '{answer: $a, citations: $c}'
    else
        jq -cn '{answer: null, citations: [],
                 reason: "commands question — the generic index found no citable command markers (no package.json \"scripts\", no Cargo.toml [package]/[workspace], no Makefile targets)"}'
    fi
}

# layout — the top-level tree walk, anchored to a real span: the first line of
# a recognizable top-level file. The claim the citation supports is explicit
# in the answer ("<file>:1 reads: <text>"), so the citation is evidence for
# the walk's anchor, never decoration.
_gi_layout_json() {
    _gil_dir="${1:-.}"
    _gil_entries=$(cd "$_gil_dir" 2>/dev/null && LC_ALL=C ls -A 2>/dev/null | head -40 | while IFS= read -r _gil_e; do
        if [ -d "$_gil_e" ]; then printf '%s/\n' "$_gil_e"; else printf '%s\n' "$_gil_e"; fi
    done | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g' || true)
    _gil_anchor=""
    _gil_first=""
    for _gil_c in README.md readme.md README package.json Cargo.toml Makefile; do
        [ -f "$_gil_dir/$_gil_c" ] || continue
        _gil_first=$(head -1 "$_gil_dir/$_gil_c" 2>/dev/null | tr -d '\r' || true)
        if [ -n "$_gil_first" ] && [ "${#_gil_first}" -le 120 ]; then
            _gil_anchor="$_gil_c"
            break
        fi
        _gil_first=""
    done
    if [ -n "$_gil_entries" ] && [ -n "$_gil_anchor" ]; then
        jq -cn --arg e "$_gil_entries" --arg f "$_gil_anchor" --arg k "$_gil_first" \
            '{answer: ("Layout (top-level): " + $e + ". Anchor: " + $f + ":1 reads: " + $k),
              citations: [{path: $f, line_start: 1, line_end: 1, kind: "code",
                           authority: {key: $k, source: "tree-walk"}}]}'
    else
        jq -cn '{answer: null, citations: [],
                 reason: "layout question — the tree walk found no citable anchor (no readable top-level README/package.json/Cargo.toml/Makefile with a non-empty first line)"}'
    fi
}

# actions — what an agent can DO next, derived from the DETECTED project type.
# Type detection is by marker-file EXISTENCE and has no span of its own (the
# 619-pfsj C1 lesson); each action is therefore anchored to a citable line
# INSIDE the marker file the detection keyed on.
_gi_actions_json() {
    _gia_dir="${1:-.}"
    _gia_types=$(detect_project_types "$_gia_dir" 2>/dev/null || true)
    _gia_parts=""
    _gia_cits='[]'
    if [ -f "$_gia_dir/package.json" ]; then
        _gia_key=""
        _gia_n=""
        for _gia_t in '"name"' '"scripts"' '"version"'; do
            _gia_n=$(grep -nF "$_gia_t" "$_gia_dir/package.json" 2>/dev/null | head -1 | cut -d: -f1 || true)
            if [ -n "$_gia_n" ]; then
                _gia_key="$_gia_t"
                break
            fi
        done
        if [ -n "$_gia_key" ]; then
            _gia_parts="${_gia_parts}node (package.json ${_gia_key} line ${_gia_n}): npm install, then npm test / npm run <script>. "
            _gia_cits=$(printf '%s' "$_gia_cits" | jq \
                --argjson n "$_gia_n" --arg k "$_gia_key" \
                '. + [{path: "package.json", line_start: $n, line_end: $n, kind: "code",
                       authority: {key: $k, source: "package.json"}}]')
        fi
    fi
    if [ -f "$_gia_dir/Cargo.toml" ]; then
        _gia_hdr=""
        _gia_hn=""
        for _gia_h in '[package]' '[workspace]'; do
            _gia_hn=$(grep -nF "$_gia_h" "$_gia_dir/Cargo.toml" 2>/dev/null | head -1 | cut -d: -f1 || true)
            if [ -n "$_gia_hn" ]; then
                _gia_hdr="$_gia_h"
                break
            fi
        done
        if [ -n "$_gia_hdr" ]; then
            _gia_parts="${_gia_parts}rust (Cargo.toml ${_gia_hdr} line ${_gia_hn}): cargo build, cargo test. "
            _gia_cits=$(printf '%s' "$_gia_cits" | jq \
                --argjson n "$_gia_hn" --arg k "$_gia_hdr" \
                '. + [{path: "Cargo.toml", line_start: $n, line_end: $n, kind: "code",
                       authority: {key: $k, source: "Cargo.toml"}}]')
        fi
    fi
    if [ -f "$_gia_dir/Makefile" ]; then
        _gia_tgt=$(grep -nE '^[A-Za-z0-9][A-Za-z0-9_./-]*[[:space:]]*:' "$_gia_dir/Makefile" 2>/dev/null | grep -v ':=' | head -1 || true)
        if [ -n "$_gia_tgt" ]; then
            _gia_f=$(printf '%s\n' "$_gia_tgt" | cut -d: -f1)
            _gia_first=$(printf '%s\n' "$_gia_tgt" | cut -d: -f2 | sed 's/[[:space:]]*$//')
            _gia_parts="${_gia_parts}make (Makefile target ${_gia_first} line ${_gia_f}): make ${_gia_first}. "
            _gia_cits=$(printf '%s' "$_gia_cits" | jq \
                --argjson n "$_gia_f" --arg k "$_gia_first" \
                '. + [{path: "Makefile", line_start: $n, line_end: $n, kind: "code",
                       authority: {key: $k, source: "Makefile"}}]')
        fi
    fi
    if [ "$(printf '%s' "$_gia_cits" | jq 'length' 2>/dev/null || echo 0)" -gt 0 ]; then
        jq -cn --arg t "${_gia_types:-none}" --arg a "${_gia_parts% }" --argjson c "$_gia_cits" \
            '{answer: ("Actions (detected types: " + $t + "): " + $a), citations: $c}'
    else
        jq -cn --arg t "${_gia_types:-none}" \
            '{answer: null, citations: [],
              reason: ("actions question — detected types (" + $t + ") carry no citable action span (no package.json, Cargo.toml, or Makefile with an anchorable line)")}'
    fi
}

# build_generic_index — the ENRICHED generic project index (order 669-egjn).
# One JSON document: path/types/meta (the pre-669-egjn subset, unchanged for
# existing readers) plus the commands/layout/actions deterministic classes,
# each carrying its own answer text and ratified Citation structs.
# `project-info.sh index [dir]` prints it and exits before the JSON-RPC loop
# (the order-569 subcommand pattern), so the tmpfs index builder
# (lib-common.sh discover_generic_project) and any litmus obtain the exact
# document the answer lane serves from.
build_generic_index() {
    _bgi_dir="${1:-.}"
    _bgi_types=$(detect_project_types "$_bgi_dir" 2>/dev/null || true)
    _bgi_meta=$(get_project_metadata "$_bgi_dir" 2>/dev/null || true)
    printf '%s' "$_bgi_meta" | jq -e . >/dev/null 2>&1 || _bgi_meta='{}'
    _bgi_cmds=$(_gi_commands_json "$_bgi_dir")
    _bgi_lay=$(_gi_layout_json "$_bgi_dir")
    _bgi_act=$(_gi_actions_json "$_bgi_dir")
    jq -n --arg path "$_bgi_dir" --arg types "$_bgi_types" \
        --argjson meta "$_bgi_meta" --argjson commands "$_bgi_cmds" \
        --argjson layout "$_bgi_lay" --argjson actions "$_bgi_act" \
        '{path: $path, types: $types, meta: $meta,
          commands: $commands, layout: $layout, actions: $actions}'
}

# ── Workspace discovery (sibling projects) ───────────────────
# @trace gap:ON-006
# Discovers sibling git projects in the parent directory of the current project.
# Returns JSON array of projects with basic metadata (name, description, managed).
discover_sibling_projects() {
    local current_project_dir="${1:-.}"
    local parent_dir
    parent_dir=$(dirname "$current_project_dir")

    local projects_json=""

    # Scan parent directory for git projects
    if [ -d "$parent_dir" ]; then
        for project_dir in "$parent_dir"/*; do
            # Skip if not a directory or doesn't have .git
            # @trace spec:forge-environment-discoverability, gap:multi-workdir-git-worktree-handling
            # Use [ -e ] instead of [ -d ] to support git worktrees, which have .git as a file
            if [ ! -d "$project_dir" ] || [ ! -e "$project_dir/.git" ]; then
                continue
            fi

            # Skip the current project itself
            if [ "$(realpath "$project_dir")" = "$(realpath "$current_project_dir")" ]; then
                continue
            fi

            local project_name
            project_name=$(basename "$project_dir")

            # Extract description from README
            local description=""
            if [ -f "$project_dir/README.md" ]; then
                description=$(head -1 "$project_dir/README.md" | sed 's/^# //' | sed 's/^## //' | head -c 100)
            fi

            # Check if Tillandsias-managed
            local is_managed="false"
            [ -f "$project_dir/.tillandsias/config.toml" ] && is_managed="true"

            # Build JSON object for this project
            if [ -z "$projects_json" ]; then
                projects_json="{\"name\":\"$project_name\",\"path\":\"$project_dir\",\"description\":\"$description\",\"managed\":$is_managed}"
            else
                projects_json="$projects_json,{\"name\":\"$project_name\",\"path\":\"$project_dir\",\"description\":\"$description\",\"managed\":$is_managed}"
            fi
        done
    fi

    # Return as JSON array
    if [ -n "$projects_json" ]; then
        echo "[$projects_json]"
    else
        echo "[]"
    fi
}

# ── Plan ledger resolution ────────────────────────────────────
# @trace spec:layered-tools-overlay, spec:forge-environment-discoverability
# ORDER 582-26mm. plan_query must see the FOLDED ledger (base ⊕ plan/index.d/
# fragments), never the base alone — a reader that forgets fragments reports a
# stale ledger with total confidence, and if plan_answer says a packet exists
# while plan_query says it does not, an agent cannot tell which surface lies.
# The compiled CLI loads the overlay; routing plan_query through it makes this
# server's answer agree with forge-plan's by construction.
resolve_plan_index() {
    if [ -n "${TILLANDSIAS_PLAN_INDEX:-}" ] && [ -f "${TILLANDSIAS_PLAN_INDEX}" ]; then
        printf '%s\n' "$TILLANDSIAS_PLAN_INDEX"
        return 0
    fi
    for candidate in \
        "$PWD/plan/index.yaml" \
        "$HOME/src/tillandsias/plan/index.yaml" \
        "$HOME/tillandsias/plan/index.yaml" \
        "/opt/cheatsheets/plan-index.yaml"; do
        if [ -f "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    printf '\n'
}

resolve_plan_bin() {
    if [ -n "${TILLANDSIAS_PLAN_BIN:-}" ] && [ -x "${TILLANDSIAS_PLAN_BIN}" ]; then
        printf '%s\n' "$TILLANDSIAS_PLAN_BIN"
        return 0
    fi
    for candidate in \
        "$HOME/.local/bin/tillandsias-plan" \
        "/usr/local/bin/tillandsias-plan" \
        "/usr/bin/tillandsias-plan"; do
        if [ -x "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    # Cargo-built binary in the checkout this server is serving.
    _idx="$(resolve_plan_index)"
    if [ -n "$_idx" ]; then
        _root="$(dirname "$(dirname "$_idx")")"
        if [ -x "$_root/target/release/tillandsias-plan" ]; then
            printf '%s\n' "$_root/target/release/tillandsias-plan"
            return 0
        fi
    fi
    printf '\n'
}

# ── Engine identity + capability manifest (orders 569, 619-pfsj C3) ─────────
# @trace spec:forge-environment-discoverability, order:619-pfsj
#
# THE PACKAGING DECISION, made explicitly against the order-459 constraint
# (image builds have no network): this generic answer engine is THIS SCRIPT,
# baked into the forge image at /home/forge/.config-overlay/mcp/project-info.sh.
# Zero build, zero vendoring, zero launch-time compilation. That choice has a
# consequence order 531 already taught us to name: the running engine's sources
# are NOT the mounted checkout, so "the launch finished" can never mean "the
# engine behaves as this checkout's contract promises". A forge whose image was
# baked from an older tree runs an older engine while every health signal reads
# green.
#
# So the engine carries its own capability manifest, embedded in the artifact
# itself — the `capabilities` subcommand pattern of order 569, adapted for a
# shell engine where "embedded at compile time" means "literal text in the
# baked script". Two readers, one manifest:
#
#   1. the RUNNING ARTIFACT self-reports: `project-info.sh capabilities`
#      prints this block and exits before the JSON-RPC loop — asked of the
#      artifact, never inferred from the checkout;
#   2. the MOUNTED CHECKOUT's expectation is read TEXTUALLY out of its copy of
#      this file by lib-project-engine-capability.sh (no execution of checkout
#      code, the same discipline as reading capabilities.txt).
#
# Tokens are `[a-z][a-z0-9-]*`, one per line, sorted; `engine-contract-vN` is
# the contract version and MUST be bumped whenever the answer contract changes
# behaviour. v2 = 619-pfsj: typed synthesis refusals + no-inference fallback.
# v3 = 669-h987: project_answer lane routing keyed on the mounted project's
# identity (own plan/index.yaml at the root), not on tool reachability — a
# non-Tillandsias mount always answers from the generic lane.
# v4 = 669-egjn: enriched deterministic subset — commands/layout/actions
# answer CITED from the generic index (`index` subcommand + question classes),
# and the overview README citation is clamped to the file's real line count.
PROJECT_INFO_ENGINE_MANIFEST='
actions-cited
commands-cited
engine-contract-v4
file-summary
find-files
generic-index
generic-lane
git-status
grep-code
layout-cited
no-inference-fallback
plan-lane
plan-query
project-answer
project-info
project-list
project-metadata
project-structure
project-type
read-file
search-code
sibling-projects
synthesis-refusal-typed
typed-refusal
'

if [ "${1:-}" = "capabilities" ]; then
    printf '%s\n' "$PROJECT_INFO_ENGINE_MANIFEST"
    exit 0
fi

# Run with `index [dir]` to print the ENRICHED generic project index (order
# 669-egjn) and exit before the JSON-RPC loop — the document the generic
# answer lane serves the deterministic subset from, and the payload
# lib-common.sh's discover_generic_project persists to tmpfs as index.json.
if [ "${1:-}" = "index" ]; then
    build_generic_index "${2:-.}"
    exit 0
fi

# ── project_answer C2/C5 helpers (order 619-pfsj) ───────────────────────────
# @trace spec:forge-environment-discoverability, order:619-pfsj
#
# _pa_is_synthesis — deterministic question classification, mirroring the
# no-fuzzy discipline of answer.rs::classify: a CLOSED marker vocabulary, no
# model, no scoring. A question is SYNTHESIS-shaped when answering it requires
# composing an explanation rather than looking a fact up — the class C5 says
# must refuse typed when it cannot be served, never be answered with a guess
# or with a deterministic fact dressed up as the asked-for explanation.
#
# Deliberately NOT synthesis: "how do I ..." (a commands question — the
# deterministic subset), "describe ..." (the cited README description IS the
# deterministic answer), and any question the deterministic layer can cite an
# answer for — the plan lane runs FIRST and a cited deterministic answer always
# wins (inference adds recall, never authority).
_pa_is_synthesis() {
    _pas_q=" $(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr '?!.,;:()' ' ') "
    case "$_pas_q" in
        *" why "* | *" explain "* | *" summarize "* | *" summarise "* | \
            *" architecture "* | *" compare "* | *" review "* | \
            *" analyze "* | *" analyse "* | *" recommend "* | \
            *" rationale "* | *" refactor "* | *" redesign "* | \
            *" tradeoff "* | *" tradeoffs "* | *" trade-off "* | *" trade-offs "* | \
            *" how does "* | *" how it works "* | *" should i "* | *" should we "*)
            return 0
            ;;
    esac
    return 1
}

# _pa_deterministic_class — closed keyword routing for the generic lane's
# deterministic question classes (order 669-egjn). Same no-fuzzy discipline as
# _pa_is_synthesis: a CLOSED vocabulary, first match wins, anything unmatched
# falls through to the overview (type/name/description) answer the 619-pfsj
# C1 slice pinned. Synthesis classification runs BEFORE this, so a question
# like "how does the build work" never reaches here. "what's next?" lands on
# the actions class — the C4 promise for the generic lane.
_pa_deterministic_class() {
    _pdc_q=" $(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr '?!.,;:()' ' ') "
    case "$_pdc_q" in
        *" command "* | *" commands "* | *" build "* | *" builds "* | \
            *" compile "* | *" run "* | *" test "* | *" tests "* | *" install "*)
            printf 'commands\n'
            return 0
            ;;
    esac
    case "$_pdc_q" in
        *" layout "* | *" structure "* | *" tree "* | *" directories "* | \
            *" folders "* | *" organized "* | *" organised "*)
            printf 'layout\n'
            return 0
            ;;
    esac
    case "$_pdc_q" in
        *" action "* | *" actions "* | *" next "*)
            printf 'actions\n'
            return 0
            ;;
    esac
    printf 'overview\n'
}

# _pa_generic_class_envelope <commands|layout|actions> — wrap one enriched
# index class in the ratified envelope. Citations present -> confidence=exact
# (a deterministic index lookup); none -> the one pinned refusal constructor
# with the derivation's own reason. Freshness and citation_root follow the
# same discipline as the overview answer below.
_pa_generic_class_envelope() {
    _pgc_json=$(build_generic_index "." | jq -c --arg k "$1" '.[$k] // {}' 2>/dev/null || echo '{}')
    _pgc_n=$(printf '%s' "$_pgc_json" | jq -r '.citations | length' 2>/dev/null || echo 0)
    case "$_pgc_n" in
        '' | *[!0-9]*) _pgc_n=0 ;;
    esac
    if [ "$_pgc_n" -gt 0 ]; then
        _pgc_commit=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
        _pgc_now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        _pgc_root=$(pwd -P)
        printf '%s' "$_pgc_json" | jq \
            --arg commit "$_pgc_commit" --arg now "$_pgc_now" --arg root "$_pgc_root" \
            '{answer: .answer, citations: .citations,
              freshness: {source_commit: $commit, indexed_at: $now},
              confidence: "exact", citation_root: $root}'
    else
        _pa_refusal "$(printf '%s' "$_pgc_json" | jq -r '.reason // "no citable evidence in the generic index for this question class"' 2>/dev/null || printf 'no citable evidence in the generic index for this question class')"
    fi
}

# _pa_refusal <reason> — the typed refusal in the ratified envelope. The
# rendering is pinned by answer.rs (`unsupported: <reason>`, zero citations,
# confidence=unsupported, a real freshness struct) so verify-answer accepts it
# and an agent can branch on it without parsing prose. Never an error string,
# never a silent degrade.
_pa_refusal() {
    _par_commit=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
    _par_now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    _par_root=$(pwd -P)
    jq -n \
        --arg reason "$1" \
        --arg commit "$_par_commit" \
        --arg now "$_par_now" \
        --arg root "$_par_root" \
        '{
            answer: ("unsupported: " + $reason),
            citations: [],
            freshness: {source_commit: $commit, indexed_at: $now},
            confidence: "unsupported",
            citation_root: $root
        }'
}

# _pa_probe_inference — is a local inference endpoint available? Asked through
# the EXISTING probe (lib-inference-state.sh, orders 392/392a): same endpoint
# resolution (TILLANDSIAS_INFERENCE_ENDPOINT, default http://inference:11434),
# same 1s budget, same closed reason vocabulary. No new config surface. A
# missing helper is its own named fact (probe-helper-missing), never a silent
# "unavailable" — an absent probe reporting a verdict would be the same lie
# `experts: ready` told in order 531.
_pa_probe_inference() {
    TILLANDSIAS_INFERENCE_STATE="unknown"
    TILLANDSIAS_INFERENCE_REASON="probe-helper-missing"
    for _pai_lib in \
        "${TILLANDSIAS_INFERENCE_STATE_LIB:-}" \
        "${BASH_SOURCE[0]%/*}/../../lib-inference-state.sh" \
        "/usr/local/lib/tillandsias/lib-inference-state.sh"; do
        if [ -n "$_pai_lib" ] && [ -r "$_pai_lib" ]; then
            # shellcheck source=/dev/null
            . "$_pai_lib"
            tillandsias_inference_state || true
            return 0
        fi
    done
    return 0
}

# _pa_synthesis_refusal — C2/C5: the typed refusal for a synthesis question the
# deterministic layer could not cite an answer for. It NAMES the missing
# capability as a machine token, and the two branches are deliberately
# distinct: blaming the endpoint when the endpoint is fine (or vice versa)
# would send an agent to fix the wrong thing.
#
#   missing_capability=local-inference  no endpoint is available; the reason is
#                                       the probe's closed vocabulary
#                                       (endpoint-unreachable, no-models, ...)
#   missing_capability=synthesis-tier   the endpoint IS ready but no synthesis
#                                       tier is wired into this surface yet
#                                       (the 397+ family owns the tiers)
_pa_synthesis_refusal() {
    _pa_probe_inference
    if [ "${TILLANDSIAS_INFERENCE_STATE:-unknown}" = "ready" ]; then
        _pa_refusal "synthesis question — missing_capability=synthesis-tier inference_state=ready inference_reason=-; the deterministic layer holds no citable answer for it, and no synthesis tier is wired into project_answer yet (inference adds recall, never authority — citations stay deterministic-layer products). Deterministic questions (type, status, commands, layout, actions) still answer."
    else
        _pa_refusal "synthesis question — missing_capability=local-inference inference_state=${TILLANDSIAS_INFERENCE_STATE:-unknown} inference_reason=${TILLANDSIAS_INFERENCE_REASON:--}; the deterministic layer holds no citable answer for it and no local inference endpoint is available to add recall. Deterministic questions (type, status, commands, layout, actions) still answer from the index alone."
    fi
}

# Read JSON-RPC requests from stdin, respond on stdout
while IFS= read -r line; do
    [ -n "$line" ] || continue
    method=$(echo "$line" | jq -r '.method // empty')
    id_json=$(printf '%s' "$line" | jq -c '.id // null')

    case "$method" in
        "initialize")
            echo '{"jsonrpc":"2.0","id":'"$id_json"',"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"project-info","version":"1.0.0"}}}'
            ;;
        "tools/list")
            echo '{"jsonrpc":"2.0","id":'"$id_json"',"result":{"tools":[{"name":"project_structure","description":"List project files (max depth 3, max 100 files)","inputSchema":{"type":"object","properties":{"depth":{"type":"number","default":3}}}},{"name":"file_summary","description":"Show line count and first lines of a file","inputSchema":{"type":"object","properties":{"path":{"type":"string"},"lines":{"type":"number","default":5}},"required":["path"]}},{"name":"search_code","description":"Search for a pattern across source files (glob supports path patterns)","inputSchema":{"type":"object","properties":{"pattern":{"type":"string"},"glob":{"type":"string","default":"*"}},"required":["pattern"]}},{"name":"find_files","description":"Find files by glob pattern (recursive, path-aware)","inputSchema":{"type":"object","properties":{"pattern":{"type":"string","description":"Glob pattern e.g. **/*.sh, plan/index.yaml"},"path":{"type":"string","description":"Root directory (default: .)"}},"required":["pattern"]}},{"name":"grep_code","description":"Search for a pattern across source files with path-aware glob","inputSchema":{"type":"object","properties":{"pattern":{"type":"string"},"include":{"type":"string","description":"File glob pattern (default: *)"},"path":{"type":"string","description":"Root directory (default: .)"}},"required":["pattern"]}},{"name":"git_status","description":"Show working tree status as structured JSON data","inputSchema":{"type":"object","properties":{}}},{"name":"read_file","description":"Read a file with offset and limit support","inputSchema":{"type":"object","properties":{"path":{"type":"string"},"offset":{"type":"number","description":"Line number to start from (1-indexed, default: 0 for beginning)"},"limit":{"type":"number","description":"Number of lines to read (default: all)"}},"required":["path"]}},{"name":"plan_query","description":"Query plan/index.yaml for matching work packets by status, role, or capability tags","inputSchema":{"type":"object","properties":{"status":{"type":"string","description":"Filter by status (ready, pending, in_progress, blocked, completed, etc.)"},"pickup_role":{"type":"string","description":"Filter by pickup_role substring"},"capability_tags":{"type":"array","items":{"type":"string"},"description":"Filter by capability tags (all must match)"},"limit":{"type":"number","description":"Max results (default: 20)"}}}},{"name":"project_answer","description":"Query project knowledge, architecture, or status with cited response envelope","inputSchema":{"type":"object","properties":{"question":{"type":"string","description":"Question about project structure, build, status, or plan"}},"required":["question"]}},{"name":"project_list","description":"Discover available projects in ~/src/ (git repos)","inputSchema":{"type":"object","properties":{}}},{"name":"sibling_projects","description":"Discover sibling projects in parent directory","inputSchema":{"type":"object","properties":{"path":{"type":"string","default":"."}},"required":[]}},{"name":"project_info","description":"Get detailed info about a project at a path","inputSchema":{"type":"object","properties":{"path":{"type":"string","default":"."}},"required":[]}},{"name":"project_type","description":"Detect project type from marker files","inputSchema":{"type":"object","properties":{"path":{"type":"string","default":"."}},"required":[]}},{"name":"project_metadata","description":"Get structured metadata about a project","inputSchema":{"type":"object","properties":{"path":{"type":"string","default":"."},"name":{"type":"string"}},"required":[]}}]}}'
            ;;
        "tools/call")
            tool=$(echo "$line" | jq -r '.params.name // empty')
            args=$(echo "$line" | jq -c '.params.arguments // {}')
            error_code=""
            error_msg=""
            case "$tool" in
                "project_structure")
                    depth=$(echo "$args" | jq -r '.depth // 3')
                    result=$(find . -maxdepth "$depth" -type f 2>&1 | head -100 || echo "Failed to list files")
                    ;;
                "file_summary")
                    filepath=$(echo "$args" | jq -r '.path')
                    lines=$(echo "$args" | jq -r '.lines // 5')
                    if [ -f "$filepath" ]; then
                        line_count=$(wc -l < "$filepath")
                        preview=$(head -n "$lines" "$filepath")
                        result="Lines: ${line_count}
--- first ${lines} lines ---
${preview}"
                    else
                        result="File not found: $filepath"
                    fi
                    ;;
                "search_code")
                    pattern=$(echo "$args" | jq -r '.pattern')
                    file_glob=$(echo "$args" | jq -r '.glob // "*"')
                    # Use find + grep for path-aware glob matching (fixes Bug 1)
                    # Only strip **/ prefix when pattern starts with **/ (not a path)
                    if [[ "$file_glob" == "**/"* ]]; then
                        glob_for_find="${file_glob#**/}"
                    else
                        glob_for_find="$file_glob"
                    fi
                    # Capping the FILE list produced SILENT FALSE NEGATIVES. `find`
                    # emits in readdir order, not sorted, and that order shifts as
                    # the tree is written to. With `head -200` against 260 matching
                    # .sh files, ~60 were dropped ARBITRARILY and differently on
                    # each call — so `search_code(pattern, glob="*.sh")` reported
                    # "No matches found" for a pattern that is plainly in
                    # ./build.sh (find position 14; the captured list happened to
                    # start at position 15). A search tool that says "not found"
                    # for something present is worse than no search tool: the agent
                    # concludes the code does not exist and acts on it.
                    #
                    # Search EVERY matching file. Cap the RESULTS instead, and say
                    # so when the cap is hit, so truncation is never mistaken for
                    # absence.
                    # || true prevents set -e killing the script on SIGPIPE.
                    if [[ "$glob_for_find" == *"/"* ]]; then
                        files=$(find . -type f -path "*/$glob_for_find" 2>/dev/null || true)
                    else
                        files=$(find . -type f -name "$glob_for_find" 2>/dev/null || true)
                    fi
                    if [ -n "$files" ]; then
                        all_hits=$(echo "$files" | xargs grep -In "$pattern" 2>/dev/null || true)
                        hit_count=$(printf '%s' "$all_hits" | grep -c . || true)
                        result=$(printf '%s' "$all_hits" | head -50 || true)
                        if [ "${hit_count:-0}" -gt 50 ]; then
                            result="${result}
[truncated: showing 50 of ${hit_count} matches — narrow the glob or pattern to see the rest]"
                        fi
                    fi
                    if [ -z "${result:-}" ]; then
                        result="No matches found"
                    fi
                    ;;
                "project_list")
                    # @trace spec:forge-environment-discoverability, gap:multi-workdir-git-worktree-handling
                    # Discover projects in ~/src/ by scanning for .git/ directories or .git files (for git worktrees)
                    # Return JSON array of projects with metadata
                    project_data="[]"
                    if [ -d "$HOME/src" ]; then
                        projects_json=""
                        for project_dir in "$HOME/src"/*; do
                            # Use [ -e ] instead of [ -d ] to support git worktrees, which have .git as a file
                            if [ -d "$project_dir" ] && [ -e "$project_dir/.git" ]; then
                                project_name=$(basename "$project_dir")
                                description=""
                                # Try to extract first line of README as description
                                if [ -f "$project_dir/README.md" ]; then
                                    description=$(head -1 "$project_dir/README.md" | sed 's/^# //' | sed 's/^## //' | head -c 100)
                                fi
                                # Check if Tillandsias-managed
                                is_managed="false"
                                [ -f "$project_dir/.tillandsias/config.toml" ] && is_managed="true"

                                if [ -z "$projects_json" ]; then
                                    projects_json="{\"name\":\"$project_name\",\"description\":\"$description\",\"managed\":$is_managed}"
                                else
                                    projects_json="$projects_json,{\"name\":\"$project_name\",\"description\":\"$description\",\"managed\":$is_managed}"
                                fi
                            fi
                        done
                        [ -n "$projects_json" ] && project_data="[$projects_json]"
                    fi
                    result="$project_data"
                    ;;
                "sibling_projects")
                    # @trace gap:ON-006
                    # Discover sibling projects in the parent directory
                    path=$(echo "$args" | jq -r '.path // "."')
                    result=$(discover_sibling_projects "$path")
                    ;;
                "project_type")
                    # @trace spec:forge-environment-discoverability
                    # Detect project type from marker files
                    path=$(echo "$args" | jq -r '.path // "."')
                    result=$(detect_project_types "$path")
                    ;;
                "project_info")
                    # @trace spec:forge-environment-discoverability
                    # Get detailed project info (deprecated in favor of project_metadata)
                    path=$(echo "$args" | jq -r '.path // "."')
                    result=$(get_project_metadata "$path")
                    ;;
                "project_metadata")
                    # @trace spec:forge-environment-discoverability
                    # Get structured metadata about a project
                    path=$(echo "$args" | jq -r '.path // "."')
                    name=$(echo "$args" | jq -r '.name // "unknown"')
                    result=$(get_project_metadata "$path" "$name")
                    ;;
                "find_files")
                    pattern=$(echo "$args" | jq -r '.pattern')
                    path=$(echo "$args" | jq -r '.path // "."')
                    if [[ "$pattern" == "**/"* ]]; then
                        find_pattern="${pattern#**/}"
                    else
                        find_pattern="$pattern"
                    fi
                    # || true prevents set -e from killing script on SIGPIPE
                    if [[ "$find_pattern" == *"/"* ]]; then
                        result=$(find "$path" -type f -path "*/$find_pattern" 2>/dev/null | head -200 || true)
                    else
                        result=$(find "$path" -type f -name "$find_pattern" 2>/dev/null | head -200 || true)
                    fi
                    if [ -z "${result:-}" ]; then
                        result="No files found"
                    fi
                    ;;
                "grep_code")
                    pattern=$(echo "$args" | jq -r '.pattern')
                    include=$(echo "$args" | jq -r '.include // "*"')
                    path=$(echo "$args" | jq -r '.path // "."')
                    if [[ "$include" == "**/"* ]]; then
                        glob_for_find="${include#**/}"
                    else
                        glob_for_find="$include"
                    fi
                    # || true prevents set -e from killing script on SIGPIPE
                    if [[ "$glob_for_find" == *"/"* ]]; then
                        files=$(find "$path" -type f -path "*/$glob_for_find" 2>/dev/null | head -200 || true)
                    else
                        files=$(find "$path" -type f -name "$glob_for_find" 2>/dev/null | head -200 || true)
                    fi
                    if [ -n "$files" ]; then
                        result=$(echo "$files" | xargs grep -In "$pattern" 2>/dev/null | head -50 || true)
                    fi
                    if [ -z "${result:-}" ]; then
                        result="No matches found"
                    fi
                    ;;
                "git_status")
                    porcelain=$(git status --porcelain 2>/dev/null) || porcelain=""
                    if [ -z "$porcelain" ]; then
                        if [ -e ".git" ]; then
                            result='{"files":[],"porcelain":""}'
                        else
                            result='{"error":"not a git repository or git not available"}'
                        fi
                    else
                        # Rewritten from python3 (tlatoani_hard_no_python). jq is present in the forge
# image; ruby is NOT, so jq is the correct tool here rather than the host's.
                        result=$(printf '%s\n' "$porcelain" | awk 'NF {
                            staged = substr($0, 1, 1);
                            working = substr($0, 2, 1);
                            path = substr($0, 4);
                            print staged "\t" working "\t" path;
                        }' | jq -R -s '
                            [ split("\n")[] | select(length > 0) | split("\t")
                              | { staged_status: .[0], working_status: .[1], path: .[2] }
                              | if (.path | test(" -> ")) then
                                    (.path | split(" -> ")) as $p
                                    | { path: $p[0], new_path: $p[1],
                                        staged_status: .staged_status,
                                        working_status: .working_status }
                                else . end
                            ] | { files: . }')
                    fi
                    ;;
                "read_file")
                    filepath=$(echo "$args" | jq -r '.path')
                    offset=$(echo "$args" | jq -r '.offset // 0')
                    limit=$(echo "$args" | jq -r '.limit // 0')
                    if [ ! -f "$filepath" ]; then
                        result="File not found: $filepath"
                    else
                        line_count=$(wc -l < "$filepath")
                        if [ "$offset" -gt 0 ] && [ "$limit" -gt 0 ]; then
                            result=$(tail -n +"$offset" "$filepath" | head -n "$limit")
                            result="${result}
---
(offset=$offset limit=$limit of $line_count lines)"
                        elif [ "$offset" -gt 0 ]; then
                            result=$(tail -n +"$offset" "$filepath")
                            result="${result}
---
(offset=$offset of $line_count lines)"
                        elif [ "$limit" -gt 0 ]; then
                            result=$(head -n "$limit" "$filepath")
                            result="${result}
---
(limit=$limit of $line_count lines)"
                        else
                            result=$(cat "$filepath")
                            result="${result}
---
($line_count lines total)"
                        fi
                    fi
                    ;;
                "plan_query")
                    filter_args=$(echo "$args" | jq -c '.')
                    # ORDER 582-26mm. Was a DIRECT yq read of plan/index.yaml —
                    # the BASE only, so a fragment-only packet (plan/index.d/)
                    # was invisible here while forge-plan's plan_* tools saw it:
                    # the exact disagreement this packet exists to kill. Now
                    # routes through the compiled CLI, which folds base ⊕
                    # fragments; the yq+jq projection and filter contract is
                    # reproduced by `query --json` so callers see no change.
                    _pbin="$(resolve_plan_bin)"
                    _pidx="$(resolve_plan_index)"
                    if [ -z "$_pbin" ] || [ -z "$_pidx" ]; then
                        result="No matching packets found"
                    else
                        _qargs=()
                        _st=$(echo "$filter_args" | jq -r '.status // empty')
                        _rl=$(echo "$filter_args" | jq -r '.pickup_role // empty')
                        _lm=$(echo "$filter_args" | jq -r '.limit // 20')
                        [ -n "$_st" ] && _qargs+=(--status "$_st")
                        [ -n "$_rl" ] && _qargs+=(--role "$_rl")
                        while IFS= read -r _t; do
                            [ -n "$_t" ] && _qargs+=(--tag "$_t")
                        done < <(echo "$filter_args" | jq -r '.capability_tags[]? // empty')
                        _qargs+=(--limit "$_lm" --json)
                        result=$("$_pbin" --index "$_pidx" query "${_qargs[@]}" 2>/dev/null || true)
                        if [ -z "$result" ] || [ "$result" = "[]" ]; then
                            result="No matching packets found"
                        fi
                    fi
                    ;;

                "project_answer")
                    _q=$(echo "$args" | jq -r '.question // empty')
                    if [ -z "$_q" ]; then
                        error_code=-32602
                        error_msg="Invalid params for tool 'project_answer': missing required 'question'"
                    else
                        # Two-lane routing (C4), ORDER 669-h987. The lane is
                        # chosen on evidence about the MOUNTED project — its own
                        # plan/index.yaml at the project root — never on tool
                        # reachability. The pre-669-h987 gate
                        # (resolve_plan_bin && resolve_plan_index) resolved the
                        # $HOME/src/tillandsias fallbacks too, so on a dev host
                        # with a Tillandsias checkout lying around a
                        # NON-Tillandsias project's question misrouted into that
                        # checkout's plan ledger and answered from the wrong
                        # project. Only a Tillandsias-shaped mounted project
                        # (own plan/index.yaml at the root) enters the plan
                        # lane, and it answers from ITS OWN ledger
                        # (TILLANDSIAS_PLAN_INDEX stays an explicit override for
                        # operator pins and test stubs); everything else answers
                        # from the generic lane, whatever the tooling resolves.
                        _pa_plan_lane=0
                        if [ -f "./plan/index.yaml" ]; then
                            _pa_plan_lane=1
                            _pbin="$(resolve_plan_bin)"
                            if [ -n "${TILLANDSIAS_PLAN_INDEX:-}" ] && [ -f "${TILLANDSIAS_PLAN_INDEX}" ]; then
                                _pidx="${TILLANDSIAS_PLAN_INDEX}"
                            else
                                _pidx="${PWD}/plan/index.yaml"
                            fi
                            [ -n "$_pbin" ] || _pa_plan_lane=0
                        fi
                        if [ "$_pa_plan_lane" = "1" ]; then
                            # DETERMINISTIC FIRST (C5): the plan engine runs
                            # before any synthesis consideration, so a question
                            # it can cite an answer for is answered — with no
                            # inference endpoint, with a dead one, always.
                            # Inference adds recall, never authority.
                            _ans=$("$_pbin" --index "$_pidx" answer "$_q" 2>/dev/null || true)
                            _conf=$(printf '%s' "$_ans" | jq -r '.confidence // empty' 2>/dev/null || true)
                            if [ -z "$_ans" ] || [ -z "$_conf" ]; then
                                # The engine produced no envelope at all. This
                                # used to emit a hand-rolled approximation
                                # (freshness: "now", no `unsupported:` prefix)
                                # that verify-answer REFUSED — the exact class
                                # of defect the C1 slice removed from the
                                # generic lane. Route through the one pinned
                                # refusal constructor instead.
                                result=$(_pa_refusal "the plan engine produced no answer envelope for this question (engine=${_pbin})")
                            elif [ "$_conf" = "unsupported" ] && _pa_is_synthesis "$_q"; then
                                # C2: the deterministic layer refused AND the
                                # question needs synthesis — refuse TYPED,
                                # naming the missing capability, instead of
                                # forwarding a refusal that talks about ledger
                                # tokens for a question that was never about
                                # the ledger.
                                result=$(_pa_synthesis_refusal)
                            else
                                result="$_ans"
                            fi
                        elif _pa_is_synthesis "$_q"; then
                            # Generic lane, synthesis question (C2/C5). The
                            # generic deterministic answer below is
                            # question-blind (it reports type/name/description
                            # whatever was asked), so classification must gate
                            # it: answering "why is the parser slow?" with
                            # "Project type: node" would be a wrong answer
                            # dressed as confidence=exact. Refuse typed,
                            # naming what is actually missing.
                            result=$(_pa_synthesis_refusal)
                        elif _pa_gclass=$(_pa_deterministic_class "$_q") && [ "$_pa_gclass" != "overview" ]; then
                            # ORDER 669-egjn — the enriched deterministic
                            # subset: commands, layout, and actions answer
                            # CITED from the generic index (marker-file spans,
                            # tree-walk anchor, detected-type actions), or
                            # refuse typed when the index holds nothing
                            # citable for the class. Questions outside the
                            # closed class vocabulary keep the overview
                            # answer below.
                            result=$(_pa_generic_class_envelope "$_pa_gclass")
                        else
                            # Generic project index lane.
                            #
                            # Order 619-pfsj. Two defects fixed here, both of which made
                            # this lane LOOK correct while failing the project's own
                            # contract:
                            #
                            # 1. CITATIONS WERE BARE STRINGS ("./README.md:1-5"). The
                            #    canonical envelope requires a Citation STRUCT
                            #    {path,line_start,line_end,kind}, so
                            #    `tillandsias-plan verify-answer` REFUSED every envelope
                            #    this lane produced — on both the Tillandsias repo and the
                            #    generic fixture — with "invalid type: string, expected
                            #    struct Citation". The plan lane above returns
                            #    tillandsias-plan's own envelope and verifies clean, so the
                            #    two lanes were emitting incompatible shapes under one tool
                            #    name. Exit criterion 1 of 619-pfsj is exactly
                            #    "verify-answer-clean on a Tillandsias and a non-Tillandsias
                            #    fixture", and it was failing on both.
                            #
                            # 2. `description` was the README's first line verbatim, which
                            #    on this repo is the opening ``` of an ASCII-art block — the
                            #    answer literally read 'Description: ```text'. A fenced or
                            #    empty first line is not a description; fall back to the
                            #    directory name rather than emit fence syntax as prose.
                            #
                            # confidence stays "high" only when a real description was
                            # found; a name-only answer is "partial", because reporting
                            # high confidence in a fallback is the same silent-default
                            # failure as 627-cx24.
                            _p_types=$(detect_project_types ".")
                            _p_meta=$(get_project_metadata ".")
                            _readme=""
                            for _c in README.md readme.md README; do
                                [ -f "./$_c" ] && { _readme="$_c"; break; }
                            done
                            _desc=$(printf '%s' "$_p_meta" | jq -r '.description // ""')
                            case "$_desc" in
                                '```'*|'~~~'*|'') _desc="" ;;
                            esac
                            # ORDER 669-egjn — clamp the README citation to
                            # the file's REAL line count. The pre-669-egjn
                            # lane cited lines 1-5 unconditionally, so a
                            # README shorter than 5 lines made verify-answer
                            # refuse a truthful confidence=exact answer
                            # ("citation line range runs past end of file").
                            # awk counts a final unterminated line, which
                            # `wc -l` would miss.
                            _rlines=1
                            if [ -n "$_readme" ]; then
                                _rlines=$(awk 'END { print NR }' "./$_readme" 2>/dev/null || echo 1)
                                case "$_rlines" in
                                    '' | *[!0-9]* | 0) _rlines=1 ;;
                                esac
                            fi
                            # The canonical envelope: citations are structs with an
                            # `authority` map, `freshness` is a struct (NOT the string
                            # "now"), `confidence` is a lowercase enum, and `citation_root`
                            # anchors relative paths so the verifier can resolve them.
                            # This lane emitted a hand-rolled approximation of all four.
                            _root=$(pwd -P)
                            _commit=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
                            _now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
                            result=$(jq -n \
                                --arg types "$_p_types" \
                                --arg readme "$_readme" \
                                --arg desc "$_desc" \
                                --arg root "$_root" \
                                --arg commit "$_commit" \
                                --arg now "$_now" \
                                --argjson rlines "$_rlines" \
                                --argjson meta "$_p_meta" \
                                '{
                                    # A TYPED REFUSAL when nothing citable was found
                                    # (exit criterion 2). The verifier enforces that an
                                    # `unsupported` answer render as "unsupported: <reason>"
                                    # — it may not dress an uncited guess as a fact.
                                    #
                                    # Type detection is by marker-file EXISTENCE, so it has
                                    # no citable span: there is no text in Cargo.toml that
                                    # "rust" appears in. Reporting the types is therefore
                                    # part of the REASON, not an evidenced claim.
                                    answer: (if ($readme == "" or $desc == "") then
                                                 ("unsupported: no citable project description"
                                                  + (if $readme == "" then " (no README found)"
                                                     else " (README line 1 is a fence or empty)" end)
                                                  + "; marker files indicate types: "
                                                  + (if $types == "" then "none" else $types end)
                                                  + " — detection is by file existence and carries no citable span")
                                             else
                                                 ("Project type: " + $types
                                                  + "\nName: " + $meta.name
                                                  + "\nPath: " + $meta.path
                                                  + "\nDescription: " + $desc)
                                             end),
                                    # A citation is emitted ONLY when there is a claim the
                                    # cited span actually supports. verify-answer requires
                                    # authority.key on a non-plan citation — the text that
                                    # must appear inside the span — precisely so a citation
                                    # cannot be decorative. With no description there is no
                                    # README-backed claim, so citing it would be exactly the
                                    # unverifiable gesture that rule forbids: the type/name
                                    # facts come from marker files and the directory, not
                                    # from the README.
                                    citations: (if ($readme == "" or $desc == "") then [] else [{
                                        path: $readme,
                                        line_start: 1,
                                        # ORDER 669-egjn: never past EOF — a
                                        # 3-line README cites 1-3.
                                        line_end: (if $rlines < 5 then $rlines else 5 end),
                                        kind: "code",
                                        authority: {
                                            key: $desc,
                                            project: $meta.name,
                                            types: $types
                                        }
                                    }] end),
                                    freshness: {
                                        source_commit: $commit,
                                        indexed_at: $now
                                    },
                                    confidence: (if ($readme == "" or $desc == "") then "unsupported" else "exact" end),
                                    citation_root: $root
                                }')
                        fi
                    fi
                    ;;

                *)
                    error_code=-32601
                    error_msg="Unknown tool: $tool"
                    ;;
            esac

            if [ -n "$error_code" ]; then
                _err_escaped=$(printf '%s' "$error_msg" | jq -Rs .)
                echo '{"jsonrpc":"2.0","id":'"$id_json"',"error":{"code":'"$error_code"',"message":'"$_err_escaped"'}}'
            else
                # Escape the result for JSON
                escaped=$(echo "$result" | jq -Rs .)
                echo '{"jsonrpc":"2.0","id":'"$id_json"',"result":{"content":[{"type":"text","text":'"$escaped"'}]}}'
            fi
            ;;
        "prompts/list")
            # @trace spec:browser-isolation-tray-integration, spec:opencode-web-session-otp
            # MCP spec: respond to prompts/list even when no prompts exist.
            # Silence here hangs OpenCode's /command endpoint for 60s.
            echo '{"jsonrpc":"2.0","id":'"$id_json"',"result":{"prompts":[]}}'
            ;;
        "resources/list")
            echo '{"jsonrpc":"2.0","id":'"$id_json"',"result":{"resources":[]}}'
            ;;
        "resources/templates/list")
            echo '{"jsonrpc":"2.0","id":'"$id_json"',"result":{"resourceTemplates":[]}}'
            ;;
        "notifications/initialized")
            # Client acknowledgment - no response needed
            ;;
        *)
            # @trace spec:browser-isolation-tray-integration, spec:opencode-web-session-otp
            # Respond to unknown methods with MCP's "method not found" error
            # so OpenCode doesn't stall 60s waiting for a reply that never comes.
            if [ -n "$id_json" ] && [ "$id_json" != "null" ]; then
                echo '{"jsonrpc":"2.0","id":'"$id_json"',"error":{"code":-32601,"message":"Method not found: '"$method"'"}}'
            fi
            ;;
    esac
done
