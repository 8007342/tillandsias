#!/bin/bash
# @trace spec:spec-traceability
# freshness: auditor=linux-macuahuitl-fable5-20260810t2240z date=2026-08-10 verdict=refreshed scope=spec-traceability suite (runner self-tests incl. name-filter fail-loud, backslash escaping, stdlib portability) 7/7 executed PASS; heavy incidental live exercise same day (5 host suites + a 195-test in-forge run via v0.4.260810.x); spec-name-only filter grammar confirmed fail-loud by design when handed a litmus: test name
# freshness: auditor=linux-macuahuitl-opencode-20260801T0611Z date=2026-08-01 verdict=refreshed scope=live executor, filters, cleanup, and stdlib remain meaningful; focused self-tests 6/6 green
#
# Tillandsias Litmus Test Execution Runner
#
# Purpose: Execute litmus tests against OpenSpec specifications to detect
#          spec-code divergence and validate convergence.
#
# Litmus tests are executable decision boundaries that validate code against specs.
# This runner enforces:
#   - Reproducibility: identical preconditions yield identical results
#   - Observability: all execution emits verifiable signals (logs, traces)
#   - Falsifiability: success and failure conditions are unambiguous
#   - Composability: smaller tests combine without interference
#   - Determinism: no timing assumptions, no flaky conditions
#
# Usage:
#   ./scripts/run-litmus-test.sh --spec SPEC   # Scope by spec ladder shorthand
#   ./scripts/run-litmus-test.sh [spec-name]       # Run single spec's litmus tests
#   ./scripts/run-litmus-test.sh                     # Run all specs' tests
#   ./scripts/run-litmus-test.sh --list              # List all test suites
#   ./scripts/run-litmus-test.sh --timeout 60        # Custom timeout in seconds
#   ./scripts/run-litmus-test.sh --ignore SPEC1,SPEC2 # Skip in-progress specs
#   ./scripts/run-litmus-test.sh --diff-scope origin/linux-next
#                                                    # Skip tests whose declared
#                                                    # `inputs:` globs are untouched
#                                                    # since that ref (order 765-mza8)
#
# --diff-scope is advisory and fails CLOSED: an unannotated test, an
# unresolvable base, a clean tree, or a full-run anchor older than 24h all
# disable scoping and run EVERYTHING, loudly. A run that actually skipped
# something also blocks build.sh from writing a gate stamp, because a scoped
# run cannot vouch for the whole tree.
#
# Exit Codes:
#   0 = all tests pass
#   1 = at least one CRITICAL test fails
#   2 = precondition not met (SKIP status)
#   3 = invalid arguments or configuration
#

set -eo pipefail

# @trace spec:graceful-shutdown
# Clean up descendant processes on exit without signaling the runner's own
# process group. Some launchers make this script the process-group leader, and
# `kill -TERM -$$` turns successful litmus runs into exit 143.
if [[ "$(uname)" == "Linux" ]]; then
    _litmus_cleanup_descendants() {
        local parent_pid="$1"
        local child_pid
        command -v pgrep >/dev/null 2>&1 || return 0
        while IFS= read -r child_pid; do
            [[ -n "$child_pid" ]] || continue
            _litmus_cleanup_descendants "$child_pid"
            kill -TERM "$child_pid" 2>/dev/null || true
        done < <(pgrep -P "$parent_pid" 2>/dev/null || true)
    }

    _litmus_exit_cleanup() {
        local rc=$?
        trap - EXIT
        _litmus_cleanup_descendants "$$"
        exit "$rc"
    }

    trap _litmus_exit_cleanup EXIT
fi

# ============================================================================
# CONFIGURATION & GLOBALS
# ============================================================================

readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Build/test DURATION telemetry (packet 682-emvg). Best-effort side-channel that
# times the litmus suite; a timing failure must NEVER change the runner's exit.
. "$(dirname "${BASH_SOURCE[0]}")/timing-log.sh" 2>/dev/null || true
command -v timing_emit >/dev/null 2>&1 || { timing_now_ms() { echo 0; }; timing_emit() { return 0; }; }
readonly LITMUS_BINDINGS="${PROJECT_ROOT}/openspec/litmus-bindings.yaml"
readonly LITMUS_TESTS_DIR="${PROJECT_ROOT}/openspec/litmus-tests"
readonly METHODOLOGY_LITMUS="${PROJECT_ROOT}/methodology/litmus.yaml"
readonly LITMUS_RUNTIME_DIR="${PROJECT_ROOT}/target/litmus-runtime"
readonly LITMUS_PODMAN_ROOT="${PROJECT_ROOT}/target/litmus-podman/root"
readonly LITMUS_PODMAN_RUNROOT="${PROJECT_ROOT}/target/litmus-podman/runroot"
readonly LITMUS_PODMAN_TMPDIR="${PROJECT_ROOT}/target/litmus-podman/tmp"
# Exported: step commands run in CHILD `bash -c` shells which `source`
# this path — an unexported readonly is invisible there, making the
# stdlib wiring silently inert (adopted-stray completion, order 225).
LITMUS_STDLIB="${PROJECT_ROOT}/scripts/litmus-stdlib.sh"
export LITMUS_STDLIB

if [[ -z "${XDG_RUNTIME_DIR:-}" || ! -w "${XDG_RUNTIME_DIR:-/dev/null}" ]]; then
    mkdir -p "$LITMUS_RUNTIME_DIR"
    chmod 700 "$LITMUS_RUNTIME_DIR"
    export XDG_RUNTIME_DIR="$LITMUS_RUNTIME_DIR"
fi

readonly REAL_PODMAN_BIN="$(command -v podman 2>/dev/null || true)"
mkdir -p "$LITMUS_RUNTIME_DIR/bin" "$LITMUS_PODMAN_ROOT" "$LITMUS_PODMAN_RUNROOT" "$LITMUS_PODMAN_TMPDIR"
chmod 700 "$LITMUS_PODMAN_ROOT" "$LITMUS_PODMAN_RUNROOT" "$LITMUS_PODMAN_TMPDIR"
cat >"$LITMUS_RUNTIME_DIR/bin/podman" <<EOF
#!/usr/bin/env bash
set -euo pipefail

args=("\$@")
mode="\${LITMUS_PODMAN_MODE:-real}"
calls_file="\${LITMUS_PODMAN_CALLS_FILE:-$PROJECT_ROOT/target/litmus-podman/calls.log}"
real_podman_bin="${REAL_PODMAN_BIN}"
if [[ "\${args[0]:-}" == "run" || "\${args[0]:-}" == "create" ]]; then
    has_userns=0
    for arg in "\${args[@]}"; do
        if [[ "\$arg" == --userns=* || "\$arg" == "--userns" ]]; then
            has_userns=1
            break
        fi
    done
    if [[ "\$has_userns" -eq 0 ]]; then
        args=("\${args[0]}" "--userns=host" "\${args[@]:1}")
    fi
fi

mkdir -p "\$(dirname "\$calls_file")"
{
    printf '%s\t' "\$(date -u +%FT%TZ)"
    printf 'podman'
    for arg in "\${args[@]}"; do
        printf ' %q' "\$arg"
    done
    printf '\n'
} >>"\$calls_file"

if [[ "\$mode" == "fake" ]]; then
    exec "$PROJECT_ROOT/scripts/test-support/podman-mock.sh" "\${args[@]}"
fi

# Real-mode delegation now passes through the Rust-owned Podman façade so
# litmus tests exercise the same backend seam as the rest of the repository.
# Strip our own dir from PATH and drop TILLANDSIAS_PODMAN_BIN so the Rust
# delegate resolves the real podman instead of re-execing this wrapper
# (which causes unbounded recursion when --version is dispatched via
# raw → podman_cmd() → TILLANDSIAS_PODMAN_BIN → this wrapper).
new_path=""
IFS=: read -ra parts <<<"\$PATH"
for d in "\${parts[@]}"; do
    [[ "\$d" == */target/litmus-runtime/bin ]] && continue
    new_path="\${new_path:+\$new_path:}\$d"
done
unset TILLANDSIAS_PODMAN_BIN
PATH="\$new_path" exec "$PROJECT_ROOT/scripts/tillandsias-podman" raw "\${args[@]}"
EOF
chmod 755 "$LITMUS_RUNTIME_DIR/bin/podman"

# ── yq for hosts that do not ship one (order 799-tb7q) ──────────────────────
# TWO REAL DEFECTS, one cause. On an immutable host (Silverblue/Kinoite) there
# is no host `yq`; it lives only in the tillandsias-builder toolbox.
#
#   1. 121 litmus STEP COMMANDS across ~30 files call `yq` directly. Measured
#      2026-08-23 on lenovinha: litmus:skills-canonical-and-mcp-first-shape
#      STEP 6 ("the MCP-first read rule is declared in methodology") reports
#      FAIL. The rule is present and correct — the same command run inside the
#      toolbox prints `ok: rule declared`. The step collapses "key absent" and
#      "command not found" into one verdict, so the failure is dressed as a
#      statement about methodology. A test that lies is worse than no test.
#   2. THIS RUNNER'S OWN yaml_get / get_litmus_tests_for_spec fall back to
#      grep-based approximations whose comment admits "not perfect but
#      functional". Those decide phase, size, host_kind, inputs and WHICH TESTS
#      RUN. So a host without yq silently selects a different test set than a
#      host with one, and nothing reports the difference.
#
# Materialised ONCE into the runtime bin rather than dispatched per call: a
# `toolbox run` round trip measures ~0.29s here, and this runner invokes yq
# once per metadata field per file — on a full suite that is minutes of pure
# overhead. Copying the toolbox's binary costs one call and then runs native.
#
# VERIFIED BEFORE IT IS TRUSTED. The binary is dynamically linked (glibc,
# libresolv), so a copy is only valid when the host can actually run it. If the
# extracted file does not answer `--version`, it is removed and the existing
# grep fallbacks apply exactly as before — this is strictly additive and can
# only improve fidelity, never reduce it.
#
# THIS MUST RUN BEFORE the runtime bin joins PATH, and that ordering is load
# bearing rather than stylistic. That directory holds this runner's `podman`
# WRAPPER; `toolbox` shells out to podman, so with the wrapper ahead of the real
# binary the extraction fails silently and the shim is never written. Measured
# the confusing way: the block was reached with `yq=none toolbox=/usr/bin/toolbox`
# and still produced nothing, because the tool it needed had been replaced two
# lines earlier.
if ! command -v yq &>/dev/null && command -v toolbox &>/dev/null; then
    _yq_shim="$LITMUS_RUNTIME_DIR/bin/yq"
    if [[ ! -x "$_yq_shim" ]]; then
        if toolbox run --container tillandsias-builder cat /usr/bin/yq \
             >"$_yq_shim" 2>/dev/null && [[ -s "$_yq_shim" ]]; then
            chmod 755 "$_yq_shim"
            if ! "$_yq_shim" --version &>/dev/null; then
                rm -f "$_yq_shim"
            fi
        else
            rm -f "$_yq_shim"
        fi
    fi
fi

# ── Say so when yq is still missing (order 799-tb7q) ────────────────────────
# A run without yq is DEGRADED and used to be indistinguishable from a clean
# one. Measured on this host: with yq absent,
# litmus:added-fragment-parse-gate-shape STEP 8 produces EMPTY output and fails,
# and litmus:skills-canonical-and-mcp-first-shape STEP 6 reports that a
# methodology rule is missing when it is present and correct. Those are wrong
# answers, not skips, and nothing in the output said the toolchain was short a
# parser.
#
# A warning, never a refusal: a host without yq must still be able to run its
# suite, and the metadata fallbacks are real fallbacks. The point is only that
# the reader can tell which kind of green they are holding.
if ! command -v yq &>/dev/null && [[ ! -x "$LITMUS_RUNTIME_DIR/bin/yq" ]]; then
    printf 'warn:litmus-degraded-no-yq — yq is not on PATH and could not be provisioned from the tillandsias-builder toolbox. Steps whose commands call yq will fail or return empty. (The runner'\''s OWN metadata reads use the compiled tillandsias-plan reader when one resolves — order 746-htj9 — and fall back to grep only without it.) Install yq on the host, or create the toolbox (see scripts/with-tillandsias-builder.sh), before trusting a verdict from this run.\n' >&2
fi

# Now the runtime bin joins PATH — after the extraction above, and carrying the
# shim it may just have written, so both this runner's own yaml_get and every
# litmus step command resolve the same real yq.
export PATH="$LITMUS_RUNTIME_DIR/bin:$PATH"

# ── ORDER 746-htj9: the sanctioned YAML read path for the runner's OWN reads ─
# Metadata reads (phase/host_kind/size/inputs, bindings queries) try
# `tillandsias-plan yaml-json | jq` FIRST: the compiled reader exists in every
# environment the gates run in, and jq is the one query tool present in all of
# them — so a host without yq now selects the SAME test set as a host with it,
# instead of silently degrading to the grep parsers. yq stays as the second
# tier, the historical awk/grep parsers as the last; both remain because a
# fresh clone that has never built the binary must still be able to run.
# Step COMMANDS inside test files that call yq themselves are 799-tb7q's
# territory (the toolbox shim above), not this block's.
LITMUS_PLAN_BIN=""
if [[ -f "$PROJECT_ROOT/scripts/plan-binary-probe.sh" ]]; then
    # shellcheck source=scripts/plan-binary-probe.sh
    . "$PROJECT_ROOT/scripts/plan-binary-probe.sh" 2>/dev/null || true
    if command -v resolve_plan_binary &>/dev/null; then
        LITMUS_PLAN_BIN="$(resolve_plan_binary 2>/dev/null)" || LITMUS_PLAN_BIN=""
    fi
fi
# _yaml_jq <file> <jq-filter> — the first tier. Returns non-zero (and prints
# nothing) when the tier is unavailable or the file does not load, so callers
# fall through to the next tier. A `blocked:` verdict from yaml-json lands on
# stdout INTO jq, which then fails — the fallback engages either way.
_yaml_jq() {
    [[ -n "$LITMUS_PLAN_BIN" ]] || return 1
    command -v jq &>/dev/null || return 1
    "$LITMUS_PLAN_BIN" yaml-json "$1" 2>/dev/null | jq -r "$2" 2>/dev/null
}
export TILLANDSIAS_NO_SINGLETON=1
export LITMUS_PODMAN_CALLS_FILE="${LITMUS_PODMAN_CALLS_FILE:-$PROJECT_ROOT/target/litmus-podman/calls.log}"

# Default timeout in seconds (can be overridden via --timeout)
# Increased from 30s to 600s (10 min) to handle slow tray feature compilation
# @trace spec:spec-traceability
TIMEOUT_SECONDS=600
VERBOSE=0
LIST_ONLY=0

# ORDER 958-b36m. Parse a named litmus file with the RUNNER'S OWN parser and
# report whether its steps are extractable, WITHOUT executing any of them.
#
# The binding gate needs to ask "can the runner run this file?" and there was
# no way to ask. Reimplementing the parse in the gate would assert the GATE's
# idea of the format and could go green while this runner refuses the file —
# strictly worse than no gate, and this corpus has two instances THIS WEEK of a
# rule copied to one lane and left on others (702-6jza D3, D4). So the answer
# is a mode on the authority itself.
PARSE_ONLY=0
PARSE_ONLY_FILES=()
FILTER_SPEC=""
# 764-8m5j was REVERTED here on 2026-08-17 and the packet reopened. It made a
# test-name filter RUN that single test, which is genuinely useful — but
# litmus-litmus-name-filter-hint-shape pins the opposite contract on purpose
# (order 300 follow-on): a name-shaped filter FAILS LOUD and names its owning
# spec. Flipping a fail-loud contract is a deliberate decision that deserves
# its own packet and its own reasoning, not a drive-by during a release. The
# safety property was never at risk — the feature still refused unknown names
# — but "useful" is not the bar for changing a pinned refusal.
FILTER_TEST_NAME=""
FILTER_PHASE="all"
SIZE_FILTER="all"
# Order 765-mza8 diff-scoped selection. Inert unless --diff-scope is passed AND
# litmus_resolve_diff_scope accepts the base; every refusal path leaves
# DIFF_SCOPE_ACTIVE=0, which means "run everything".
DIFF_SCOPE_BASE=""
DIFF_SCOPE_ACTIVE=0
DIFF_SCOPE_BASE_SHA=""
DIFF_SCOPE_CHANGED=""
DIFF_SCOPE_SKIPS=0
COMPACT=0
STRICT_MODE=0
STRICT_SPEC_LIST=""
IGNORE_SPEC_LIST=""
SPEC_SHORTHAND=""

# Test result tracking
TESTS_PASSED=0
# 765-dfry: per-test duration accumulator, tab-separated `dur_ms<TAB>name<TAB>rc`
# lines. Consumed twice at suite end: a ranked slowest-tests block in compact
# output, and ONE --emit-timing-batch spawn (per-test spawns would tax an
# instant suite seconds to measure milliseconds — the empty-suite-floor lesson).
_PER_TEST_LOG=""
TESTS_FAILED=0
TESTS_SKIPPED=0
TESTS_RUN=0

# Track which specs were tested. Portable bash-3.2 dedup+count (no
# associative arrays: stock macOS ships bash 3.2, which lacks `declare -A`).
# The per-spec verdict itself is never read back, only the distinct count.
SPEC_RESULTS_SEEN=$'\n'
SPEC_RESULTS_COUNT=0

record_spec_result() {
    local spec_id="$1"
    case "$SPEC_RESULTS_SEEN" in
        *$'\n'"$spec_id"$'\n'*) ;; # already recorded — don't double-count
        *)
            SPEC_RESULTS_SEEN+="$spec_id"$'\n'
            SPEC_RESULTS_COUNT=$((SPEC_RESULTS_COUNT + 1))
            ;;
    esac
}

# Global deduplication for cross-spec litmus tests (same portable pattern).
LITMUS_GLOBAL_SEEN_LIST=$'\n'

litmus_global_seen() {
    case "$LITMUS_GLOBAL_SEEN_LIST" in
        *$'\n'"$1"$'\n'*) return 0 ;;
        *) return 1 ;;
    esac
}

litmus_global_mark_seen() {
    LITMUS_GLOBAL_SEEN_LIST+="$1"$'\n'
}

# Color output (respects NO_COLOR env var)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

if [[ "${NO_COLOR:-0}" == "1" ]]; then
    RED='' GREEN='' YELLOW='' BLUE='' BOLD='' NC=''
fi

# ============================================================================
# LOGGING & FORMATTING
# ============================================================================

log_info() {
    printf '%b%s%b %s\n' "${BLUE}" "i" "${NC}" "$*" >&2
}

log_pass() {
    printf '%b%s%b %s\n' "${GREEN}" "✓" "${NC}" "$*" >&2
}

log_fail() {
    printf '%b%s%b %s\n' "${RED}" "✗" "${NC}" "$*" >&2
}

log_warn() {
    printf '%b%s%b %s\n' "${YELLOW}" "⚠" "${NC}" "$*" >&2
}

log_spec_start() {
    local spec_name="$1"
    printf '%bspec:%b%s\n' "${BOLD}" "${NC}" "$spec_name" >&2
}

log_test_result() {
    local spec_name="$1"
    local test_name="$2"
    local status="$3"
    local message="${4:-}"
    local suppress_output=0

    case "$status" in
        PASS)
            TESTS_PASSED=$((TESTS_PASSED+1))
            [[ "$COMPACT" == "1" ]] && suppress_output=1
            if [[ "$suppress_output" -eq 0 ]]; then
                printf '  %b[PASS]%b %s\n' "${GREEN}" "${NC}" "$test_name" >&2
            fi
            ;;
        FAIL)
            printf '  %b[FAIL]%b spec=%s test=%s\n' "${RED}" "${NC}" "$spec_name" "$test_name" >&2
            [[ -n "$message" ]] && printf '         %b%s%b\n' "${RED}" "$message" "${NC}" >&2
            TESTS_FAILED=$((TESTS_FAILED+1))
            ;;
        SKIP)
            TESTS_SKIPPED=$((TESTS_SKIPPED+1))
            [[ "$COMPACT" == "1" ]] && suppress_output=1
            if [[ "$suppress_output" -eq 0 ]]; then
                printf '  %b[SKIP]%b %s\n' "${YELLOW}" "${NC}" "$test_name" >&2
                [[ -n "$message" ]] && printf '         %b%s%b\n' "${YELLOW}" "$message" "${NC}" >&2
            fi
            ;;
    esac
    TESTS_RUN=$((TESTS_RUN+1))
}

# ============================================================================
# YAML PARSING HELPERS
# ============================================================================

# Parse YAML value using yq or jq (fallback to grep)
# Unescape a YAML double-quoted scalar captured by a bash regex (875-v7hv).
#
# The step parser below captures the RAW BYTES between the outer quotes, so a
# YAML `\"` arrives as a literal backslash followed by a quote. Two passes, in
# this order, reproduce YAML's own left-to-right escape consumption:
#   1. \" -> "   2. \\ -> \
# Order matters: a raw `\\\"` must become `\"`, which is what a real YAML
# parser produces. Doing \\ first would consume the backslash that guards the
# quote and yield something else.
#
# WHY THIS IS A FUNCTION AND NOT INLINE, which is the whole of 875-v7hv: these
# two passes were applied to `command:` alone (added under
# plan/issues/litmus-runner-command-backslash-escaping-2026-07-06.md) while
# `expected_behavior:`, `success_pattern:` and `failure_pattern:` got none. A
# step whose command emits a double quote and whose expected_behavior declares
# that same text could therefore NEVER match itself — measured on yoga
# 2026-08-25, where the runner reported
#   expected=out.push((\"no_proxy\"...)   output=out.push(("no_proxy"...)
# i.e. a content mismatch between two strings that are in fact identical.
#
# The dangerous direction is `failure_pattern`: one carrying `\"` silently
# never matches, so a genuine failure signal is missed and the step is reported
# green. An assertion that cannot fire is worse than an absent one.
yaml_unescape_dq() {
    local s="$1"
    s="${s//\\\"/\"}"
    s="${s//\\\\/\\}"
    printf '%s' "$s"
}

yaml_get() {
    local file="$1"
    local path="$2"

    # ORDER 746-htj9: yq's filter language is jq's, so the same path string
    # feeds both tiers.
    local v
    if v="$(_yaml_jq "$file" "$path")"; then
        echo "$v"
    elif command -v yq &>/dev/null; then
        yq eval "$path" "$file" 2>/dev/null || echo ""
    elif command -v jq &>/dev/null; then
        # Simple fallback for yq-style paths (not perfect but functional)
        grep -E "^${path//./\\.}:" "$file" 2>/dev/null | cut -d':' -f2- | xargs || echo ""
    else
        # Minimal grep-based fallback
        grep "^  ${path}:" "$file" 2>/dev/null | cut -d':' -f2- | xargs || echo ""
    fi
}

# Extract test names from bindings file for a given spec
get_litmus_tests_for_spec() {
    local spec_id="$1"

    local v
    if v="$(_yaml_jq "$LITMUS_BINDINGS" ".specs[] | select(.spec_id==\"${spec_id}\") | .litmus_tests[]?")"; then
        # An empty match is rc=0, exactly as the yq tier's `|| true` made it:
        # callers treat non-zero as a runner failure, not as "no tests".
        if [[ -n "$v" ]]; then printf '%s\n' "$v"; fi
    elif command -v yq &>/dev/null; then
        yq eval ".specs[] | select(.spec_id==\"${spec_id}\") | .litmus_tests[]" \
            "$LITMUS_BINDINGS" 2>/dev/null || true
    else
        # Fallback: grep and parse. YAML structure is:
        # - spec_id: <name>
        #   status: active
        #   litmus_tests:
        #   - <test-name>
        awk -v spec="$spec_id" '
            /^- spec_id: / {
                gsub(/^- spec_id: /, "");
                in_current = ($0 == spec) ? 1 : 0
                in_tests = 0
                next
            }
            in_current && /^  litmus_tests:/ { in_tests = 1; next }
            in_current && in_tests && /^  - / {
                gsub(/^  - /, "");
                print
                next
            }
            in_current && /^- spec_id/ { exit }
        ' "$LITMUS_BINDINGS"
    fi
}

# Get all active spec IDs from bindings
get_all_active_specs() {
    local v
    if v="$(_yaml_jq "$LITMUS_BINDINGS" '.specs[] | select(.status=="active") | .spec_id')"; then
        if [[ -n "$v" ]]; then printf '%s\n' "$v"; fi
    elif command -v yq &>/dev/null; then
        yq eval '.specs[] | select(.status=="active") | .spec_id' "$LITMUS_BINDINGS" 2>/dev/null || true
    else
        # Fallback: grep-based parsing
        awk '
            /^- spec_id: / {
                gsub(/^- spec_id: /, "");
                current_spec = $0
                next
            }
            /^  status: / {
                gsub(/^  status: /, "");
                status = $0
                if (status == "active" && current_spec != "") print current_spec
            }
        ' "$LITMUS_BINDINGS"
    fi
}

get_test_phase() {
    local file="$1"

    local v
    if v="$(_yaml_jq "$file" '.phase // "runtime"')"; then
        echo "${v:-runtime}"
    elif command -v yq &>/dev/null; then
        yq eval '.phase // "runtime"' "$file" 2>/dev/null || echo "runtime"
    else
        awk '
            /^phase: / {
                gsub(/^phase: /, "");
                print
                found=1
                exit
            }
            END {
                if (!found) print "runtime"
            }
        ' "$file"
    fi
}

# Order 661-emqi. A test may declare the host kind it requires; anywhere else it
# SKIPS instead of failing. Defaults to `any`, so every existing test is
# unaffected — an absent field must never start gating anything.
#
# The motivating case: litmus:forge-policy-binary-discoverability hardcodes
# /home/forge/.cache, which exists only inside the forge container. Bound and run
# on a Linux host it failed with `mktemp: ... No such file or directory` — a red
# that says nothing about the product. Left unbound it was silent instead, which
# is the condition 660-ryhn is about. Neither is acceptable; SKIP is the honest
# third answer, and the runner already skips for phase and size.
get_test_host_kind() {
    local file="$1"

    local v
    if v="$(_yaml_jq "$file" '.host_kind // "any"')"; then
        echo "${v:-any}"
    elif command -v yq &>/dev/null; then
        yq eval '.host_kind // "any"' "$file" 2>/dev/null || echo "any"
    else
        awk '
            /^host_kind: / {
                gsub(/^host_kind: /, "");
                print
                found=1
                exit
            }
            END {
                if (!found) print "any"
            }
        ' "$file"
    fi
}

# The kind of host this runner is on. TILLANDSIAS_HOST_KIND is authoritative when
# set (the forge sets it; check-credential-channel.sh:66 already trusts it);
# otherwise fall back to uname. Deliberately coarse — this gate exists to keep a
# forge-only test off a laptop, not to model the full host taxonomy.
current_host_kind() {
    if [[ -n "${TILLANDSIAS_HOST_KIND:-}" ]]; then
        printf '%s' "$TILLANDSIAS_HOST_KIND"
        return
    fi
    case "$(uname -s 2>/dev/null)" in
        Darwin)                      printf 'macos' ;;
        Linux)                       printf 'linux' ;;
        MINGW*|MSYS*|CYGWIN*)        printf 'windows' ;;
        *)                           printf 'unknown' ;;
    esac
}

get_test_size() {
    local file="$1"

    local v
    if v="$(_yaml_jq "$file" '.size // "quick"')"; then
        echo "${v:-quick}"
    elif command -v yq &>/dev/null; then
        yq eval '.size // "quick"' "$file" 2>/dev/null || echo "quick"
    else
        awk '
            /^size: / {
                gsub(/^size: /, "");
                print
                found=1
                exit
            }
            END {
                if (!found) print "quick"
            }
        ' "$file"
    fi
}

# Order 765-mza8. OPTIONAL `inputs:` — the repo paths whose content can change
# this test's verdict, as a YAML list of globs. ABSENT means "unknown inputs",
# which must read as "any change could matter", so an unannotated test always
# runs. That default is the whole safety story: annotation can only ever REMOVE
# a test from a scoped run, so a missing or wrong annotation costs time, never
# coverage.
#
# Emits one glob per line; empty output means unannotated.
get_test_inputs() {
    local file="$1"

    local v
    if v="$(_yaml_jq "$file" '.inputs[]? // ""')"; then
        [[ -n "$v" ]] && printf '%s\n' "$v" | grep -v '^$' || true
    elif command -v yq &>/dev/null; then
        yq eval '.inputs[]? // ""' "$file" 2>/dev/null | grep -v '^$' || true
    else
        awk '
            /^inputs:[[:space:]]*$/ { collecting=1; next }
            collecting && /^[[:space:]]*-[[:space:]]+/ {
                line = $0
                sub(/^[[:space:]]*-[[:space:]]+/, "", line)
                gsub(/^["'"'"']|["'"'"']$/, "", line)
                print line
                next
            }
            collecting && /^[^[:space:]]/ { collecting=0 }
        ' "$file"
    fi
}

# Does any changed path match any of this test's declared globs?
#
# Pattern matching is bash `[[ == ]]`, NOT pathname expansion, so `*` DOES
# cross `/`: `crates/*` means "anything under crates/", which is the reading an
# annotator intends. Stated here because the opposite assumption would silently
# narrow a glob and skip a test that should have run.
litmus_inputs_intersect_diff() {
    local globs="$1" changed="$2"
    local g p
    while IFS= read -r g; do
        [[ -n "$g" ]] || continue
        while IFS= read -r p; do
            [[ -n "$p" ]] || continue
            # shellcheck disable=SC2053
            if [[ "$p" == $g ]]; then
                return 0
            fi
        done <<<"$changed"
    done <<<"$globs"
    return 1
}

# Order 765-mza8: resolve --diff-scope into an ACTIVE scope or a loud refusal.
#
# POLARITY, and it is the opposite of 634-39ik's: that guard only ADDS
# enforcement, so it may fail open on a missing base ref. This selector REMOVES
# coverage, so every uncertainty must fail CLOSED — i.e. disable scoping and run
# the full suite, loudly. The refusals below are therefore not error handling;
# they are the feature working.
#
# Sets DIFF_SCOPE_ACTIVE=1 + DIFF_SCOPE_BASE_SHA + DIFF_SCOPE_CHANGED on success.
litmus_resolve_diff_scope() {
    local base="$1"
    DIFF_SCOPE_ACTIVE=0
    DIFF_SCOPE_BASE_SHA=""
    DIFF_SCOPE_CHANGED=""

    if ! git -C "$PROJECT_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
        log_warn "diff-scope DISABLED (running FULL): not a git repository"
        return 0
    fi

    local sha
    if ! sha="$(git -C "$PROJECT_ROOT" rev-parse --verify --quiet "${base}^{commit}" 2>/dev/null)" \
        || [[ -z "$sha" ]]; then
        log_warn "diff-scope DISABLED (running FULL): base ref '${base}' does not resolve"
        return 0
    fi

    # Tracked changes BASE..worktree (not ..HEAD — uncommitted edits must count,
    # or a scoped run would skip the very test covering what you just typed),
    # plus untracked files, which are changes the diff cannot see at all.
    local tracked untracked
    if ! tracked="$(git -C "$PROJECT_ROOT" diff --name-only "$sha" -- 2>/dev/null)"; then
        log_warn "diff-scope DISABLED (running FULL): diff against ${sha} is unparseable"
        return 0
    fi
    untracked="$(git -C "$PROJECT_ROOT" ls-files --others --exclude-standard 2>/dev/null || true)"

    local changed
    changed="$(printf '%s\n%s\n' "$tracked" "$untracked" | grep -v '^$' | sort -u || true)"
    if [[ -z "$changed" ]]; then
        # Nothing changed at all. Scoping would skip EVERY annotated test, which
        # is defensible but indistinguishable from a broken diff — and the
        # packet forbids a vacuous green. Run full; it is the honest answer to
        # "verify this tree" when nothing is known to have moved.
        log_warn "diff-scope DISABLED (running FULL): no changes against ${sha:0:12}"
        return 0
    fi

    # 24h full-run ratchet. Skipping forever on a long-lived branch means the
    # unannotated-but-affected test never runs again; a periodic full anchor
    # bounds how stale scoped confidence can get.
    local anchor_file anchor_age now
    anchor_file="$(git -C "$PROJECT_ROOT" rev-parse --absolute-git-dir 2>/dev/null)/tillandsias-litmus-full-anchor"
    now="$(date -u +%s 2>/dev/null || echo 0)"
    if [[ -f "$anchor_file" ]]; then
        anchor_age="$(cat "$anchor_file" 2>/dev/null || echo 0)"
        case "$anchor_age" in ''|*[!0-9]*) anchor_age=0 ;; esac
        if [[ "$now" -gt 0 && $((now - anchor_age)) -ge 86400 ]]; then
            log_warn "diff-scope DISABLED (running FULL): last full quick-tier run is older than 24h (ratchet)"
            return 0
        fi
    else
        log_warn "diff-scope DISABLED (running FULL): no full-run anchor recorded yet (ratchet)"
        return 0
    fi

    DIFF_SCOPE_ACTIVE=1
    DIFF_SCOPE_BASE_SHA="$sha"
    DIFF_SCOPE_CHANGED="$changed"
    local n
    # wc, not `grep -c .`: grep PRINTS 0 and EXITS 1 on no-match, so the usual
    # `|| echo 0` fallback would concatenate into "0\n0".
    n="$(printf '%s\n' "$changed" | wc -l | tr -d ' ')"
    log_info "diff-scope ACTIVE against ${sha:0:12} (${n} changed path(s)); unannotated tests still run"
    return 0
}

# Record that a FULL quick-tier run completed, feeding the 24h ratchet above.
litmus_record_full_anchor() {
    local dir
    dir="$(git -C "$PROJECT_ROOT" rev-parse --absolute-git-dir 2>/dev/null)" || return 0
    date -u +%s > "$dir/tillandsias-litmus-full-anchor" 2>/dev/null || true
}

# A scoped run must never be mistaken for a full one by whatever writes the
# gate stamp. build.sh hardcodes `--scope full`, so without this breadcrumb a
# scoped lane inside --ci-full would stamp the tree as fully validated — the
# exact silent-green pivot audit F5 names. The sentinel is consumed and cleared
# by _write_gate_stamp.
litmus_mark_scoped_run() {
    local dir
    dir="$(git -C "$PROJECT_ROOT" rev-parse --absolute-git-dir 2>/dev/null)" || return 0
    printf 'diff-scope base=%s skips=%s\n' "$DIFF_SCOPE_BASE_SHA" "$1" \
        > "$dir/tillandsias-litmus-diff-scoped" 2>/dev/null || true
}

size_matches_filter() {
    local test_size="$1"
    local filter="$2"

    if [[ "$filter" == "all" ]]; then
        return 0
    fi

    case "$test_size" in
        instant)
            [[ "$filter" =~ ^(instant|quick|long|e2e)$ ]] && return 0 || return 1
            ;;
        quick)
            [[ "$filter" =~ ^(quick|long|e2e)$ ]] && return 0 || return 1
            ;;
        long)
            [[ "$filter" =~ ^(long|e2e)$ ]] && return 0 || return 1
            ;;
        e2e)
            [[ "$filter" == "e2e" ]] && return 0 || return 1
            ;;
        *)
            return 0
            ;;
    esac
}

# ============================================================================
# TEST EXECUTION
# ============================================================================

# NOTE: the former execute_test_command() helper was DEAD CODE — zero call
# sites; the real step execution is the file-capture invocation inside
# run_litmus_test_file (search for step_capture). It was deleted 2026-07-15
# after its presence misled a hardening pass into patching the wrong site
# while the live command-substitution path kept wedging the gate.

# Check if output matches success/failure criteria
check_signal() {
    local output="$1"
    local success_pattern="$2"
    local failure_pattern="$3"

    # Check failure first (more specific usually)
    if [[ -n "$failure_pattern" ]] && grep -qE "$failure_pattern" <<<"$output"; then
        return 1  # Failure condition met
    fi

    # Check success condition
    if [[ -n "$success_pattern" ]]; then
        if grep -qE "$success_pattern" <<<"$output"; then
            return 0  # Success condition met
        else
            return 1  # Success pattern not found
        fi
    fi

    # No success pattern specified; assume success if no failure
    [[ -z "$failure_pattern" ]] || return 0
}

behavior_matches_output() {
    local output="$1"
    local expected="$2"
    # Order 661-nm73. The step's EXIT CODE, so a step can succeed by producing
    # nothing. Optional and defaulting to 0: callers that do not pass it keep the
    # previous output-only semantics rather than silently changing verdict.
    local exit_code="${3:-0}"
    # tr, not bash-4+ ${var,,}, so this runs on stock macOS bash 3.2 too.
    local expected_lc
    expected_lc="$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')"
    local output_lc
    output_lc="$(printf '%s' "$output" | tr '[:upper:]' '[:lower:]')"

    [[ -z "$expected_lc" ]] && return 0

    if [[ "$expected_lc" =~ ([0-9]+)\+\ env\ vars ]]; then
        local threshold="${BASH_REMATCH[1]}"
        local count
        count="$(grep -Eo '[0-9]+' <<<"$output" | head -1 || true)"
        [[ -n "$count" ]] || return 1
        [[ "$count" -ge "$threshold" ]]
        return $?
    fi

    case "$expected_lc" in
        *"0 directories"*|*"0 mounts"*|*"0 sockets"*|*"0 files"*|*"0 matches"*|*"0 log files"*|*"0 token files"*|*"0 socket files"*)
            local count
            count="$(grep -Eo '[0-9]+' <<<"$output" | head -1 || true)"
            [[ "${count:-}" == "0" ]]
            return $?
            ;;
        *"1 or more"*|*"at least one"*|*"multiple"*|*"several"*)
            local count
            count="$(grep -Eo '[0-9]+' <<<"$output" | head -1 || true)"
            [[ -n "$count" ]] || return 1
            if [[ "$expected_lc" == *"multiple"* || "$expected_lc" == *"several"* ]]; then
                [[ "$count" -ge 2 ]]
            else
                [[ "$count" -ge 1 ]]
            fi
            return $?
            ;;
        *"3-10 env vars"*|*"3 to 10 env vars"*|*"3-10 env vars only"*)
            local count
            count="$(grep -Eo '[0-9]+' <<<"$output" | head -1 || true)"
            [[ -n "$count" ]] || return 1
            [[ "$count" -ge 3 && "$count" -le 10 ]]
            return $?
            ;;
        *"readable file with size > 0"*|*"size > 0 bytes"*|*"size > 0"*)
            local size
            size="$(grep -Eo '[0-9]+' <<<"$output" | tail -1 || true)"
            [[ -n "$size" ]] || return 1
            [[ "$size" -gt 0 ]]
            return $?
            ;;
        *"no such file"*|*"file not found"*|*"directory not found"*|*"not found error"*)
            grep -Eqi 'no such file|not found|directory_not_found|directory not found' <<<"$output"
            return $?
            ;;
        *"timeout or connection refused"*|*"connection refused"*|*"network unreachable"*|*"could not resolve"*)
            grep -Eqi 'failed to connect|connection refused|network unreachable|timeout|could not resolve|curl_exit=[1-9]' <<<"$output"
            return $?
            ;;
        # These name a SPECIFIC artefact the step must print, so silence really is
        # a failure for them. Listed first: `case` takes the first match, and
        # "shutdown command succeeds" would otherwise fall into the generic
        # exit-code branch below and stop requiring its output.
        # "grep succeeds" is a claim about a MATCH, so it means output, not exit
        # status — a step may chain several greps and end on a non-zero one while
        # the match it cares about was printed. Listed before the generic
        # "succeeds" branch, which honours the exit code instead.
        *"grep succeeds"*|*"container id returned"*|*"launches without error"*|*"shutdown command succeeds"*)
            [[ -n "$output" ]]
            return $?
            ;;
        # Order 661-nm73. A bare "succeeds" is a claim about the step's OUTCOME,
        # not about it printing something. Requiring non-empty output made ABSENCE
        # assertions unpassable by construction: the canonical form is a negated
        # grep (`! grep -E '<forbidden>' file`), which — when the property HOLDS —
        # matches nothing, prints nothing, and exits 0. Correct behaviour, empty
        # output, and the runner called it FAIL.
        #
        # That punished exactly the tests that check something is NOT there, which
        # are the negative controls this project relies on. litmus:no-raw-error-in-
        # status-chip failed this way while the property it asserts was true.
        #
        # It honours the EXIT CODE ONLY — deliberately, and `output || exit_code`
        # was tried first and is wrong. With `! grep`, a VIOLATION prints the
        # offending lines and exits 1, so any condition that accepts non-empty
        # output passes the very case the step exists to catch. That is how
        # litmus:no-raw-error-in-status-chip came to be inverted in BOTH
        # directions: silent-and-correct read as FAIL, loud-and-violating read as
        # PASS. Caught by injecting a violation and watching the step stay green.
        #
        # "succeeds" is a claim about the outcome. The exit code IS the outcome.
        *"succeeds"*)
            [[ "$exit_code" -eq 0 ]]
            return $?
            ;;
        *"path is correctly set"*|*"cargo"*)
            grep -Eqi 'cargo' <<<"$output"
            return $?
            ;;
        *"token file exists in git-service"*)
            grep -q 'TOKEN_MOUNTED' <<<"$output"
            return $?
            ;;
        *"token files are present"*|*"token files are readable"*)
            local count
            count="$(grep -Eo '[0-9]+' <<<"$output" | head -1 || true)"
            [[ -n "$count" ]] || return 1
            [[ "$count" -ge 1 ]]
            return $?
            ;;
        *"minimal env vars"*|*"minimal necessary vars present"*)
            grep -Eqi '^(PATH|HOME|USER)=' <<<"$output"
            return $?
            ;;
    esac

    if grep -Fqi "$expected" <<<"$output" || grep -Fqi "$expected_lc" <<<"$output_lc"; then
        return 0
    fi

    return 1
}

run_rust_queries_for_litmus() {
    local test_file="$1"

    if ! grep -qE '^rust_queries:' "$test_file"; then
        return 0
    fi

    # @trace spec:spec-traceability
    local output=""
    local status=0
    printf '  [RUST QUERIES] %s...' "$(basename "$test_file")" >&2

    # Run-don't-stat (order 770-ifeg): `-x` passes for the OTHER platform's
    # artifact on a shared Windows/WSL checkout; probe by execution via the
    # shared helper (sourced in a subshell so this large script's namespace
    # stays untouched).
    local litmus_rust_bin=""
    litmus_rust_bin="$(. "$PROJECT_ROOT/scripts/plan-binary-probe.sh" \
        && resolve_target_binary tillandsias-litmus-rust debug "$PROJECT_ROOT")" || litmus_rust_bin=""
    if command -v tillandsias-litmus-rust >/dev/null 2>&1; then
        output="$(tillandsias-litmus-rust check --litmus "$test_file" 2>&1)" || status=$?
    elif [[ -n "$litmus_rust_bin" ]]; then
        output="$("$litmus_rust_bin" check --litmus "$test_file" 2>&1)" || status=$?
    else
        output="$(cargo run --quiet -p tillandsias-litmus-rust -- check --litmus "$test_file" 2>&1)" || status=$?
    fi

    if [[ "$status" -ne 0 ]]; then
        printf ' %b[FAIL]%b\n' "${RED}" "${NC}" >&2
        printf '%s\n' "$output" >&2
        return 1
    fi

    printf ' %b[OK]%b\n' "${GREEN}" "${NC}" >&2
    [[ -n "$output" ]] && printf '%s\n' "$output" >&2
    return 0
}

normalize_spec_list() {
    local raw="${1:-}"
    raw="${raw//:/ }"
    raw="${raw//,/ }"
    for item in $raw; do
        [[ -n "$item" ]] && printf '%s\n' "$item"
    done | awk '!seen[$0]++'
}

spec_in_list() {
    local needle="$1"
    local raw_list="${2:-}"

    [[ -z "$raw_list" ]] && return 1
    while IFS= read -r item; do
        [[ "$item" == "$needle" ]] && return 0
    done < <(normalize_spec_list "$raw_list")
    return 1
}

spec_is_ignored() {
    local spec_id="$1"
    [[ -z "$IGNORE_SPEC_LIST" ]] && return 1
    spec_in_list "$spec_id" "$IGNORE_SPEC_LIST"
}

should_fail_fast_for_spec() {
    local spec_id="$1"

    if spec_is_ignored "$spec_id"; then
        return 1
    fi
    [[ "$STRICT_MODE" != "1" ]] && return 1
    [[ -z "$STRICT_SPEC_LIST" ]] && return 0
    spec_in_list "$spec_id" "$STRICT_SPEC_LIST"
}

# Parse and execute litmus test file
# Returns 0 (success) if test should be considered passing, 1 (failure) otherwise
# Note: Does NOT log results - caller is responsible for that
run_litmus_test_file() {
    local test_file="$1"
    local spec_id="${2:-}"

    if [[ ! -f "$test_file" ]]; then
        return 1
    fi

    # Environmental preflight: when a test needs REAL podman but podman is
    # stalled (a hard-killed writer's surviving threads hold the sqlite
    # storage lock; every call blocks ~100s in busy-retry), each podman test
    # burns its full step budget and FAILs as a fake regression. Probe once,
    # fail FAST with the environmental cause named. fake-backend tests
    # (LITMUS_PODMAN_MODE=fake) never touch real podman — exempt.
    # Trigger only when a critical-path COMMAND actually invokes podman —
    # a test that merely MENTIONS the word (e.g. the cross-target cfg sweep
    # naming the tillandsias-podman crate) must not inherit the podman
    # environment. On Windows hosts common.sh primes a podman shim that
    # exists-but-fails, which turned every grep-shape litmus into a false
    # ENV-FAIL (2026-07-15 windows repro).
    # PLEASE REVIEW: linux — trigger tightened from whole-file grep to
    # command lines by the windows lane.
    # Evidence: plan/issues/podman-sqlite-lock-zombie-cascade-2026-07-15.md
    # Linux hosts ONLY: on macOS/Windows podman is VM-internal by design —
    # a homebrew podman CLI with no machine is the NORMAL host state, and
    # the un-gated preflight blanket-ENV-FAILed 35 source-shape checks on
    # darwin (2026-07-15, instant suite 96%→72%). Merge synthesis
    # 2026-07-16: macOS's platform gate + windows' tightened trigger
    # (command lines that actually invoke podman, not whole-file mentions)
    # — each lane independently fixed one half of the same over-trigger.
    # Order 797-5kqe: THE PROBE MUST REPORT WHAT IT SAW, NOT WHAT IT ASSUMED.
    # This used to be a bare `! timeout 5 podman ps`, and every non-zero exit
    # was announced as "podman unresponsive (>5s): stalled storage lock or dead
    # runtime — environmental, not a code regression". `timeout` returns 124
    # only when it ACTUALLY timed out; for anything else it returns the
    # command's own status — 127 for a wrapper whose exec target was deleted,
    # 126, 125, 1. So a podman that failed in three milliseconds was reported
    # as one that stalled for over five seconds, with a named cause and a
    # citation. Cost, measured this cycle: roughly four hours and three wrong
    # root causes, while `podman info` was sampled at 0.07s on 45 consecutive
    # samples taken DURING the run that called podman unresponsive.
    # The "environmental, not a code regression" verdict is the worse half: it
    # is what makes a reader stop looking, and here it was attached to a
    # genuine code-level configuration defect (797-r6tc). A preflight may
    # report what it observed; it must not classify a failure it did not
    # diagnose. Pinned by litmus:litmus-podman-preflight-diagnosis-shape.
    if [ "$(uname -s)" = "Linux" ] \
        && grep -qE '^[[:space:]]*command:.*(^|[ ;|&(])podman[[:space:]]' "$test_file" 2>/dev/null \
        && ! grep -q '^backend: fake' "$test_file" 2>/dev/null \
        && command -v podman >/dev/null 2>&1; then
        local _preflight_err=""
        local _preflight_rc=0
        # Assignment first, status captured on the SAME command: a `local
        # x="$(...)"` one-liner would report local's own status, not the
        # probe's, which is the exit-code-masking class this file gates for.
        _preflight_err="$(timeout 5 podman ps --format '{{.ID}}' 2>&1 >/dev/null)" \
            || _preflight_rc=$?
        if [ "$_preflight_rc" -eq 124 ]; then
            echo -e "  ${RED}[ENV-FAIL]${NC} podman did not answer 'podman ps' within 5s (timeout, exit 124) — consistent with a stalled storage lock or a dead runtime (plan/issues/podman-sqlite-lock-zombie-cascade-2026-07-15.md)"
            return 1
        elif [ "$_preflight_rc" -ne 0 ]; then
            echo -e "  ${RED}[ENV-FAIL]${NC} 'podman ps' FAILED IMMEDIATELY with exit ${_preflight_rc} — this is not a timeout and the cause is not diagnosed here. podman resolved to '$(command -v podman)' and said: ${_preflight_err:-(no output)}"
            return 1
        fi
    fi

    if ! run_rust_queries_for_litmus "$test_file"; then
        return 1
    fi

    # Parse YAML: extract critical_path steps and gating_points.
    # The runner executes each critical-path step sequentially; later
    # assertions depend on earlier setup work.
    local in_critical_path=0
    local in_gating_points=0
    local current_step_name=""
    local current_step_command=""
    local current_step_timeout=30000
    local current_step_expected=""
    local current_step_success_pattern=""
    local current_step_failure_pattern=""
    local -a step_names=()
    local -a step_commands=()
    local -a step_timeouts=()
    local -a step_expecteds=()
    local -a step_success_patterns=()
    local -a step_failure_patterns=()
    local -a unparsed_step_names=()
    local success_criteria=()
    local failure_criteria=()

    append_step() {
        # A named step whose command: could not be extracted is a PARSE
        # failure, not a silently droppable entry (order 256: a folded `>-`
        # command parsed to zero steps and the litmus failed as a generic
        # "Check implementation" with no diagnostic since authoring).
        if [[ -z "$current_step_command" ]]; then
            [[ -n "$current_step_name" ]] && unparsed_step_names+=("$current_step_name")
            return 0
        fi
        step_names+=("$current_step_name")
        step_commands+=("$current_step_command")
        step_timeouts+=("$current_step_timeout")
        step_expecteds+=("$current_step_expected")
        step_success_patterns+=("$current_step_success_pattern")
        step_failure_patterns+=("$current_step_failure_pattern")
    }

    while IFS= read -r line; do
        if [[ "$line" =~ ^critical_path: ]]; then
            in_critical_path=1
            in_gating_points=0
            continue
        fi

        if [[ "$line" =~ ^gating_points: ]]; then
            append_step
            current_step_name=""
            current_step_command=""
            current_step_timeout=30000
            current_step_expected=""
            current_step_success_pattern=""
            current_step_failure_pattern=""
            in_critical_path=0
            in_gating_points=1
            continue
        fi

        if [[ "$line" =~ ^[a-z_]+: ]]; then
            append_step
            current_step_name=""
            current_step_command=""
            current_step_timeout=30000
            current_step_expected=""
            current_step_success_pattern=""
            current_step_failure_pattern=""
            in_critical_path=0
            in_gating_points=0
        fi

        if [[ $in_critical_path -eq 1 ]]; then
            if [[ "$line" =~ ^[[:space:]]*-[[:space:]]step:\ \"(.+)\" ]]; then
                append_step
                current_step_name="${BASH_REMATCH[1]}"
                current_step_command=""
                current_step_timeout=30000
                current_step_expected=""
                current_step_success_pattern=""
                current_step_failure_pattern=""
            elif [[ "$line" =~ ^[[:space:]]*command:\ \"(.+)\" ]]; then
                # YAML escapes \" as a double-quote inside a double-quoted
                # string. The bash regex above captures the raw bytes between
                # the outer "s, so the captured value retains the backslashes.
                # When that value is later run via `bash -c`, the sub-shell
                # treats unquoted \" as a literal " character — meaning test
                # commands like `... \"$VAR\" ...` send a quote-wrapped value
                # to the underlying program (e.g. podman: parsing reference
                # "\"localhost/foo\""). Unescape here so commands behave the
                # way they read.
                #
                # Also collapse \\ -> \, matching real YAML double-quote
                # escaping (the only valid YAML way to embed one literal
                # backslash, e.g. for a grep -E `\.`/`\(`/`\)`/`\|`). Order
                # matters: do the \" pass FIRST, then \\ — this reproduces
                # YAML's own left-to-right escape consumption for combined
                # sequences (e.g. raw `\\\"` -> `\"` -> `\"`, matching a real
                # YAML parser, not `\\\"` -> (both passes blindly interact) ->
                # something else). Without this second pass, a `command:`
                # string that is valid YAML and reads correctly under
                # `ruby -ryaml` could still execute with an extra literal
                # backslash at runtime, silently breaking any escaped
                # metacharacter with no parse error anywhere — see
                # plan/issues/litmus-runner-command-backslash-escaping-2026-07-06.md.
                current_step_command="$(yaml_unescape_dq "${BASH_REMATCH[1]}")"
            elif [[ "$line" =~ timeout_ms:\ ([0-9]+) ]]; then
                current_step_timeout="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ expected_behavior:\ \"(.+)\" ]]; then
                current_step_expected="$(yaml_unescape_dq "${BASH_REMATCH[1]}")"
            elif [[ "$line" =~ expected_behavior:\ (.+)$ ]]; then
                # PLAIN (unquoted) YAML scalar: no escape sequences exist in
                # one, so a `\"` here is literally backslash-quote and must NOT
                # be unescaped. Only the double-quoted branch above may be.
                current_step_expected="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ success_pattern:\ \"(.+)\" ]]; then
                current_step_success_pattern="$(yaml_unescape_dq "${BASH_REMATCH[1]}")"
            elif [[ "$line" =~ failure_pattern:\ \"(.+)\" ]]; then
                current_step_failure_pattern="$(yaml_unescape_dq "${BASH_REMATCH[1]}")"
            fi
        fi

        if [[ $in_gating_points -eq 1 ]]; then
            if [[ "$line" =~ success:\ \"(.+)\" ]]; then
                success_criteria+=("${BASH_REMATCH[1]}")
            elif [[ "$line" =~ failure:\ \"(.+)\" ]]; then
                failure_criteria+=("${BASH_REMATCH[1]}")
            fi
        fi
    done < "$test_file"

    append_step

    # A named step whose command: cannot be extracted is a hard PARSE FAIL
    # (order 267 promotion, 2026-07-10): the corpus carries zero folded
    # commands post-slice-2, so an unparseable step is authoring drift, not
    # legacy debt — silently thinner coverage was the original dead-check
    # vector (31 steps skipped since authoring before the rewrite).
    if [[ "${#unparsed_step_names[@]}" -gt 0 ]]; then
        printf '  %b[PARSE FAIL]%b %s\n' "${RED}" "${NC}" "$test_file" >&2
        for us in "${unparsed_step_names[@]}"; do
            printf '%s\n' "         step '${us}': command: not extractable (single-line double-quoted scalar required; folded '>'/'>-' unsupported)" >&2
        done
        return 1
    fi

    # A file with ZERO parseable steps has always failed — but generically
    # ("Check implementation"). Name the real reason (order 256).
    if [[ "${#step_commands[@]}" -eq 0 ]]; then
        printf '  %b[PARSE ERROR]%b %s: no parseable critical_path steps (each step needs a single-line double-quoted command: scalar)\n' "${RED}" "${NC}" "$test_file" >&2
        return 1
    fi

    # ORDER 958-b36m. PARSE-ONLY returns HERE — after the same parse the real
    # run does, and before a single step is executed. Both refusals above
    # (PARSE FAIL for an unextractable named step, PARSE ERROR for a file with
    # no steps at all) have already fired if they apply, so this mode's verdict
    # is the runner's verdict by construction rather than by imitation.
    if [[ $PARSE_ONLY -eq 1 ]]; then
        printf 'ok:litmus-parseable:%s:%d step(s)\n' "$test_file" "${#step_commands[@]}"
        return 0
    fi

    local combined_output=""
    local step_index=0

    for idx in "${!step_commands[@]}"; do
        local step_name="${step_names[$idx]}"
        local step_command="${step_commands[$idx]}"
        local step_timeout_ms="${step_timeouts[$idx]}"
        local step_expected="${step_expecteds[$idx]}"
        local step_success_pattern="${step_success_patterns[$idx]}"
        local step_failure_pattern="${step_failure_patterns[$idx]}"
        local step_output=""
        local exit_code=0

        step_index=$((step_index + 1))
        local timeout_sec=$(( step_timeout_ms / 1000 ))

        # Progress reporting: show step start and timeout value
        # Always show progress to prevent user-perceived hangs during long-running tests
        # @trace spec:spec-traceability
        printf '  [STEP %d/%d] %s (timeout: %ds)...' "$step_index" "${#step_commands[@]}" "$step_name" "$timeout_sec" >&2

        # Capture step output to a FILE, never a command-substitution pipe:
        # a fixture grandchild that survives the step (daemonized test
        # server, detached container) inherits the pipe write-end and blocks
        # this read FOREVER — three gate wedges on 2026-07-15, each unblocked
        # only by hand-killing the stray (see
        # plan/issues/podman-sqlite-lock-zombie-cascade-2026-07-15.md).
        # A file read EOFs at whatever was written; survivors keep writing
        # harmlessly after the step is scored. --kill-after: TERM first
        # (podman writers get a sqlite-rollback window), then KILL for
        # TERM-immune fixtures.
        local step_capture
        step_capture="$(mktemp "${TMPDIR:-/tmp}/litmus-step-capture.XXXXXX")"
        LITMUS_STDLIB="${LITMUS_STDLIB}" timeout --kill-after=10s "${timeout_sec}s" bash -c 'source "$LITMUS_STDLIB"; '"${step_command}" >"$step_capture" 2>&1 || exit_code=$?
        step_output="$(cat "$step_capture")"
        rm -f "$step_capture"
        combined_output+=$'\n'"[${step_index}:${step_name}]${step_output}"

        if [[ $exit_code -eq 124 ]]; then
            printf ' %b[TIMEOUT]%b\n' "${RED}" "${NC}" >&2
            log_warn "Test timeout after ${timeout_sec}s in step: ${step_name:-step-${step_index}}"
            # ORDER 820-c8q8. A TIMEOUT has two causes that read identically,
            # and both happened on macuahuitl on 2026-08-18 within one hour:
            #   * fragment-status-loss step 5 — the guard genuinely took 41s
            #     against a 30s budget (a real regression, 816-kq2z).
            #   * forge-standard-gitconfig-path step 1 — the SAME fixture exits
            #     0 in ZERO seconds when run alone, and had passed in the
            #     previous full run. The box was saturated.
            # In the first the answer was to fix code; in the second, to re-run.
            # Nothing on the line distinguished them, so the verdict named a
            # suspect it had not convicted.
            #
            # ELAPSED TIME CANNOT DISCRIMINATE — a killed step always elapses
            # its budget, by construction. Load at kill time can: a runqueue
            # longer than the core count means other work was competing for the
            # CPU this step was being timed on. Reported, never used to change
            # the verdict: the step still FAILS, because a step that cannot
            # finish inside its budget on this host has not passed.
            _lt_load="unknown"; _lt_cpus="unknown"
            if [ -r /proc/loadavg ]; then
                _lt_load="$(cut -d' ' -f1 < /proc/loadavg 2>/dev/null)"
            elif command -v sysctl >/dev/null 2>&1; then
                _lt_load="$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | awk '{print $1}')"
            fi
            if command -v nproc >/dev/null 2>&1; then
                _lt_cpus="$(nproc 2>/dev/null)"
            elif command -v sysctl >/dev/null 2>&1; then
                _lt_cpus="$(sysctl -n hw.ncpu 2>/dev/null)"
            fi
            case "${_lt_load}:${_lt_cpus}" in
                unknown:*|*:unknown|:*|*:)
                    log_warn "  load at kill time: unavailable on this host — cause UNCLASSIFIED (slow step vs starved step)" ;;
                *)
                    # Scaled integer compare; bash 3.2 has no floats and bc is
                    # not guaranteed present.
                    _lt_l100="$(printf '%s' "$_lt_load" | awk '{printf "%d", $1 * 100}' 2>/dev/null)"
                    _lt_c100=$(( _lt_cpus * 100 ))
                    if [ -n "$_lt_l100" ] && [ "$_lt_l100" -gt "$_lt_c100" ] 2>/dev/null; then
                        log_warn "  load1=${_lt_load} over ${_lt_cpus} cpus — host SATURATED at kill time; a step that is fast when idle can be starved here, so re-run before treating this as a regression"
                    else
                        log_warn "  load1=${_lt_load} over ${_lt_cpus} cpus — host NOT saturated at kill time; this step is genuinely too slow for its ${timeout_sec}s budget"
                    fi
                    ;;
            esac
            return 1
        fi

        # Patternless non-zero exits (order 256): when a step declares
        # neither success_pattern nor expected_behavior, its exit code is
        # the only signal it has — a non-zero exit FAILS the step (the
        # order-256 dead-check trap). STRICT IS THE DEFAULT as of order
        # 267's flip (2026-07-10, staged flag→burn-down→default per
        # migration discipline; the corpus was 156/156 strict at flip
        # time). TILLANDSIAS_LITMUS_STRICT_EXIT=0 is the emergency opt-out
        # — using it on a red is a finding to file, not a fix.
        if [[ $exit_code -ne 0 && -z "$step_success_pattern" && -z "$step_expected" ]]; then
            if [[ "${TILLANDSIAS_LITMUS_STRICT_EXIT:-1}" != "0" ]]; then
                printf ' %b[FAIL]%b\n' "${RED}" "${NC}" >&2
                printf '%s\n' "         exit_code=${exit_code} (no success_pattern/expected_behavior declared — non-zero exit fails the step; strict-exit mode)" >&2
                printf '%s\n' "         output=${step_output}" >&2
                return 1
            fi
            printf ' %b[DEAD-CHECK WARNING]%b\n' "${YELLOW}" "${NC}" >&2
            printf '%s\n' "         exit_code=${exit_code} with no declared pattern — PASSING via the TILLANDSIAS_LITMUS_STRICT_EXIT=0 opt-out (file a finding; the opt-out is not a fix)" >&2
        fi

        # If success_pattern is declared, use check_signal() which is
        # authoritative for regex-based pass/fail. Otherwise fall back to the
        # expected_behavior heuristic for backward compatibility with steps
        # that rely on its keyword-matching logic.
        if [[ -n "$step_success_pattern" ]]; then
            if ! check_signal "$step_output" "$step_success_pattern" "$step_failure_pattern"; then
                printf ' %b[FAIL]%b\n' "${RED}" "${NC}" >&2
                printf '%s\n' "         success_pattern=${step_success_pattern}" >&2
                [[ -n "$step_failure_pattern" ]] && printf '%s\n' "         failure_pattern=${step_failure_pattern}" >&2
                printf '%s\n' "         output=${step_output}" >&2
                return 1
            fi
        elif ! behavior_matches_output "$step_output" "$step_expected" "$exit_code"; then
            printf ' %b[FAIL]%b\n' "${RED}" "${NC}" >&2
            printf '%s\n' "         expected=${step_expected}" >&2
            printf '%s\n' "         output=${step_output}" >&2
            # ORDER 868-p8xi. An expectation written as a regex alternation is
            # searched for VERBATIM — behavior_matches_output's fallback is
            # `grep -Fqi` — so it can never match and the step fails on every
            # one of its own legitimate outcomes. That is what happened to
            # litmus:sidecar-arch-derivation STEP 3, which printed
            # `ok: staged-arch-matches` against an expectation that listed
            # exactly that string among three alternatives, and still failed.
            #
            # Named only HERE, in the already-failing path, so it costs a green
            # run nothing and cannot produce a false positive. The alternative —
            # teaching the matcher to interpret expectations as regexes — would
            # silently reinterpret every existing expectation that happens to
            # contain a metacharacter, which is a far wider blast radius than
            # the one authoring mistake it would fix.
            if [[ "$step_expected" =~ \([^\)]*\|[^\)]*\) ]]; then
                printf '%s\n' "         note: this expectation contains (a|b) alternation, but expectations are matched as a LITERAL SUBSTRING, not a regex — rewrite it as the longest literal all accepted outputs share (868-p8xi)" >&2
            fi
            return 1
        fi

        # Step matched expected behavior — surface success only after validation.
        printf ' %b[OK]%b\n' "${GREEN}" "${NC}" >&2
    done

    for failure in "${failure_criteria[@]}"; do
        if grep -qE "$failure" <<<"$combined_output"; then
            printf '  %b[FAIL]%b gating_points.failure matched: %s\n' "${RED}" "${NC}" "$failure" >&2
            return 1
        fi
    done

    if [[ "${#success_criteria[@]}" -gt 0 ]]; then
        for success in "${success_criteria[@]}"; do
            if grep -qE "$success" <<<"$combined_output"; then
                return 0
            fi
        done
        printf '  %b[FAIL]%b no gating_points.success criterion matched combined output\n' "${RED}" "${NC}" >&2
        local first_success="${success_criteria[0]}"
        printf '         tried: %s\n' "${success_criteria[*]}" >&2
        return 1
    fi

    return 0
}

# Main test execution loop
run_tests_for_spec() {
    local spec_id="$1"

    if spec_is_ignored "$spec_id"; then
        [[ "$COMPACT" == "1" ]] || log_warn "Ignoring spec: $spec_id"
        record_spec_result "$spec_id"
        return 0
    fi

    [[ "$COMPACT" == "1" ]] || log_spec_start "$spec_id"

    # Get all litmus tests bound to this spec
    local litmus_tests
    litmus_tests="$(get_litmus_tests_for_spec "$spec_id")"

    if [[ -z "$litmus_tests" ]]; then
        if should_fail_fast_for_spec "$spec_id"; then
            log_fail "spec=$spec_id no litmus tests bound; strict filter requires an executable boundary"
            printf '@trace spec:%s\n' "$spec_id" >&2
            return 21
        fi
        [[ "$COMPACT" == "1" ]] || log_warn "No litmus tests bound to spec: $spec_id"
        record_spec_result "$spec_id"
        return 0
    fi

    # Execute each litmus test
    local test_count=0
    local spec_failed=0
    local spec_skipped=0
    while IFS= read -r test_name; do
        [[ -z "$test_name" ]] && continue

        # Skip if already executed globally (same test bound to multiple specs)
        if litmus_global_seen "$test_name"; then
            log_test_result "$spec_id" "$test_name" "SKIP" "Already executed (bound to multiple specs)"
            spec_skipped=1
            test_count=$((test_count+1))
            continue
        fi
        litmus_global_mark_seen "$test_name"

        # Convert colon to hyphen for file lookup (litmus:ephemeral-guarantee -> litmus-ephemeral-guarantee)
        local test_file="${LITMUS_TESTS_DIR}/${test_name//:/-}.yaml"

        if [[ ! -f "$test_file" ]]; then
            if should_fail_fast_for_spec "$spec_id"; then
                log_test_result "$spec_id" "$test_name" "FAIL" "Test file not found"
                printf '@trace spec:%s\n' "$spec_id" >&2
                return 21
            fi
            log_test_result "$spec_id" "$test_name" "SKIP" "Test file not found"
            spec_skipped=1
            test_count=$((test_count+1))
            continue
        fi

        local test_phase
        test_phase="$(get_test_phase "$test_file")"
        if [[ "$FILTER_PHASE" != "all" && "$test_phase" != "$FILTER_PHASE" ]]; then
            log_test_result "$spec_id" "$test_name" "SKIP" "Phase mismatch: $test_phase"
            spec_skipped=1
            test_count=$((test_count+1))
            continue
        fi

        # Order 661-emqi. Host-kind gate, before size so a forge-only test on a
        # laptop reports WHY it did not run rather than looking like a size miss.
        local test_host_kind
        test_host_kind="$(get_test_host_kind "$test_file")"
        if [[ "$test_host_kind" != "any" && "$test_host_kind" != "$(current_host_kind)" ]]; then
            log_test_result "$spec_id" "$test_name" "SKIP" "Host-kind mismatch: needs ${test_host_kind}, this host is $(current_host_kind)"
            spec_skipped=1
            test_count=$((test_count+1))
            continue
        fi

        local test_size
        test_size="$(get_test_size "$test_file")"
        if ! size_matches_filter "$test_size" "$SIZE_FILTER"; then
            log_test_result "$spec_id" "$test_name" "SKIP" "Size mismatch: $test_size"
            spec_skipped=1
            test_count=$((test_count+1))
            continue
        fi

        # Order 765-mza8: diff-scoped skip, LAST of the four selection gates so
        # a scoped-out test is never confused with a phase/host/size miss.
        #
        # Three independent conditions must ALL hold to skip, and each one is a
        # fail-closed door: scoping resolved, the test declares its inputs, none
        # of those inputs intersect the diff — and the test's OWN file is
        # unchanged, because editing a test is the one edit that must always
        # re-run it (its verdict lives in that file, not only in its inputs).
        if [[ "$DIFF_SCOPE_ACTIVE" -eq 1 ]]; then
            local test_inputs test_file_rel
            test_inputs="$(get_test_inputs "$test_file")"
            test_file_rel="${test_file#"$PROJECT_ROOT"/}"
            if [[ -n "$test_inputs" ]] \
                && ! printf '%s\n' "$DIFF_SCOPE_CHANGED" | grep -qxF "$test_file_rel" \
                && ! litmus_inputs_intersect_diff "$test_inputs" "$DIFF_SCOPE_CHANGED"; then
                log_test_result "$spec_id" "$test_name" "SKIP" \
                    "Diff-scoped: declared inputs untouched since ${DIFF_SCOPE_BASE_SHA:0:12}"
                DIFF_SCOPE_SKIPS=$((DIFF_SCOPE_SKIPS+1))
                spec_skipped=1
                test_count=$((test_count+1))
                continue
            fi
        fi

        # Execute test and capture result
        # Always show which test is executing to prevent user-perceived hangs
        # @trace spec:spec-traceability
        printf '%bℹ%b Executing %s...\n' "${BLUE}" "${NC}" "$test_name" >&2

        # 765-dfry: time every executed test so the quick lane is rankable
        # test-by-test. Capture is two clock reads; emission is batched at
        # suite end. Best-effort: a stubbed clock yields t0=0 and the record
        # is dropped downstream, never poisoned.
        local _pt_t0 _pt_dur _pt_rc
        _pt_t0="$(timing_now_ms 2>/dev/null || echo 0)"
        if run_litmus_test_file "$test_file" "$spec_id"; then
            _pt_rc=0
            log_test_result "$spec_id" "$test_name" "PASS" ""
        else
            _pt_rc=1
            log_test_result "$spec_id" "$test_name" "FAIL" "Check implementation"
            spec_failed=1
        fi
        if [[ "$_pt_t0" =~ ^[0-9]+$ && "$_pt_t0" -gt 0 ]]; then
            _pt_dur=$(( $(timing_now_ms 2>/dev/null || echo 0) - _pt_t0 ))
            [[ "$_pt_dur" -ge 0 && "$_pt_dur" -lt 86400000 ]] || _pt_dur=0
            _PER_TEST_LOG="${_PER_TEST_LOG}${_pt_dur}	${test_name}	${_pt_rc}
"
        fi
        if [[ "$_pt_rc" -ne 0 ]] && should_fail_fast_for_spec "$spec_id"; then
            printf '@trace spec:%s\n' "$spec_id" >&2
            return 20
        fi

        test_count=$((test_count+1))
    done <<<"$litmus_tests"

    record_spec_result "$spec_id"

    return 0
}

# ============================================================================
# REPORTING
# ============================================================================

print_summary() {
    local total_executed=$((TESTS_PASSED + TESTS_FAILED))
    local coverage_ratio="0"

    if [[ $total_executed -gt 0 ]]; then
        coverage_ratio="$((TESTS_PASSED * 100 / total_executed))"
    fi

    echo "" >&2
    printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n' >&2
    printf '%bTest Results Summary%b\n' "${BOLD}" "${NC}" >&2
    printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n' >&2

    printf '  %bPASS%b:  %d\n' "${GREEN}" "${NC}" "$TESTS_PASSED" >&2
    printf '  %bFAIL%b:  %d\n' "${RED}" "${NC}" "$TESTS_FAILED" >&2
    printf '  %bSKIP%b:  %d (excluded from coverage)\n' "${YELLOW}" "${NC}" "$TESTS_SKIPPED" >&2
    printf '  %bTotal%b: %d (executed: %d, skipped: %d)\n' "${BOLD}" "${NC}" "$TESTS_RUN" "$total_executed" "$TESTS_SKIPPED" >&2
    echo "" >&2

    # Coverage calculation (excluding skipped tests)
    local all_specs
    all_specs="$(get_all_active_specs)"
    local total_specs=0
    if [[ -n "$all_specs" ]]; then
        total_specs="$(printf '%s\n' "$all_specs" | grep -c . || echo 0)"
    fi
    local covered_specs=0
    local spec_count=$SPEC_RESULTS_COUNT
    if [[ $total_specs -gt 0 ]]; then
        covered_specs=$(( spec_count * 100 / total_specs ))
    fi

    local coverage_text
    # coverage_text computed to avoid bash subshell interpretation of parentheses
    coverage_text="[$spec_count/$total_specs specs]"
    printf '%bCoverage%b: %d%% %s\n' "${BOLD}" "${NC}" "$covered_specs" "$coverage_text" >&2
    printf '%bPass Rate%b: %d%% (%d/%d executed)\n' "${BOLD}" "${NC}" "$coverage_ratio" "$TESTS_PASSED" "$total_executed" >&2

    # Order 765-mza8: the skip ledger. A scoped run states its cost in coverage
    # on EVERY run, including when it skipped nothing, because "silent
    # truncation reads as covered everything" (audit F12) and the reader cannot
    # tell a scoped green from a full green without being told.
    if [[ -n "$DIFF_SCOPE_BASE" ]]; then
        if [[ "$DIFF_SCOPE_ACTIVE" -eq 1 ]]; then
            printf '%bDiff-scope%b: %d diff-scoped skips against base %s\n' \
                "${BOLD}" "${NC}" "$DIFF_SCOPE_SKIPS" "${DIFF_SCOPE_BASE_SHA:0:12}" >&2
        else
            printf '%bDiff-scope%b: REFUSED — ran FULL (see the reason above)\n' \
                "${BOLD}" "${NC}" >&2
        fi
    fi
    echo "" >&2

    # 765-dfry: per-test durations — ONE batch emission for the whole suite,
    # plus a ranked slowest-tests block so the compact view names what
    # dominates the lane (quiet threshold 500ms, top 10 — the full ranking
    # lives in the timing records; 734-sjb3 noise discipline).
    if [[ -n "$_PER_TEST_LOG" ]]; then
        {
            printf '%s' "$_PER_TEST_LOG" | awk -F'\t' \
                -v phase="${FILTER_PHASE:-unknown}" \
                -v host="${TILLANDSIAS_HOST_ID:-$(hostname 2>/dev/null || echo unknown)}" \
                'NF >= 3 { name = $2; sub(/^litmus:/, "", name); printf "litmus:%s\t%s\t%s\t%s\t%s\n", name, phase, $1, $3, host }' \
                | bash "$PROJECT_ROOT/scripts/cycle-metrics.sh" --emit-timing-batch
        } 2>/dev/null || true
        # `|| true`: under `set -eo pipefail`, head's early close SIGPIPEs
        # sort/awk (rc 141) once the sweep is big enough to overflow ten
        # lines, aborting the runner AFTER it printed PASS — ci-full then
        # reported "litmus failures detected" over a log reading 100%
        # (measured 2026-08-25: full pre-build quick sweep exit 141, single
        # -spec runs unaffected because head never closes early on them).
        _slow_tests="$(printf '%s' "$_PER_TEST_LOG" | sort -rn | awk -F'\t' '$1 >= 500 {printf "  %7.1fs  %s\n", $1/1000, $2}' | head -10 || true)"
        if [[ -n "$_slow_tests" ]]; then
            printf '%bSlowest tests%b (>=0.5s, top 10; full ranking in the timing records):\n%s\n\n' "${BOLD}" "${NC}" "$_slow_tests" >&2
        fi
    fi

    # Overall status
    if [[ $TESTS_FAILED -gt 0 ]]; then
        printf 'Status: %b[FAIL]%b\n' "${RED}" "${NC}" >&2
        return 1
    fi

    # ORDER 913-27ex — ZERO EXECUTED IS NOT A PASS.
    #
    # `TESTS_FAILED -eq 0` was the whole verdict, so a run that executed NOTHING
    # printed PASS and exited 0. MEASURED on macuahuitl 2026-08-26:
    #
    #   run-litmus-test.sh subdomain-routing-via-reverse-proxy --phase pre-build --size e2e
    #   Total: 1 (executed: 0, skipped: 1)
    #   Pass Rate: 0% (0/0 executed)
    #   Status: [PASS]                      <-- exit 0
    #
    # The same command without `--phase pre-build` executes the test and returns
    # [FAIL] on a real defect (913-7m3t). So a phase filter turned a failing
    # suite green, and the runner printed `0/0 executed` directly above its own
    # PASS. It had the fact and declined to act on it.
    #
    # THIS WAS REASONED ABOUT AND GOT THE WRONG ANSWER. The FILTER_SPEC guard
    # below says: "Legitimately empty phase/size buckets still have TESTS_RUN >
    # 0 because their bound tests are counted as skips, so this guard preserves
    # those pass semantics." TESTS_RUN was 1 — the skip — so that guard did not
    # fire, and the pass semantics it preserved are the defect.
    #
    # WHAT THIS CHANGES AND WHAT IT DELIBERATELY DOES NOT.
    #
    # The verdict STRING stops saying PASS. The EXIT CODE is unchanged.
    #
    # That split is not timidity; it is the resolution of a genuine conflict
    # this fix uncovered. `litmus:litmus-name-filter-fail-loud-shape` (order
    # 300) deliberately PINS the opposite behaviour — its second case asserts
    # that "a valid explicit spec with every bound test excluded by phase still
    # passes", exit 0. That pin exists because the same shape is LEGITIMATE in
    # ordinary use: iterating specs across phases, or `--diff-scope` on a commit
    # touching no litmus input (most commits), both select nothing through no
    # fault of anyone. Making those non-zero would redden the fleet for the
    # normal case, and a guard that fires constantly gets muted — the outcome
    # 913-27ex's own criteria warn against.
    #
    # But the HARM I measured was not the exit code. It was reading `Status:
    # [PASS]` and nearly recording it as evidence that a suite was green. A
    # verdict of [NO-TESTS-EXECUTED] cannot be misread that way, at zero blast
    # radius, and the existing order-300 guard above still exits non-zero for an
    # explicit filter matching NO BOUND TESTS AT ALL — the distinction order 300
    # actually cared about, which remains intact.
    #
    # LEFT OPEN ON PURPOSE, recorded in 913-27ex rather than decided here:
    # whether a NAMED spec whose tests are all phase-excluded should also exit
    # non-zero. That is a fleet-wide behaviour change against a deliberate pin,
    # and it belongs to the operator/fleet, not to the cycle that happened to
    # find it. The evidence for both sides is in the packet.
    local _executed=$((TESTS_PASSED + TESTS_FAILED))
    if [[ $_executed -eq 0 ]]; then
        printf 'Status: %b[NO-TESTS-EXECUTED]%b\n' "${YELLOW:-}" "${NC}" >&2
        if [[ -n "${FILTER_SPEC:-}" ]]; then
            printf '  filter %s selected %d test(s) and executed NONE — every one was excluded by --phase/--size.\n' \
                "'${FILTER_SPEC}'" "$TESTS_RUN" >&2
            printf '  THIS RUN IS NOT EVIDENCE OF ANYTHING. Widen or drop the phase/size filter to actually verify it.\n' >&2
        else
            printf '  Nothing was selected, so this run proves nothing. Not treated as a failure: --diff-scope on a commit touching no litmus input is the normal case.\n' >&2
        fi
        return 0
    fi

    printf 'Status: %b[PASS]%b\n' "${GREEN}" "${NC}" >&2
    return 0
}

print_json_summary() {
    local total_executed=$((TESTS_PASSED + TESTS_FAILED))
    local pass_rate=0
    if [[ $total_executed -gt 0 ]]; then
        pass_rate=$(( TESTS_PASSED * 100 / total_executed ))
    fi

    local status="FAIL"
    [[ $TESTS_FAILED -eq 0 ]] && status="PASS"

    local spec_count=$SPEC_RESULTS_COUNT

    printf '{\n'
    printf '  "timestamp": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '  "test_results": {\n'
    printf '    "passed": %d,\n' "$TESTS_PASSED"
    printf '    "failed": %d,\n' "$TESTS_FAILED"
    printf '    "skipped": %d,\n' "$TESTS_SKIPPED"
    printf '    "total_run": %d,\n' "$TESTS_RUN"
    printf '    "total_executed": %d\n' "$total_executed"
    printf '  },\n'
    printf '  "coverage": {\n'
    printf '    "specs_tested": %d,\n' "$spec_count"
    printf '    "pass_rate_executed": %d\n' "$pass_rate"
    printf '  },\n'
    printf '  "status": "%s"\n' "$status"
    printf '}\n'
}

list_all_tests() {
    echo "Available Litmus Test Suites:" >&2
    echo "" >&2

    # Get unique test names from bindings
    if [[ -n "$LITMUS_PLAN_BIN" ]] || command -v yq &>/dev/null; then
        { _yaml_jq "$LITMUS_BINDINGS" '.specs[].litmus_tests[]?' \
            || yq eval '.specs[].litmus_tests[]' "$LITMUS_BINDINGS" 2>/dev/null; } | sort -u | while read -r test; do
            local test_file="${LITMUS_TESTS_DIR}/${test}.yaml"
            if [[ -f "$test_file" ]]; then
                local desc
                desc="$(yaml_get "$test_file" ".description" 2>/dev/null || echo "N/A")"
                printf '  %-40s %s\n' "$test" "$desc" >&2
            fi
        done
    else
        ls "$LITMUS_TESTS_DIR"/litmus-*.yaml 2>/dev/null | while read -r file; do
            basename "$file" .yaml
        done | while read -r test; do
            printf '  %s\n' "$test" >&2
        done
    fi

    echo "" >&2
}

# ============================================================================
# ARGUMENT PARSING
# ============================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --list)
                LIST_ONLY=1
                shift
                ;;
            --parse-only)
                PARSE_ONLY=1
                shift
                while [[ $# -gt 0 && "${1:0:1}" != "-" ]]; do
                    PARSE_ONLY_FILES+=("$1")
                    shift
                done
                ;;
            --timeout)
                TIMEOUT_SECONDS="${2}"
                shift 2
                ;;
            --filter|--filter=*)
                if [[ "$1" == *=* ]]; then
                    FILTER_SPEC="${1#*=}"
                    shift
                else
                    if [[ -n "${2:-}" && "${2:0:1}" != "-" ]]; then
                        FILTER_SPEC="${2}"
                        shift 2
                    else
                        FILTER_SPEC=""
                        shift
                    fi
                fi
                ;;
            --strict|--strict=*)
                STRICT_MODE=1
                if [[ "$1" == *=* ]]; then
                    STRICT_SPEC_LIST="${1#*=}"
                    shift
                else
                    if [[ -n "${2:-}" && "${2:0:1}" != "-" ]]; then
                        STRICT_SPEC_LIST="${2}"
                        shift 2
                    else
                        STRICT_SPEC_LIST=""
                        shift
                    fi
                fi
                ;;
            --ignore|--ignore=*)
                if [[ "$1" == *=* ]]; then
                    IGNORE_SPEC_LIST="${1#*=}"
                    shift
                else
                    if [[ -n "${2:-}" && "${2:0:1}" != "-" ]]; then
                        IGNORE_SPEC_LIST="${2}"
                        shift 2
                    else
                        IGNORE_SPEC_LIST=""
                        shift
                    fi
                fi
                ;;
            --spec|--spec=*)
                if [[ "$1" == *=* ]]; then
                    SPEC_SHORTHAND="${1#*=}"
                    shift
                else
                    if [[ -n "${2:-}" && "${2:0:1}" != "-" ]]; then
                        SPEC_SHORTHAND="${2}"
                        shift 2
                    else
                        SPEC_SHORTHAND=""
                        shift
                    fi
                fi
                ;;
            --compact)
                COMPACT=1
                shift
                ;;
            --phase)
                FILTER_PHASE="${2:-all}"
                shift 2
                ;;
            --size|--size=*)
                if [[ "$1" == *=* ]]; then
                    SIZE_FILTER="${1#*=}"
                    shift
                else
                    SIZE_FILTER="${2:-all}"
                    shift 2
                fi
                ;;
            --diff-scope|--diff-scope=*)
                if [[ "$1" == *=* ]]; then
                    DIFF_SCOPE_BASE="${1#*=}"
                    shift
                elif [[ $# -ge 2 && "${2}" != -* ]]; then
                    DIFF_SCOPE_BASE="$2"
                    shift 2
                else
                    # No value, or the next token is another flag. Do NOT
                    # `shift 2` past the end: under `set -e` that aborts the
                    # run outright. Refuse the scope and keep going full — the
                    # selector's whole polarity is that confusion runs MORE,
                    # never less. Swallowing `--compact` as a base ref would
                    # also drop that flag silently.
                    log_warn "--diff-scope needs a base ref (e.g. --diff-scope origin/linux-next); running FULL"
                    DIFF_SCOPE_BASE=""
                    shift
                fi
                ;;
            --json)
                # JSON output (handled at end)
                shift
                ;;
            --verbose|-v)
                VERBOSE=1
                shift
                ;;
            -*)
                log_fail "Unknown option: $1"
                echo "Use: $0 [spec-name] --timeout N --phase <name> --list --json" >&2
                exit 3
                ;;
            *)
                if [[ -z "$FILTER_SPEC" ]]; then
                    FILTER_SPEC="$1"
                else
                    log_fail "Multiple specs not supported; got: $1"
                    exit 3
                fi
                shift
                ;;
        esac
    done
}

# ============================================================================
# VALIDATION
# ============================================================================

validate_environment() {
    local missing=0

    if [[ ! -f "$LITMUS_BINDINGS" ]]; then
        log_fail "Bindings file not found: $LITMUS_BINDINGS"
        missing=$((missing+1))
    fi

    if [[ ! -d "$LITMUS_TESTS_DIR" ]]; then
        log_fail "Tests directory not found: $LITMUS_TESTS_DIR"
        missing=$((missing+1))
    fi

    if [[ ! -f "$METHODOLOGY_LITMUS" ]]; then
        log_warn "Methodology file not found - non-critical: $METHODOLOGY_LITMUS"
    fi

    # Check for YAML parser
    if ! command -v yq &>/dev/null && ! command -v jq &>/dev/null; then
        log_warn "yq/jq not found; using fallback grep-based parsing - reduced functionality"
    fi

    return $missing
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    parse_args "$@"
    # ORDER 958-b36m. `--parse-only <file>...` asks THIS runner whether it can
    # extract the named files' steps, and answers without executing any of
    # them. Short-circuits before selection and before the reporting banner:
    # the caller is a gate wanting one verdict line per file, not a test run.
    #
    # Selection is deliberately bypassed. A gate checking a NEWLY BOUND file
    # must be able to reach it whatever its phase, size or spec — the whole
    # failure being closed is a file that no selection path reaches.
    if [[ $PARSE_ONLY -eq 1 ]]; then
        local parse_rc=0
        local parse_target
        if [[ ${#PARSE_ONLY_FILES[@]} -eq 0 ]]; then
            printf 'blocked:parse-only:no files named\n' >&2
            exit 2
        fi
        for parse_target in ${PARSE_ONLY_FILES[@]+"${PARSE_ONLY_FILES[@]}"}; do
            if [[ ! -f "$parse_target" ]]; then
                printf 'blocked:parse-only:missing:%s\n' "$parse_target" >&2
                parse_rc=1
                continue
            fi
            run_litmus_test_file "$parse_target" "parse-only" || parse_rc=1
        done
        exit "$parse_rc"
    fi


    if [[ -n "$SPEC_SHORTHAND" ]]; then
        if [[ -z "$FILTER_SPEC" ]]; then
            FILTER_SPEC="$SPEC_SHORTHAND"
        fi
        if [[ "$STRICT_MODE" != "1" || -z "$STRICT_SPEC_LIST" ]]; then
            STRICT_MODE=1
            [[ -z "$STRICT_SPEC_LIST" ]] && STRICT_SPEC_LIST="$SPEC_SHORTHAND"
        fi
    fi

    log_info "Tillandsias Litmus Test Runner"
    log_info "Environment: ${PROJECT_ROOT}"

    if ! validate_environment; then
        exit 3
    fi

    if [[ $LIST_ONLY -eq 1 ]]; then
        list_all_tests
        exit 0
    fi

    log_info "Timeout per test: ${TIMEOUT_SECONDS}s"
    log_info "Phase filter: ${FILTER_PHASE}"
    log_info "Size filter: ${SIZE_FILTER}  (use --size instant|quick|long|e2e|all for more)"
    [[ "$COMPACT" == "1" ]] && log_info "Output mode: compact"
    [[ "$STRICT_MODE" == "1" ]] && log_info "Strict mode: enabled"
    # Order 765-mza8. Clear any sentinel from a PREVIOUS run first: it must
    # describe this run or nothing. A stale one would make an honest full gate
    # refuse to stamp, which fails closed (safe) but would be a mystery to the
    # operator — and mysteries are how guards get switched off.
    local _dsdir
    _dsdir="$(git -C "$PROJECT_ROOT" rev-parse --absolute-git-dir 2>/dev/null || true)"
    [[ -n "$_dsdir" ]] && rm -f "$_dsdir/tillandsias-litmus-diff-scoped" 2>/dev/null
    # Resolved BEFORE any test runs so the banner states the selection regime
    # up front — a reader must never have to infer from the skip lines whether
    # this run was scoped.
    if [[ -n "$DIFF_SCOPE_BASE" ]]; then
        litmus_resolve_diff_scope "$DIFF_SCOPE_BASE"
    fi
    echo "" >&2


    # Determine which specs to test
    local specs_to_test
    if [[ -n "$FILTER_SPEC" ]]; then
        log_info "Running tests for spec: $FILTER_SPEC"
        specs_to_test="$(normalize_spec_list "$FILTER_SPEC")"
        if [[ "$STRICT_MODE" == "1" && -z "$STRICT_SPEC_LIST" ]]; then
            STRICT_SPEC_LIST="$FILTER_SPEC"
        fi
    else
        log_info "Running tests for all active specs"
        specs_to_test="$(normalize_spec_list "$(get_all_active_specs)")"
    fi

    if [[ -n "$IGNORE_SPEC_LIST" ]]; then
        local filtered_specs=""
        while IFS= read -r spec_id; do
            [[ -z "$spec_id" ]] && continue
            if ! spec_is_ignored "$spec_id"; then
                filtered_specs+="${spec_id}"$'\n'
            fi
        done <<<"$specs_to_test"
        specs_to_test="$(printf '%s' "$filtered_specs" | awk 'NF')"
    fi

    # Check if spec list is empty
    if [[ -z "$specs_to_test" ]]; then
        log_fail "No specs found in bindings. Check litmus-bindings.yaml."
        exit 1
    fi

    # Time the whole suite run as a telemetry side-channel (packet 682-emvg).
    # The trap fires on every exit past this point — normal completion AND the
    # early strict/empty-filter failure exits below — recording the real exit
    # code without altering it. Named `litmus-suite` so cycle-metrics' timing:
    # line folds it into litmus_ms_avg.
    local _suite_t0
    _suite_t0="$(timing_now_ms)"
    trap 'timing_emit litmus-suite "$FILTER_PHASE" "$_suite_t0" $?' EXIT

    # Execute tests for each spec
    while IFS= read -r spec_id; do
        [[ -z "$spec_id" ]] && continue
        run_tests_for_spec "$spec_id"
        local status=$?
        if [[ $status -ne 0 ]]; then
            print_summary
            exit "$status"
        fi
    done <<<"$specs_to_test"

    # Order 765-mza8 bookkeeping, in this order deliberately.
    #
    # A run that actually scoped drops a sentinel so whatever writes the gate
    # stamp cannot claim `scope full` for a tree whose tests did not all run
    # (audit F5). A run that did NOT scope — including every refusal path — is
    # a full quick-tier run and refreshes the 24h ratchet anchor. The two are
    # mutually exclusive by construction: only a full run may extend the window
    # that permits scoping.
    if [[ "$DIFF_SCOPE_ACTIVE" -eq 1 && "$DIFF_SCOPE_SKIPS" -gt 0 ]]; then
        litmus_mark_scoped_run "$DIFF_SCOPE_SKIPS"
    elif [[ "$DIFF_SCOPE_ACTIVE" -eq 0 && "$SIZE_FILTER" == "quick" && "$FILTER_PHASE" == "pre-build" && -z "$FILTER_SPEC" ]]; then
        litmus_record_full_anchor
    fi

    # @trace spec:spec-traceability
    # An explicit filter is a requested verification boundary. Treating a
    # typo, renamed spec, or litmus-name-shaped argument as PASS with zero
    # selected tests silently disables that boundary. Legitimately empty
    # phase/size buckets still have TESTS_RUN > 0 because their bound tests
    # are counted as skips, so this guard preserves those pass semantics.
    if [[ -n "$FILTER_SPEC" && $TESTS_RUN -eq 0 ]]; then
        log_fail "no litmus tests matched filter '$FILTER_SPEC'"
        # @trace spec:spec-traceability
        # A litmus:*/litmus-* filter is a TEST NAME, not a spec id. The runner
        # selects tests by spec binding, so a name-shaped filter always matches
        # zero tests. When the name resolves to a real litmus file, name its
        # owning spec so the user can run the intended suite. The failure and
        # its non-zero exit are unchanged: an unmatched explicit filter must
        # still fail (642 semantics).
        # Order 764-8m5j. A test id typed WITHOUT its litmus: prefix is the same
        # mistake and matched zero tests just as silently — the hint simply did
        # not cover it, because the prefix test above is what gated it. Observed
        # 2026-08-17: `run-litmus-test.sh fake-podman-direct-invocation-safety`
        # answered "no litmus tests matched filter" with no hint, and the spec
        # (litmus-framework) had to be found by grepping the corpus by hand.
        #
        # The packet's other option — ACCEPTING a test id as a filter and running
        # it — is deliberately not taken: order 300/642 requires an explicit
        # filter that matches zero tests to fail loud, and litmus:litmus-name-
        # filter-hint-shape pins that. Making the refusal more useful is additive;
        # making it succeed would delete a safety contract.
        local -a name_candidates=()
        if [[ "$FILTER_SPEC" == litmus:* || "$FILTER_SPEC" == litmus-* ]]; then
            name_candidates+=("$FILTER_SPEC")
        else
            name_candidates+=("litmus:${FILTER_SPEC}")
        fi

        local candidate name_file owner_spec resolved_file resolved_name
        resolved_file=""
        for candidate in "${name_candidates[@]}"; do
            while IFS= read -r name_file; do
                [[ -n "$name_file" ]] || continue
                # grep -F "name: x" also matches "name: x-longer", so confirm the
                # file's declared name is EXACTLY the candidate before hinting.
                # A hint naming the wrong spec is worse than none.
                resolved_name="$(grep -m1 -E '^name:[[:space:]]*' "$name_file" 2>/dev/null \
                    | sed -E 's/^name:[[:space:]]*//; s/[[:space:]]*$//')"
                if [[ "$resolved_name" == "$candidate" ]]; then
                    resolved_file="$name_file"
                    break
                fi
            done < <(grep -rlF "name: ${candidate}" "${LITMUS_TESTS_DIR}" 2>/dev/null)
            [[ -n "$resolved_file" ]] && break
        done

        if [[ -n "$resolved_file" ]]; then
            owner_spec="$(grep -m1 -F 'spec: ' "$resolved_file" 2>/dev/null | sed -E 's/^spec:[[:space:]]*//')"
            if [[ -n "$owner_spec" ]]; then
                log_warn "hint: '${FILTER_SPEC}' is a test name; run its spec: scripts/run-litmus-test.sh ${owner_spec}"
            fi
        fi
        exit 1
    fi

    # Print summary
    print_summary
    local exit_code=$?

    # Optional JSON output
    if [[ "$*" == *"--json"* ]]; then
        echo "" >&2
        print_json_summary
    fi

    exit $exit_code
}

# ============================================================================
# ENTRY POINT
# ============================================================================

main "$@"
