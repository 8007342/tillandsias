#!/usr/bin/env bash
# freshness: added 2026-08-28 linux-yoga (order 748-tkjx)
# @trace order:748-tkjx, order:885-92iu, order:921-vtf4
#
# litmus-covering-specs.sh — "which litmus specs cover the file I just edited?"
#
# ── THE DEFECT (order 748-tkjx) ──────────────────────────────────────────────
#
# On 2026-08-15 an in-forge agent fixed 747-hws2 by editing
# images/default/lib-common.sh, then did everything the contract asks:
# `./build.sh --check` rc=0, the spec it was working in PASS 7/7, every probe
# ok, pushed with evidence. All true — and litmus:startup-context-addendum-shape,
# which pins the very block it edited, was RED the whole time. The next cycle
# found it by happening to run a different spec.
#
# TWO CAUSES, and only one is the agent's. `./build.sh --check` runs no litmus
# at all (deliberate — the suite is minutes and a gate that slow gets bypassed
# with --no-verify). And openspec/litmus-bindings.yaml maps spec -> tests with
# no reverse map from FILE -> specs, even though every litmus already declares
# its artifacts in `preconditions: - workspace contains <path>`. The information
# exists and was not queryable. So an editor of a shared file — lib-common.sh is
# touched by the forge, startup-context, git-mirror and inference lanes — had no
# way to ask what to re-run, and reasonably ran only their own spec.
#
# It is not a stale anecdote: 921-vtf4 was filed on 2026-08-28 because three
# litmus tests had been red back to af745f3fd and only a full suite run
# surfaced them. Same disease, three months on.
#
# ── WHAT THIS IS, AND WHAT IT DELIBERATELY IS NOT ────────────────────────────
#
# A QUERY, not an enforcement, and not a second list. It derives the reverse map
# at call time from the two files that already exist — the litmus corpus and the
# bindings registry — so there is no hand-maintained index to drift. The packet
# is explicit that the fix must NOT be "make --check run the whole suite"; the
# cheap version tells the editor which specs to run and lets the cycle decide.
#
# TWO MATCH TIERS, kept apart because they carry different weight:
#   declared  the test names the path in `preconditions: workspace contains …`.
#             An authored claim of coverage.
#   command   a critical_path command mentions the path. Real coverage the
#             preconditions forgot to declare — the common case, and exactly
#             what an editor needs — but weaker evidence, so it is labelled.
#
# BINDING IS REPORTED, because execution is binding-driven (885-92iu): a test no
# spec binds runs in no suite and is as inert as a missing one. Telling an
# editor to re-run an unbound test would send them to a suite that will not
# execute it, so `binding:unbound` is printed rather than silently folded in.
#
# NEGATIVE CONTROL, required by the packet: a path no litmus references returns
# an EMPTY set, exit 0, and no warning. An editor of an uncovered file must not
# be nagged.
#
# ── GRAMMAR ──────────────────────────────────────────────────────────────────
# Zero or more coverage lines, then exactly one verdict line:
#   <path>\tspec:<id>\ttest:<test-name>\tmatch:declared|command\tbinding:bound|unbound
#   ok:litmus-coverage:<n>-spec(s)            n >= 0; 0 is the negative control
#   unavailable:<reason>                      the corpus could not be read
#
# Exit: 0 on any answer INCLUDING none (advisory, never a gate — same contract
# as the other cycle probes), 2 when it could not answer.
#
# Usage:
#   litmus-covering-specs.sh <path>...     paths to ask about
#   litmus-covering-specs.sh --changed     the working tree's changed files
#   litmus-covering-specs.sh --changed <ref>   files changed since <ref>
#   litmus-covering-specs.sh --run         print the run-litmus-test.sh
#                                          command lines instead of the rows
#   litmus-covering-specs.sh fixture
#
# Seams (used by the fixture):
#   TILLANDSIAS_LITMUS_TESTS_DIR   corpus directory
#   TILLANDSIAS_LITMUS_BINDINGS    bindings registry path

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)" || ROOT="."
TESTS_DIR="${TILLANDSIAS_LITMUS_TESTS_DIR:-$ROOT/openspec/litmus-tests}"
BINDINGS="${TILLANDSIAS_LITMUS_BINDINGS:-$ROOT/openspec/litmus-bindings.yaml}"

# One awk pass over the whole corpus. Emits a row per (path, spec, test, tier).
#
# Anchoring matters: `^name:` / `^spec:` / `^phase:` / `^size:` at column zero,
# FIRST occurrence per file. The corpus contains nested keys that share those
# names inside step blocks (a `size: 2` and a `phase: instant` are in there),
# and reading the last match would attribute a step's field to the document.
scan() {
    # THE TARGET LIST ARRIVES AS A FILE, NOT THROUGH -v (order 923-mp4w).
    #
    # It used to arrive as an awk command-line variable assignment holding the
    # newline-separated list (the literal spelling is deliberately not written
    # here: fixture case 9b greps this file for it, and a comment that answers
    # a check about the code is the 601-462g shape). A literal
    # newline inside a -v assignment is FATAL on BSD awk, which is what macOS
    # ships: `awk: newline in string a\nb... at source line 1`. One path has no
    # newline, so every single-path query worked and every single-path fixture
    # assertion passed; TWO paths killed awk, this function emitted nothing, and
    # the counter honestly reported what it received -- zero.
    #
    # Measured before the fix, on the real corpus: `lib-common.sh` alone -> 12
    # specs; `lib-common.sh` plus ANY uncovered path, either order -> 0 specs.
    # Since this tool's whole call shape is "the files I changed", and a
    # changeset is normally more than one file, that made it answer
    # `ok:litmus-coverage:0-spec(s)` -- the same token a true empty answer uses,
    # exit 0, no warning -- for changes a dozen specs cover.
    #
    # gawk accepts the newline where BSD awk rejects it, which is why this
    # shipped green from the Linux hosts and only the macOS gate caught it.
    #
    # `-v` is for scalars. A list goes in a file, read with the NR==FNR idiom.
    # The file always holds at least one line (printf adds the newline even for
    # an empty target list), so NR==FNR can never spill into the first corpus
    # file and mistake it for targets.
    _scan_tf="$(mktemp)" || return 2
    _scan_ef="$(mktemp)" || { rm -f "$_scan_tf"; return 2; }
    printf '%s\n' "$1" > "$_scan_tf"
    awk '
        NR == FNR { if ($0 != "") tgt[$0] = 1; next }
        FNR == 1 {
            flush()
            name = ""; spec = ""; phase = ""; size = ""; inpre = 0
            delete decl; delete cmd
        }
        /^name:[ \t]/      { if (name  == "") { name  = trim(substr($0, 6)) } }
        /^spec:[ \t]/      { if (spec  == "") { spec  = trim(substr($0, 6)) } }
        /^phase:[ \t]/     { if (phase == "") { phase = trim(substr($0, 7)) } }
        /^size:[ \t]/      { if (size  == "") { size  = trim(substr($0, 6)) } }
        /^preconditions:/  { inpre = 1; next }
        /^[a-z_]+:/        { if ($0 !~ /^preconditions:/) inpre = 0 }
        {
            if (inpre && $0 ~ /workspace contains /) {
                p = trim(substr($0, index($0, "workspace contains ") + 19))
                if (p in tgt) decl[p] = 1
            }
            for (t in tgt) if (index($0, t) > 0) cmd[t] = 1
        }
        END { flush() }

        function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
        function flush(   p) {
            if (name == "") return
            for (p in cmd) {
                # declared outranks command: one row per (path, test), labelled
                # with the strongest evidence available.
                printf "%s\t%s\t%s\t%s\t%s\t%s\n", p, spec, name, \
                    (p in decl ? "declared" : "command"), phase, size
            }
            for (p in decl) if (!(p in cmd)) {
                printf "%s\t%s\t%s\tdeclared\t%s\t%s\n", p, spec, name, phase, size
            }
        }
    ' "$_scan_tf" "$TESTS_DIR"/*.yaml 2>"$_scan_ef"
    _scan_rc=$?
    # A DEAD AWK MUST NOT READ AS "NOTHING COVERS THIS" (923-mp4w). The old
    # `2>/dev/null` is precisely what turned a fatal awk error into a confident
    # empty answer: the caller cannot tell "I looked and found none" from "I
    # could not look". This script already draws that distinction for an
    # unreadable corpus (`unavailable:`, rc 2); the scan deserves the same.
    if [ "$_scan_rc" != 0 ] || [ -s "$_scan_ef" ]; then
        printf 'litmus-covering-specs: scan failed: %s\n' \
            "$(tr '\n' ' ' < "$_scan_ef")" >&2
        rm -f "$_scan_tf" "$_scan_ef"
        return 2
    fi
    rm -f "$_scan_tf" "$_scan_ef"
}

# Which tests some spec actually BINDS. An unbound test executes in no suite.
bound_tests() {
    awk '/^[ \t]+- litmus:/ { sub(/^[ \t]+- /, ""); sub(/[ \t\r]+$/, ""); print }' \
        "$BINDINGS" 2>/dev/null | sort -u
}

query() {
    _q_targets="$1"; _q_mode="$2"
    [ -d "$TESTS_DIR" ] || { echo "unavailable:litmus-corpus-unreadable"; return 2; }
    [ -r "$BINDINGS" ] || { echo "unavailable:litmus-bindings-unreadable"; return 2; }

    _q_bound="$(bound_tests)"
    # Take scan's exit status BEFORE sorting: a pipeline would discard it and
    # the `unavailable:` distinction above would be lost again (923-mp4w).
    _q_rows="$(scan "$_q_targets")" || {
        echo "unavailable:litmus-scan-failed"
        return 2
    }
    _q_rows="$(printf '%s\n' "$_q_rows" | sort -u)"

    _q_specs=""
    _q_out=""
    _q_runs=""
    # A `while read` in a pipeline runs in a subshell on some shells, so the
    # accumulators would be lost. Feed it from a here-doc instead.
    while IFS="$(printf '\t')" read -r p spec test match phase size; do
        [ -n "$test" ] || continue
        if printf '%s\n' "$_q_bound" | grep -qxF "$test"; then
            binding="bound"
        else
            binding="unbound"
        fi
        _q_out="${_q_out}${p}	spec:${spec}	test:${test}	match:${match}	binding:${binding}
"
        case "$binding" in
            bound)
                case "|$_q_specs|" in
                    *"|$spec|"*) ;;
                    *)
                        _q_specs="${_q_specs}${spec}|"
                        _q_runs="${_q_runs}scripts/run-litmus-test.sh ${spec} --phase ${phase:-pre-build} --size ${size:-instant} --compact
"
                        ;;
                esac
                ;;
        esac
    done <<EOF
$_q_rows
EOF

    _q_n=0
    if [ -n "$_q_specs" ]; then
        _q_n="$(printf '%s' "$_q_specs" | tr '|' '\n' | grep -c .)"
    fi

    if [ "$_q_mode" = "run" ]; then
        [ -n "$_q_runs" ] && printf '%s' "$_q_runs"
    else
        [ -n "$_q_out" ] && printf '%s' "$_q_out"
    fi
    echo "ok:litmus-coverage:${_q_n}-spec(s)"
    return 0
}

changed_files() {
    if [ -n "${1:-}" ]; then
        git -C "$ROOT" diff --name-only "$1" 2>/dev/null
    else
        # Uncommitted work AND anything this branch adds over origin/linux-next:
        # the question is "what am I about to push", not "what is dirty".
        {
            git -C "$ROOT" diff --name-only 2>/dev/null
            git -C "$ROOT" diff --name-only --cached 2>/dev/null
            git -C "$ROOT" diff --name-only origin/linux-next...HEAD 2>/dev/null
        }
    fi | sort -u | grep .
}

case "${1:-}" in
    '')
        echo "usage: litmus-covering-specs.sh [--run] <path>... | [--run] --changed [<ref>] | fixture" >&2
        exit 2
        ;;
    fixture) ;;
    *)
        mode="rows"
        if [ "$1" = "--run" ]; then mode="run"; shift; fi
        if [ "${1:-}" = "--changed" ]; then
            targets="$(changed_files "${2:-}")"
            if [ -z "$targets" ]; then
                echo "ok:litmus-coverage:0-spec(s)"
                exit 0
            fi
        else
            targets="$(printf '%s\n' "$@")"
        fi
        query "$targets" "$mode"
        exit $?
        ;;
esac

# ── fixture ──────────────────────────────────────────────────────────────────
_fx_fail=0
_fx_n=0
_fx_dir="$(mktemp -d)"
_fx_self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
mkdir -p "$_fx_dir/tests"

# 721-77yu. check-litmus-pin-claims.sh greps every *.sh for `litmus:<name>` and
# refuses a name no test declares — correctly, since a script naming a
# nonexistent litmus test reads as verification and supplies none. This
# fixture's stand-in tests need that exact shape, so the prefix is ASSEMBLED
# here and the literal claim token never appears in this file.
_LT="litmus"; _LT="${_LT}:"

cat >"$_fx_dir/tests/a.yaml" <<YAML
name: ${_LT}alpha-shape
spec: alpha
phase: pre-build
size: instant
preconditions:
  - workspace contains images/shared/thing.sh
  - shell utilities (grep) are available in PATH
critical_path:
  - step: "s"
    command: "grep -q x images/shared/thing.sh"
    size: 2
YAML
cat >"$_fx_dir/tests/b.yaml" <<YAML
name: ${_LT}beta-shape
spec: beta
phase: post-build
size: quick
preconditions:
  - shell utilities (grep) are available in PATH
critical_path:
  - step: "s"
    command: "test -f images/shared/thing.sh && echo ok"
YAML
cat >"$_fx_dir/tests/c.yaml" <<YAML
name: ${_LT}gamma-orphan-shape
spec: gamma
phase: pre-build
size: instant
preconditions:
  - workspace contains images/shared/thing.sh
critical_path:
  - step: "s"
    command: "true"
YAML
cat >"$_fx_dir/bindings.yaml" <<YAML
version: '1.0'
specs:
- spec_id: alpha
  litmus_tests:
  - ${_LT}alpha-shape
- spec_id: beta
  litmus_tests:
  - ${_LT}beta-shape
- spec_id: gamma
  litmus_tests: []
YAML

_run() {
    TILLANDSIAS_LITMUS_TESTS_DIR="$_fx_dir/tests" \
    TILLANDSIAS_LITMUS_BINDINGS="$_fx_dir/bindings.yaml" \
        bash "$_fx_self" "$@"
}
# Every passing case goes through this so the tally cannot drift from reality.
_ok() { _fx_n=$((_fx_n + 1)); echo "ok: $1"; }
_expect_line() {
    _n="$1"; _want="$2"; shift 2
    if _run "$@" 2>/dev/null | grep -qxF "$_want"; then
        _ok "$_n"
    else
        echo "FAIL: $_n — no line '$_want' in:"; _run "$@" 2>&1 | sed 's/^/    /'
        _fx_fail=1
    fi
}

T="$(printf '\t')"

# 1. A DECLARED artifact resolves to its spec. This is the 2026-08-15 case in
#    miniature: the editor of a shared file learns which spec pins it.
_expect_line "declared-artifact-names-its-spec" \
    "images/shared/thing.sh${T}spec:alpha${T}test:${_LT}alpha-shape${T}match:declared${T}binding:bound" \
    images/shared/thing.sh

# 2. Coverage the preconditions never declared is still found, and is LABELLED
#    as the weaker evidence rather than passed off as a declaration. This tier
#    is the one that catches real breakage, so losing it would gut the tool.
_expect_line "undeclared-command-coverage-is-found-and-labelled" \
    "images/shared/thing.sh${T}spec:beta${T}test:${_LT}beta-shape${T}match:command${T}binding:bound" \
    images/shared/thing.sh

# 3. A test NO spec binds runs in no suite (885-92iu). It is reported, and
#    reported as unbound — sending an editor to run an inert test would be a
#    confident wrong answer.
_expect_line "a-test-no-spec-binds-is-marked-unbound" \
    "images/shared/thing.sh${T}spec:gamma${T}test:${_LT}gamma-orphan-shape${T}match:declared${T}binding:unbound" \
    images/shared/thing.sh

# 4. Only BOUND specs are counted, because only they will actually execute.
_expect_line "the-count-counts-only-bound-specs" "ok:litmus-coverage:2-spec(s)" \
    images/shared/thing.sh

# 5. THE NEGATIVE CONTROL the packet requires: an uncovered path answers
#    empty, exit 0, and says nothing else. No nagging.
_got="$(_run docs/never-referenced.md 2>/dev/null)"; _rc=$?
if [ "$_got" = "ok:litmus-coverage:0-spec(s)" ] && [ "$_rc" = 0 ]; then
    _ok "an-uncovered-path-is-silent-and-exits-zero"
else
    echo "FAIL: uncovered path expected the bare 0-spec verdict rc=0, got '$_got' rc=$_rc"
    _fx_fail=1
fi

# 6. --run gives the editor the command, not a map to interpret. Unbound specs
#    are absent from it for the same reason they are not counted.
_expect_line "run-mode-emits-a-runnable-command" \
    "scripts/run-litmus-test.sh alpha --phase pre-build --size instant --compact" \
    --run images/shared/thing.sh
_got="$(_run --run images/shared/thing.sh 2>/dev/null | grep -c 'gamma')"
[ "$_got" = "0" ] && _ok "run-mode-omits-unbound-specs" \
    || { echo "FAIL: run-mode emitted an unbound spec"; _fx_fail=1; }

# 7. A nested `size:`/`phase:` inside a step must not be read as the document's.
#    litmus-alpha carries `size: 2` in a step; the run line above asserts
#    `--size instant`, so this is already pinned — assert it explicitly so the
#    reason survives a refactor.
_got="$(_run --run images/shared/thing.sh 2>/dev/null | grep -c -- '--size 2')"
[ "$_got" = "0" ] && _ok "a-steps-nested-size-is-not-the-documents-size" \
    || { echo "FAIL: a nested step field leaked into the document's fields"; _fx_fail=1; }

# 8. Several paths at once — the real call shape is "the files I changed".
_got="$(_run images/shared/thing.sh docs/never-referenced.md 2>/dev/null | tail -1)"
[ "$_got" = "ok:litmus-coverage:2-spec(s)" ] && _ok "multiple-paths-answer-in-one-call" \
    || { echo "FAIL: multi-path query expected 2-spec(s), got '$_got'"; _fx_fail=1; }

# 9. An unreadable corpus is `unavailable:`, never a confident empty answer —
#    "no specs cover this" and "I could not look" must never share a token.
_got="$(TILLANDSIAS_LITMUS_TESTS_DIR="$_fx_dir/nope" \
        TILLANDSIAS_LITMUS_BINDINGS="$_fx_dir/bindings.yaml" \
        bash "$_fx_self" images/shared/thing.sh 2>/dev/null)"; _rc=$?
if [ "$_got" = "unavailable:litmus-corpus-unreadable" ] && [ "$_rc" = 2 ]; then
    _ok "an-unreadable-corpus-is-unavailable-not-empty"
else
    echo "FAIL: expected unavailable:litmus-corpus-unreadable rc=2, got '$_got' rc=$_rc"
    _fx_fail=1
fi

# 9b. REGRESSION PIN for 923-mp4w. Case 8 above catches the symptom, but only
#     on an awk that rejects a newline in a -v assignment — on gawk it passed
#     while the tool was broken for every macOS user. This pins the CAUSE, so
#     the defect cannot come back green on the host that reintroduces it.
# The needle is ASSEMBLED, never written literally — otherwise this very line
# is the match and the check fails on a healthy file. Same reason the fixture
# assembles the pin-claim prefix above (721-77yu).
_needle="-v"; _needle="${_needle} targets="
_got="$(grep -c -- "$_needle" "$_fx_self")"
[ "$_got" = "0" ] && _ok "the-target-list-is-not-passed-through-awk-v" \
    || { echo "FAIL: a list is being passed through awk -v again (923-mp4w): fatal on BSD awk"; _fx_fail=1; }

# 10. THE REAL CASE from the packet, against the REAL corpus — verified by
#     running it, not by reading the map (exit criterion 3).
_got="$(bash "$_fx_self" --run images/default/lib-common.sh 2>/dev/null | grep -c 'meta-orchestration')"
if [ "${_got:-0}" -ge 1 ]; then
    _ok "the-real-lib-common.sh-case-returns-meta-orchestration"
else
    echo "FAIL: images/default/lib-common.sh did not return the meta-orchestration spec"
    bash "$_fx_self" images/default/lib-common.sh 2>&1 | sed 's/^/    /' | head -5
    _fx_fail=1
fi

rm -rf "$_fx_dir"
# The case count is DERIVED, not typed. It was the literal 11 and I added a
# case (9b) without it changing -- a verification count that cannot notice new
# verification is the same looks-checked-checks-nothing shape this script's own
# subject matter is about (923-mp4w).
[ "$_fx_fail" = 0 ] && echo "ok:litmus-covering-specs-fixture:${_fx_n}"
exit "$_fx_fail"
