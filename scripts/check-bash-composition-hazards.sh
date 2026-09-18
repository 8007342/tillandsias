#!/usr/bin/env bash
# @trace order:1252-r72q, spec:fail-loud-diagnosis
#
# check-bash-composition-hazards.sh — ADVISORY report of the four measured
# bash composition hazards, over a tree-sitter-bash parse.
#
# ADVISORY TIER, DELIBERATELY. This is NOT a gate step and must not become one
# until the reported population is owned by a row (1252-r72q exit criterion 4).
# The arithmetic is the reason, not caution: 545 candidate pipelines would red
# trunk for every host on a backlog nobody owns, and a guard that reds trunk
# gets disabled rather than obeyed. Same ordering 1251-54p3 followed.
#
# It ALWAYS EXITS 0. A non-zero exit here would make it a gate by accident the
# first time a caller used `set -e`.
#
# Verdicts:
#   advisory:bash-hazards:scanned=<n>
#   advisory:bash-hazards:<shape>:pipelines=<n>:files=<n>
#   skip:bash-hazards:no-binary   the litmus binary is not built
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 0

# Prefer the freshly built binary over an installed one, and verify it by
# RUNNING it -- an executable bit is a claim, running is evidence (the
# plan-binary-probe rule, 1172-dyvd).
# CAPTURE THEN MATCH (795-imz3), and this script EARNED that remedy rather
# than inheriting it. The first version of this probe was:
#     "$cand" bash-hazards 2>&1 | grep -q 'bash-hazards'
# which is hazard shape 1 -- the very shape this file reports. Under the
# `set -o pipefail` three lines above, grep -q exits on the first match,
# SIGPIPEs the producer, and the pipeline reports FAILURE ON A MATCH. It
# printed skip:bash-hazards:no-binary with a working binary sitting right
# there. Recorded because it is the best available argument that the
# population this script counts is worth counting: the author of the lint
# wrote the defect into the lint's own launcher, in the same hour.
BIN=""
for cand in "$ROOT/target/release/tillandsias-litmus-rust" "$ROOT/target/debug/tillandsias-litmus-rust"; do
    [ -x "$cand" ] || continue
    # `bash-hazards` with no paths is a usage error -- that IS the probe: it
    # proves the subcommand exists in THIS binary rather than that some older
    # build happens to sit on the path.
    _probe="$("$cand" bash-hazards 2>&1)"
    case "$_probe" in
        *bash-hazards*) BIN="$cand"; break ;;
    esac
done
if [ -z "$BIN" ]; then
    echo "skip:bash-hazards:no-binary"
    exit 0
fi

# find -L, not `grep -r`: plain -r does not descend into symlinked directories
# on this fleet and exits 0 regardless, so a symlinked tree reads as clean.
FILES=()
while IFS= read -r _line; do FILES+=("$_line"); done < <(find -L "${1:-scripts}" -name '*.sh' -type f 2>/dev/null | sort)
if [ "${#FILES[@]}" -eq 0 ]; then
    echo "advisory:bash-hazards:scanned=0"
    exit 0
fi

"$BIN" bash-hazards "${FILES[@]}" || true
exit 0
