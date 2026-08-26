#!/usr/bin/env bash
# @trace order:829-dkuc, spec:ci-release
#
# check-dead-env-branches.sh — name the TILLANDSIAS_* variables that live code
# READS and nothing anywhere ASSIGNS or DOCUMENTS.
#
# WHY (order 829-dkuc criterion 1). A branch guarded by a variable nothing
# sets is unreachable code wearing a feature flag's costume — the prototype
# run found TILLANDSIAS_STATUS_CHECK gating Step 5 (the forge launch!) of
# orchestrate-enclave.sh into unreachability. In CRDT-style accretion these
# survive precisely because each one looks deliberate in isolation; only the
# corpus-wide read/assign/document reconciliation exposes them.
#
# CLASSIFICATION (deliberately mechanical; the sweep judges, this detects):
#   READ        a $-expansion or env-var read of TILLANDSIAS_<NAME> in live
#               (non-comment) lines of scripts/ images/ crates/ build.sh
#   ASSIGNED    NAME= / export NAME / .env("NAME" / -e|--env NAME= anywhere in
#               those trees (fixtures count: a var a test assigns is a seam)
#   DOCUMENTED  the name appears on a comment line or in methodology/, docs/,
#               plan/, skills/, openspec/ prose — a STATED seam is deliberate
#   DEAD        READ, never ASSIGNED, never DOCUMENTED
#
# This is a SWEEP INPUT, not a build gate: exit 1 on findings feeds the
# 829-dkuc deslop sweep, whose job is to construct the (mutation, predicted
# observable) pair per finding. Do not wire it into ./build.sh --check while
# the backlog is nonzero — that would be 660-ryhn's blind-binding mistake in
# a different costume.
#
# GRAMMAR (one line on stdout, findings to stderr):
#   ^dead-env-branches: total=[0-9]+ unassigned=[0-9]+ dead=[0-9]+ verdict=(ok|dead-branches-found)$
# Exit 0 when dead=0; 1 when dead>0; 2 usage/infra.
#
# Seams: DEAD_ENV_ROOT overrides the scan root (self-test);
#   --self-test runs the planted-fixture negative/positive controls.
set -uo pipefail

ROOT="${DEAD_ENV_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

if [ "${1:-}" = "--self-test" ]; then
    t="$(mktemp -d)"
    trap 'rm -rf "$t"' EXIT
    mkdir -p "$t/scripts"
    # The fixture's variable names are COMPOSED ("$P") so this script's own
    # heredoc cannot appear to the scanner as a live read — the first draft
    # reported its own planted fixture as a real dead branch.
    P="TILLANDSIAS_SELFTEST"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'if [ -n "${%s_DEAD_VAR:-}" ]; then\n    echo unreachable\nfi\n' "$P"
        printf '%s_LIVE_VAR=1\n' "$P"
        printf 'if [ -n "${%s_LIVE_VAR:-}" ]; then\n    echo reachable\nfi\n' "$P"
        printf '# %s_DOC_VAR is a documented fixture seam.\n' "$P"
        printf 'if [ -n "${%s_DOC_VAR:-}" ]; then\n    echo documented\nfi\n' "$P"
        printf 'tune="${%s_TUNE_VAR:-fallback}"\necho "$tune"\n' "$P"
    } > "$t/scripts/fixture.sh"
    out="$(DEAD_ENV_ROOT="$t" bash "${BASH_SOURCE[0]}" 2>&1)"
    rc=$?
    [ "$rc" -eq 1 ] || { echo "SELF-TEST FAIL: planted dead var must exit 1, got rc=$rc"; exit 1; }
    printf '%s\n' "$out" | grep -q 'TILLANDSIAS_SELFTEST_DEAD_VAR' \
        || { echo "SELF-TEST FAIL: planted dead var not named: $out"; exit 1; }
    printf '%s\n' "$out" | grep -q 'TILLANDSIAS_SELFTEST_LIVE_VAR' \
        && { echo "SELF-TEST FAIL: assigned var wrongly reported: $out"; exit 1; }
    printf '%s\n' "$out" | grep -q 'TILLANDSIAS_SELFTEST_DOC_VAR' \
        && { echo "SELF-TEST FAIL: documented var wrongly reported: $out"; exit 1; }
    printf '%s\n' "$out" | grep -q 'TILLANDSIAS_SELFTEST_TUNE_VAR' \
        && { echo "SELF-TEST FAIL: nonempty-default tunable wrongly reported: $out"; exit 1; }
    printf '%s\n' "$out" | grep -q 'dead=1 verdict=dead-branches-found' \
        || { echo "SELF-TEST FAIL: wrong verdict line: $out"; exit 1; }
    echo "SELF-TEST PASS: dead named, assigned and documented spared"
    exit 0
fi

scan_dirs=()
for d in scripts images crates; do
    [ -d "$ROOT/$d" ] && scan_dirs+=("$ROOT/$d")
done
[ -f "$ROOT/build.sh" ] && scan_dirs+=("$ROOT/build.sh")
[ "${#scan_dirs[@]}" -gt 0 ] || { echo "dead-env-branches: total=0 unassigned=0 dead=0 verdict=ok"; exit 2; }

# READS: $VAR / ${VAR} / env::var("VAR") / std::env::var on non-comment lines.
reads="$(grep -rhoE '(\$\{?|env::var\(&?")TILLANDSIAS_[A-Z0-9_]+' "${scan_dirs[@]}" 2>/dev/null \
    | grep -oE 'TILLANDSIAS_[A-Z0-9_]+' | sort -u)"

# TUNABLES ARE NOT DEAD BRANCHES. `${VAR:-nonempty}` runs the same code either
# way — the default CARRIES the behavior, so the branch is live whether or not
# anyone assigns the var. A variable is a dead-branch CANDIDATE only if it has
# at least one bare/empty-default read (`$VAR`, `${VAR}`, `${VAR:-}`,
# `${VAR:+...}`, or a rust env read) — the shapes that do nothing until
# something sets them. TILLANDSIAS_STATUS_CHECK is the archetype: default
# empty, then gating the forge-launch step into unreachability.
gating="$( { grep -rhoE '\$\{TILLANDSIAS_[A-Z0-9_]+(:-)?\}' "${scan_dirs[@]}" 2>/dev/null; \
             grep -rhoE '\$\{TILLANDSIAS_[A-Z0-9_]+:\+' "${scan_dirs[@]}" 2>/dev/null; \
             grep -rhoE '\$TILLANDSIAS_[A-Z0-9_]+' "${scan_dirs[@]}" 2>/dev/null; \
             grep -rhoE 'env::var\(&?"TILLANDSIAS_[A-Z0-9_]+' "${scan_dirs[@]}" 2>/dev/null; } \
    | grep -oE 'TILLANDSIAS_[A-Z0-9_]+' | sort -u)"

# ASSIGNMENTS: shell assignment, export, container/env injection, rust .env()
# and set_var (test fixtures count: a var a test assigns is a seam).
assigns="$(grep -rhoE '(^|[^A-Z0-9_$@{("'"'"'])(export +)?TILLANDSIAS_[A-Z0-9_]+=|\.env\(\s*"TILLANDSIAS_[A-Z0-9_]+"|set_var\(\s*"TILLANDSIAS_[A-Z0-9_]+"|(-e|--env) +TILLANDSIAS_[A-Z0-9_]+=|"TILLANDSIAS_[A-Z0-9_]+=' "${scan_dirs[@]}" 2>/dev/null \
    | grep -oE 'TILLANDSIAS_[A-Z0-9_]+' | sort -u)"
# rustfmt splits `set_var(`/`.env(` from their string argument across lines;
# join one line forward so those assignments are not misread as absent (the
# first draft reported TILLANDSIAS_PODMAN_STORAGE_CONF dead past exactly this).
assigns="$( { printf '%s\n' "$assigns"; \
    find "${scan_dirs[@]}" -name '*.rs' -type f 2>/dev/null -exec awk '
        joined { print prev $0; joined = 0 }
        /(set_var|\.env)\($/ { prev = $0; joined = 1; next }
        { print }' {} + \
    | grep -E '(set_var|\.env)\(\s*"TILLANDSIAS_[A-Z0-9_]+"' \
    | grep -oE 'TILLANDSIAS_[A-Z0-9_]+'; } | sort -u)"

# DOCUMENTATION: comment lines in the scan trees, plus prose trees. plan/ is
# deliberately EXCLUDED — the ledger describing a variable (including a packet
# describing it as dead, as 829-dkuc itself does for TILLANDSIAS_STATUS_CHECK)
# is a record about it, not a seam declaration; counting it would let every
# filed finding immunize its own subject.
doc_sources=("${scan_dirs[@]}")
for d in methodology docs skills openspec; do
    [ -d "$ROOT/$d" ] && doc_sources+=("$ROOT/$d")
done
# This script's own comments quote its FINDINGS (TILLANDSIAS_STATUS_CHECK is
# the archetype) and must not immunize them — the first draft's header
# "documented" its own example out of the report. Findings-quoting text is a
# record, not a seam declaration; the detector excludes itself from the
# comment pass only (its reads/assigns still scan).
self_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
docs="$(grep -rlE '^[[:space:]]*#.*TILLANDSIAS_[A-Z0-9_]+' "${scan_dirs[@]}" 2>/dev/null \
            | grep -vxF "$self_path" \
            | xargs -r grep -hE '^[[:space:]]*#.*TILLANDSIAS_[A-Z0-9_]+' 2>/dev/null; \
        grep -rhoE 'TILLANDSIAS_[A-Z0-9_]+' \
            --include='*.md' --include='*.yaml' --include='*.yml' \
            "${doc_sources[@]}" 2>/dev/null)"
docs="$(printf '%s\n' "$docs" | grep -oE 'TILLANDSIAS_[A-Z0-9_]+' | sort -u)"

total=0 unassigned=0 dead=0 tunable=0
dead_list=""
while IFS= read -r var; do
    [ -n "$var" ] || continue
    total=$((total + 1))
    printf '%s\n' "$assigns" | grep -qxF "$var" && continue
    unassigned=$((unassigned + 1))
    printf '%s\n' "$docs" | grep -qxF "$var" && continue
    if ! printf '%s\n' "$gating" | grep -qxF "$var"; then
        tunable=$((tunable + 1))     # every read carries a nonempty default
        continue
    fi
    dead=$((dead + 1))
    dead_list="${dead_list}${var}"$'\n'
done <<< "$reads"

if [ "$dead" -gt 0 ]; then
    {
        echo "(excluded: $tunable undocumented tunable(s) whose every read carries a nonempty default — live either way)"
        echo "dead branches — READ in a gating shape, ASSIGNED nowhere, DOCUMENTED nowhere:"
        printf '%s' "$dead_list" | while IFS= read -r v; do
            [ -n "$v" ] || continue
            echo "  $v"
            grep -rn "$v" "${scan_dirs[@]}" 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | head -2 | sed 's/^/    /'
        done
    } >&2
    echo "dead-env-branches: total=$total unassigned=$unassigned dead=$dead verdict=dead-branches-found"
    exit 1
fi
echo "dead-env-branches: total=$total unassigned=$unassigned dead=$dead verdict=ok"
exit 0
