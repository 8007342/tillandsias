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
#               (non-comment) lines of scripts/ images/ crates/ build.sh; a
#               rust env::var read with a nonempty .unwrap_or(...)/
#               .unwrap_or_else(...) default is a TUNABLE, not a candidate
#               (parity with the shell ${VAR:-nonempty} exclusion)
#   ASSIGNED    NAME= / export NAME / .env("NAME" / set_var("NAME" /
#               ANY-RECEIVER.set("NAME" / -e|--env NAME= / $(NAME=... cmd)
#               anywhere in those trees (fixtures count: a var a test assigns
#               is a seam)
#   DOCUMENTED  the name appears on a #, ///, or //! comment line, or in
#               methodology/, docs/, plan/, skills/, openspec/ prose — a
#               STATED seam is deliberate
#   DEAD        READ, never ASSIGNED, never DOCUMENTED
#
# This detector's own comment lines never count as a READ or a DOCUMENTED
# hit for a name they quote as illustration (self_name below) — order
# 1169-zw44: without that, a variable this file names as an example could
# never clear even after its real reads were deleted.
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
    mkdir -p "$t/scripts" "$t/crates"
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
        # ORDER 829-dkuc. A dead name that is a PREFIX of a live one, so the
        # evidence lines can be checked for pointing at the RIGHT variable.
        # `_PFX` is dead (bare read, never assigned); `_PFX_SUFFIX` is assigned
        # and therefore live, and its assignment sits EARLIER in the file so an
        # unanchored `grep | head -2` reports it in place of the real read.
        printf '%s_PFX_SUFFIX=1\necho "$%s_PFX_SUFFIX"\n' "$P" "$P"
        printf 'if [ -n "${%s_PFX:-}" ]; then\n    echo prefixdead\nfi\n' "$P"
        # ORDER 1166-99mk. An env-prefix assignment directly after a
        # command-substitution open — the house test idiom
        # `_got="$(VAR=... cmd)"` — must count as ASSIGNED even though the
        # character immediately before the name is '(', not a boundary the
        # original excluded-prefix class allowed.
        printf '_got="$(%s_ENVPFX_VAR=1 true)"\n' "$P"
        printf 'if [ -n "${%s_ENVPFX_VAR:-}" ]; then\n    echo envpfx\nfi\n' "$P"
    } > "$t/scripts/fixture.sh"
    {
        # ORDER 1167-ga24 / 1168-bbbe. Rust-side shapes: a nonempty
        # unwrap_or_else default (tunable) and a bare read with none (still a
        # candidate, negative control); a `///` doc comment (documents) and a
        # plain `//` comment (does not — boundary control); a wrapper `.set(`
        # assignment.
        printf '// %s_RUST_DEAD_VAR: read, no default, no assignment, no doc.\n' "$P"
        printf 'fn selftest_rust_dead() {\n    let _ = std::env::var("%s_RUST_DEAD_VAR");\n}\n\n' "$P"
        printf '// nonempty default -> tunable, not a dead-branch candidate.\n'
        printf 'fn selftest_rust_tunable() {\n    let _ = std::env::var("%s_RUST_TUNABLE_VAR")\n        .unwrap_or_else(|_| "fallback".to_string());\n}\n\n' "$P"
        printf '/// documents %s_RUST_DOC_ONLY_VAR, read below, assigned nowhere.\n' "$P"
        printf 'fn selftest_rust_doc_only() {\n    let _ = std::env::var("%s_RUST_DOC_ONLY_VAR");\n}\n\n' "$P"
        printf '// names %s_RUST_PLAINCOMMENT_VAR in a plain, non-doc comment.\n' "$P"
        printf 'fn selftest_rust_plaincomment() {\n    let _ = std::env::var("%s_RUST_PLAINCOMMENT_VAR");\n}\n\n' "$P"
        printf 'fn selftest_rust_wrapset() {\n    let _ = std::env::var("%s_RUST_WRAPSET_VAR");\n    restore.set("%s_RUST_WRAPSET_VAR", "1");\n}\n' "$P" "$P"
    } > "$t/crates/fixture.rs"
    # ORDER 1169-zw44. A file sharing THIS detector's own basename, quoting a
    # variable in a comment exactly the way this file's header/evidence-block
    # comments quote TILLANDSIAS_PROJECT_ENGINE / TILLANDSIAS_STATUS_CHECK.
    # That quote must count as neither a read nor documentation, so the
    # variable must be entirely invisible below — not dead, not live.
    {
        printf '#!/usr/bin/env bash\n'
        printf '# Mimics this detectors own explanatory-comment shape: quoting a\n'
        printf '# variable as an example, e.g. `${%s_SELFQUOTE_VAR:-}`.\n' "$P"
    } > "$t/scripts/check-dead-env-branches.sh"
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
    # ORDER 829-dkuc. THE EVIDENCE MUST BE FOR THE VARIABLE IT IS FILED UNDER.
    #
    # The display used an UNANCHORED `grep -rn "$v" | head -2`, so a name that
    # is a prefix of others showed THEIR lines and omitted its own. Measured on
    # the real tree: TILLANDSIAS_PROJECT_ENGINE displayed two _SRC_REL/_DEFAULT
    # assignment lines — different variables — while its actual gating read at
    # lib-common.sh:1386 never appeared. The finding was CORRECT and its
    # evidence pointed elsewhere, which is the combination that makes an auditor
    # dismiss a true row; I did exactly that before reading the source.
    #
    # This arm pins it in the direction that matters: the _PFX row must cite the
    # line that made it a candidate, not the earlier _PFX_SUFFIX assignment.
    _pfx_ev="$(printf '%s\n' "$out" | grep -A2 "^  ${P}_PFX$" | tail -n +2)"
    printf '%s\n' "$_pfx_ev" | grep -q "${P}_PFX:-" \
        || { echo "SELF-TEST FAIL: prefix-dead var's evidence omits its own gating read: $_pfx_ev"; exit 1; }
    printf '%s\n' "$_pfx_ev" | grep -q "${P}_PFX_SUFFIX=" \
        && { echo "SELF-TEST FAIL: evidence cites a DIFFERENT variable's line: $_pfx_ev"; exit 1; }

    # 1166-99mk. NEGATIVE CONTROL: TILLANDSIAS_SELFTEST_DEAD_VAR (asserted
    # dead above) has no assignment in ANY shape, including this one, so
    # widening ASSIGNED must not spare it.
    printf '%s\n' "$out" | grep -q "${P}_ENVPFX_VAR" \
        && { echo "SELF-TEST FAIL: \$(VAR=1 cmd) env-prefix assignment not recognized: $out"; exit 1; }

    # 1167-ga24. A Rust env::var read with a nonempty unwrap_or_else default
    # is a TUNABLE, parity with the shell \${VAR:-nonempty} exclusion.
    printf '%s\n' "$out" | grep -q "${P}_RUST_TUNABLE_VAR" \
        && { echo "SELF-TEST FAIL: rust env::var with nonempty default wrongly reported dead: $out"; exit 1; }
    # NEGATIVE CONTROL: a Rust env::var read with no default, assignment or
    # doc must still be reported dead -- the tunable exclusion must not
    # swallow a genuinely dead Rust read.
    printf '%s\n' "$out" | grep -q "${P}_RUST_DEAD_VAR" \
        || { echo "SELF-TEST FAIL: rust env::var with no default wrongly spared: $out"; exit 1; }

    # 1168-bbbe. A Rust \`///\` doc comment above the read documents it.
    printf '%s\n' "$out" | grep -q "${P}_RUST_DOC_ONLY_VAR" \
        && { echo "SELF-TEST FAIL: rust /// doc comment not recognized as DOCUMENTED: $out"; exit 1; }
    # BOUNDARY CONTROL: a plain // comment (not a doc comment) must NOT
    # document -- only \`///\`/\`//!\` extend the DOCUMENTED pass. Doubles as
    # a negative control: this var has no assignment either, so it must stay
    # dead exactly like TILLANDSIAS_SELFTEST_DEAD_VAR.
    printf '%s\n' "$out" | grep -q "${P}_RUST_PLAINCOMMENT_VAR" \
        || { echo "SELF-TEST FAIL: plain // comment wrongly treated as documentation: $out"; exit 1; }
    # 1168-bbbe. A wrapper setter (any receiver, method literally \`set\`)
    # assigns, the same as set_var/.env.
    printf '%s\n' "$out" | grep -q "${P}_RUST_WRAPSET_VAR" \
        && { echo "SELF-TEST FAIL: wrapper .set(\"VAR\", ...) not recognized as ASSIGNED: $out"; exit 1; }

    # 1169-zw44. This detector's own comments (mimicked by the same-basename
    # file above) must not manufacture a permanent read -- a self-quote
    # counts as neither documentation nor a read, so the variable must be
    # invisible to the report entirely (not dead, not live).
    printf '%s\n' "$out" | grep -q "${P}_SELFQUOTE_VAR" \
        && { echo "SELF-TEST FAIL: self-referential comment manufactured a phantom read: $out"; exit 1; }

    printf '%s\n' "$out" | grep -q 'dead=4 verdict=dead-branches-found' \
        || { echo "SELF-TEST FAIL: wrong verdict line: $out"; exit 1; }
    echo "SELF-TEST PASS: dead named, assigned/documented/tunable spared, env-prefix/rust-default/rust-doc/wrapper-set/self-quote shapes covered, evidence anchored"
    exit 0
fi

scan_dirs=()
for d in scripts images crates; do
    [ -d "$ROOT/$d" ] && scan_dirs+=("$ROOT/$d")
done
[ -f "$ROOT/build.sh" ] && scan_dirs+=("$ROOT/build.sh")
[ "${#scan_dirs[@]}" -gt 0 ] || { echo "dead-env-branches: total=0 unassigned=0 dead=0 verdict=ok"; exit 2; }

# READS: $VAR / ${VAR} / env::var("VAR") / std::env::var on non-comment lines.
#
# SELF-REFERENCE (order 1169-zw44). The DOCUMENTED pass below already
# excludes this file's own comment lines from immunizing a finding — a
# variable this detector quotes as an example (TILLANDSIAS_PROJECT_ENGINE,
# TILLANDSIAS_STATUS_CHECK in its header and evidence block) must not
# document itself out of the report. But this READS pass had no matching
# exclusion: those same quoted comments use the live `${VAR...}` shape as
# illustration, so they were extracted as a permanent phantom read —
# undocumented (correctly) AND unassignable (nothing "assigns" a comment), so
# a variable named here could never clear even after its real reads were
# deleted. self_name (shared with the DOCUMENTED pass) excludes this file's
# own comment lines from both passes identically: a self-quote counts as
# neither.
self_name="$(basename "${BASH_SOURCE[0]}")"
reads="$( { grep -rhoE '(\$\{?|env::var\(&?")TILLANDSIAS_[A-Z0-9_]+' "${scan_dirs[@]}" \
                --exclude="$self_name" 2>/dev/null; \
             find "${scan_dirs[@]}" -name "$self_name" -type f 2>/dev/null \
                 -exec grep -vhE '^[[:space:]]*#' {} + \
                 | grep -ohE '(\$\{?|env::var\(&?")TILLANDSIAS_[A-Z0-9_]+' 2>/dev/null; } \
    | grep -oE 'TILLANDSIAS_[A-Z0-9_]+' | sort -u)"

# TUNABLES ARE NOT DEAD BRANCHES. `${VAR:-nonempty}` runs the same code either
# way — the default CARRIES the behavior, so the branch is live whether or not
# anyone assigns the var. A variable is a dead-branch CANDIDATE only if it has
# at least one bare/empty-default read (`$VAR`, `${VAR}`, `${VAR:-}`,
# `${VAR:+...}`, or a rust env read with no nonempty default) — the shapes
# that do nothing until something sets them. TILLANDSIAS_STATUS_CHECK is the
# archetype: default empty, then gating the forge-launch step into
# unreachability.
#
# RUST PARITY (order 1167-ga24). `env::var("VAR")` used to feed gating
# unconditionally, with no counterpart to the shell `${VAR:-nonempty}`
# exclusion above, so e.g. build_nix_cache_run_args's three `env::var(...)`
# reads — every one defaulted via `.unwrap_or(...)`/`.unwrap_or_else(...)` —
# read as dead-branch candidates while their shell twins (same defaults) were
# correctly spared. Each read is joined forward into the rest of its
# statement (bounded to 8 lines, or cut at the first `;`, so a `.ok()` /
# `.and_then(...)` chain landing on `.unwrap_or(...)` several calls later —
# TILLANDSIAS_NIX_CACHE_HOST_PORT's shape — still resolves) and excluded from
# gating only when that continuation is a NONEMPTY `.unwrap_or(`/
# `.unwrap_or_else(` call; a bare `env::var(...)` with no such call, or an
# empty one, still counts as a candidate.
gating="$( { grep -rhoE '\$\{TILLANDSIAS_[A-Z0-9_]+(:-)?\}' "${scan_dirs[@]}" 2>/dev/null; \
             grep -rhoE '\$\{TILLANDSIAS_[A-Z0-9_]+:\+' "${scan_dirs[@]}" 2>/dev/null; \
             grep -rhoE '\$TILLANDSIAS_[A-Z0-9_]+' "${scan_dirs[@]}" 2>/dev/null; \
             find "${scan_dirs[@]}" -name '*.rs' -type f 2>/dev/null -exec awk '
                 FNR==1 { if (buf != "") { print buf; buf = ""; n = 0 } }
                 { buf = (buf == "" ? $0 : buf " " $0); n++
                   if ($0 ~ /;/ || n >= 8) { print buf; buf = ""; n = 0 } }
                 END { if (buf != "") print buf }' {} + \
                 | grep -E 'env::var\(&?"TILLANDSIAS_[A-Z0-9_]+"' \
                 | grep -vE '\.unwrap_or(_else)?\([^)]'; } \
    | grep -oE 'TILLANDSIAS_[A-Z0-9_]+' | sort -u)"

# ASSIGNMENTS: shell assignment, export, container/env injection, rust .env()
# and set_var (test fixtures count: a var a test assigns is a seam).
#
# ENV-PREFIX OPEN (order 1166-99mk). The excluded-prefix class used to
# include '(', so `_got="$(VAR=value cmd)"` — the house test idiom for
# capturing a subshell run with a scoped env override — was invisible: the
# character right before the name in `$(VAR=` IS '('. Nothing else here
# depends on excluding a bare '(' (unlike '"', which the dedicated
# quoted-assign alternative below already owns), so dropping it from the
# class costs nothing and makes the idiom count.
#
# WRAPPER SETTERS (order 1168-bbbe). `set_var("VAR"` and `.env("VAR"` only
# see std::env::set_var and the container .env() builder by their exact
# names; a test helper that wraps set_var under a method literally called
# `set` (e.g. `restore.set("VAR", value)`, TestEnvRestore's shape) was
# unreadable to either. `\.set\(` covers any receiver — the string argument
# already anchors it to a real TILLANDSIAS_ name, so nothing else can match.
assigns="$(grep -rhoE '(^|[^A-Z0-9_$@{"'"'"'])(export +)?TILLANDSIAS_[A-Z0-9_]+=|\.env\(\s*"TILLANDSIAS_[A-Z0-9_]+"|set_var\(\s*"TILLANDSIAS_[A-Z0-9_]+"|\.set\(\s*"TILLANDSIAS_[A-Z0-9_]+"|(-e|--env) +TILLANDSIAS_[A-Z0-9_]+=|"TILLANDSIAS_[A-Z0-9_]+=' "${scan_dirs[@]}" 2>/dev/null \
    | grep -oE 'TILLANDSIAS_[A-Z0-9_]+' | sort -u)"
# rustfmt splits `set_var(`/`.env(`/`.set(` from their string argument across
# lines; join one line forward so those assignments are not misread as absent
# (the first draft reported TILLANDSIAS_PODMAN_STORAGE_CONF dead past exactly
# this).
assigns="$( { printf '%s\n' "$assigns"; \
    find "${scan_dirs[@]}" -name '*.rs' -type f 2>/dev/null -exec awk '
        joined { print prev $0; joined = 0 }
        /(set_var|\.env|\.set)\($/ { prev = $0; joined = 1; next }
        { print }' {} + \
    | grep -E '(set_var|\.env|\.set)\(\s*"TILLANDSIAS_[A-Z0-9_]+"' \
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
# record, not a seam declaration; the detector excludes itself (self_name,
# defined with the READS pass above, shared so both passes agree on what
# "itself" means) from the comment pass only (its reads/assigns still scan).
#
# RUST DOC COMMENTS (order 1168-bbbe). The comment pattern only matched a
# leading '#', so a Rust `///` (outer) or `//!` (inner) doc comment could not
# document anything — DelegatedRunConfig's timeout contract is stated in a
# `///` directly above its read, and the plain regex missed it entirely.
# Deliberately narrow to DOC comments (`//` immediately followed by `!` or
# `/`): a plain `//` comment must NOT count, the same as it never has for `#`.
comment_doc_pat='^[[:space:]]*(#|//[!/]).*TILLANDSIAS_[A-Z0-9_]+'
docs="$(grep -rlE "$comment_doc_pat" "${scan_dirs[@]}" --exclude="$self_name" 2>/dev/null \
            | xargs -r grep -hE "$comment_doc_pat" 2>/dev/null; \
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
    if ! grep -qxF "$var" <<<"$gating"; then
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
            # ORDER 829-dkuc. THE EVIDENCE MUST BE FOR THIS VARIABLE.
            #
            # This was `grep -rn "$v"` — an UNANCHORED substring match, then
            # head -2. For a name that is a PREFIX of other names the first two
            # hits are other variables entirely, and the reads that made this a
            # candidate never appear.
            #
            # MEASURED before the fix: TILLANDSIAS_PROJECT_ENGINE displayed
            #   lib-project-engine-capability.sh:89  ..._SRC_REL=...
            #   lib-project-engine-capability.sh:92  ..._DEFAULT=...
            # — two DIFFERENT variables — while its actual gating read,
            # `${TILLANDSIAS_PROJECT_ENGINE:-}` at lib-common.sh:1386, was not
            # shown at all. The same for TILLANDSIAS_STATUS_CHECK, whose only
            # displayed line was TILLANDSIAS_STATUS_CHECK_BIN.
            #
            # THE FINDING WAS CORRECT AND ITS EVIDENCE POINTED ELSEWHERE, which
            # is the worst combination for the sweep this list feeds: 829-dkuc's
            # protocol makes every finding a (mutation, predicted-observable)
            # pair, and a pair built from another variable's lines predicts an
            # observable that cannot appear. I dismissed two correct rows as
            # prefix artifacts on exactly this display before checking the
            # source — the audit step the sweep depends on is the step this
            # misleads.
            #
            # Anchored on a trailing non-name character or end-of-line. A
            # LEADING boundary is deliberately not required: `${VAR`, `"$VAR`
            # and `--env VAR=` all precede the name with characters that vary,
            # and every name here already starts with the TILLANDSIAS_ prefix
            # the extractor matched.
            grep -rnE "${v}([^A-Z0-9_]|\$)" "${scan_dirs[@]}" 2>/dev/null \
                | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | head -2 | sed 's/^/    /'
        done
    } >&2
    echo "dead-env-branches: total=$total unassigned=$unassigned dead=$dead verdict=dead-branches-found"
    exit 1
fi
echo "dead-env-branches: total=$total unassigned=$unassigned dead=$dead verdict=ok"
exit 0
