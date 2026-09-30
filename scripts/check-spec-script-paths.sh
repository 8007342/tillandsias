#!/usr/bin/env bash
# @trace order:815-yace, spec:ci-release
#
# check-spec-script-paths.sh — every `scripts/...` path an active spec names
# must resolve in the tree.
#
# WHY. openspec/specs/project-summarizers/spec.md required six summarizers
# under `scripts/summarizers/`; that directory never existed, two of the six
# were never committed and two ship under other names. The bound litmus grepped
# a cheatsheet for ONE name, which exists, so every step passed and the
# enumeration rotted green (815-yace). A spec's list of scripts is a claim about
# the tree, and nothing checked it.
#
# WHAT IT READS. Every openspec/specs/*/spec.md, for tokens shaped
# `scripts/<path>.<sh|ps1|lua|rs|yaml|md>`. A token resolves when that path
# exists relative to the repository root.
#
# TWO WAYS A PATH MAY BE ABSENT, both named, neither silent:
#   1. A line carrying `spec-path-absent: ok (<reason>)` (in an HTML comment,
#      so it does not render): a deliberate negative, such as a requirement that
#      a script MUST NOT be invoked.
#   2. An entry in the BASELINE (scripts/spec-script-paths-baseline.txt,
#      `<spec>\t<path>\t<reason>`): drift that predates this check, listed with
#      its reason. The baseline is a BURNDOWN list. A NEW unresolved path is
#      refused; a baselined path that now resolves prints a note asking for the
#      entry to be removed.
#
# Verdicts (last line):
#   ok:spec-script-paths:<resolved>-resolved,<baselined>-baselined,<exempt>-exempt
#   blocked:spec-script-paths:<n>-unresolved      (exit 1)
#   unavailable:spec-script-paths:<reason>        (exit 2)
#
# Seams (fixtures): TILLANDSIAS_SPEC_PATHS_SPECS (spec dir),
# TILLANDSIAS_SPEC_PATHS_ROOT (resolution root),
# TILLANDSIAS_SPEC_PATHS_BASELINE (baseline file).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPECS="${TILLANDSIAS_SPEC_PATHS_SPECS:-$ROOT/openspec/specs}"
RESOLVE_ROOT="${TILLANDSIAS_SPEC_PATHS_ROOT:-$ROOT}"
BASELINE="${TILLANDSIAS_SPEC_PATHS_BASELINE:-$ROOT/scripts/spec-script-paths-baseline.txt}"

[ -d "$SPECS" ] || { echo "unavailable:spec-script-paths:no-spec-dir:$SPECS"; exit 2; }

# One pass over every spec: `<spec>\t<path>\t<exempt 0|1>` per token, in file
# and line order. A token counts as exempt when ITS OWN LINE carries the marker.
rows="$(find "$SPECS" -name spec.md -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r spec; do
    rel="${spec#"$ROOT"/}"
    awk -v spec="$rel" '
        {
            ex = index($0, "spec-path-absent: ok (") ? 1 : 0
            line = $0
            while (match(line, /scripts\/[A-Za-z0-9_.\/-]+\.(sh|ps1|lua|rs|yaml|md)/)) {
                print spec "\t" substr(line, RSTART, RLENGTH) "\t" ex
                line = substr(line, RSTART + RLENGTH)
            }
        }' "$spec"
done)"

if [ -z "$rows" ]; then
    echo "unavailable:spec-script-paths:no-spec-names-a-script-path — a check with nothing to read vouches for nothing"
    exit 2
fi

baseline=""
[ -f "$BASELINE" ] && baseline="$(grep -vE '^[[:space:]]*(#|$)' "$BASELINE" | cut -f1,2 || true)"
# Newline-framed, so a lookup is one `case` and no pipeline decides it.
baseline_keys="
$baseline
"
in_baseline() { case "$baseline_keys" in *"
$1
"*) return 0 ;; esac; return 1; }

resolved=0; baselined=0; exempt=0; unresolved=0
seen=""
while IFS="$(printf '\t')" read -r spec path ex; do
    [ -n "$path" ] || continue
    key="$spec	$path"
    case "$seen" in *"
$key
"*) continue ;; esac
    seen="$seen
$key
"
    if [ -e "$RESOLVE_ROOT/$path" ]; then
        resolved=$((resolved + 1))
        if in_baseline "$key"; then
            echo "note: $spec names $path, which now RESOLVES — remove its line from ${BASELINE#"$ROOT"/} (burndown)" >&2
        fi
        continue
    fi
    if [ "$ex" = 1 ]; then
        exempt=$((exempt + 1))
        continue
    fi
    if in_baseline "$key"; then
        baselined=$((baselined + 1))
        continue
    fi
    unresolved=$((unresolved + 1))
    echo "violation:spec-script-paths:$spec:$path — the spec names a script that is not in the tree" >&2
done <<EOF
$rows
EOF

if [ "$unresolved" -gt 0 ]; then
    echo "  REMEDY: correct the path in the spec, commit the script it describes, or — for a deliberate negative — mark the line <!-- spec-path-absent: ok (<reason>) -->. Do not add to the baseline: it is a burndown list (815-yace)." >&2
    echo "blocked:spec-script-paths:${unresolved}-unresolved"
    exit 1
fi
echo "ok:spec-script-paths:${resolved}-resolved,${baselined}-baselined,${exempt}-exempt"
