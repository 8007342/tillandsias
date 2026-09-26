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
# ORDER 1268-m2ir. EXPORTED so child processes resolve metrics logs against the
# checkout this runner KNOWS it is in, rather than guessing from their own path.
# A step shells out to cycle-metrics.sh --emit-timing, which resolves the timing
# log itself; without this it can decide "not in a checkout" for a tree the
# runner is standing in, and the records land in /tmp where the split guard then
# reds the next release gate.
export PROJECT_ROOT

# Build/test DURATION telemetry (packet 682-emvg). Best-effort side-channel that
# times the litmus suite; a timing failure must NEVER change the runner's exit.
# The `-f` test is what makes the "best-effort" real. bash 3.2 — the system
# shell on every macOS host — ABORTS a non-interactive shell when `.` cannot
# find its file, and `|| true` does not save it (bash 4.4+ does not, which is
# why this survived on Linux). So a runner copied somewhere without
# timing-log.sh beside it died on this line before parsing anything, and a
# timing side-channel changed the runner's exit after all. Verified:
# `bash -c 'set -eo pipefail; . /nonexistent 2>/dev/null || true; echo X'`
# prints nothing and exits 1 under 3.2.57.
if [[ -f "$(dirname "${BASH_SOURCE[0]}")/timing-log.sh" ]]; then
    . "$(dirname "${BASH_SOURCE[0]}")/timing-log.sh" 2>/dev/null || true
fi
command -v timing_emit >/dev/null 2>&1 || { timing_now_ms() { echo 0; }; timing_emit() { return 0; }; }
# ORDER 1252-znbn. Overridable alongside LITMUS_TESTS_DIR below, with the same
# unchanged default. The two are a PAIR — bindings name the tests, the directory
# holds them — so overriding one without the other gives a fixture half a seam
# and a discovery path that silently finds nothing. Both or neither.
readonly LITMUS_BINDINGS="${TILLANDSIAS_LITMUS_BINDINGS:-${PROJECT_ROOT}/openspec/litmus-bindings.yaml}"
# ORDER 1252-znbn. Overridable, defaulting to exactly the previous value, so a
# fixture can exercise ADJUDICATION against its own throwaway corpus instead of
# writing test files into the real one. Without this the structured `assert:`
# arms could only be tested by polluting openspec/litmus-tests, and a guard that
# cannot be tested without touching the tree it guards does not get tested.
# The default is unchanged, so every existing caller resolves identically.
readonly LITMUS_TESTS_DIR="${TILLANDSIAS_LITMUS_TESTS_DIR:-${PROJECT_ROOT}/openspec/litmus-tests}"
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
# PUBLISH THE REAL PODMAN TO STEP CHILDREN (release gate ci4, 2026-09-18).
# litmus-inference-deferred-model-pulls and litmus-inference-model-warm-timing
# bypass the shim below on purpose — they drive the real container lane — and
# read `${TILLANDSIAS_REAL_PODMAN:-/usr/bin/podman}`. This runner already
# resolves the real binary one line up and never exported it, so inside the
# tillandsias-builder toolbox (where ./build.sh --ci-full runs) the default
# fired and both steps died with "/usr/bin/podman: No such file or directory":
# in the toolbox podman is /usr/local/bin/podman and /usr/bin/podman is absent.
# Same shape as the vault SELinux probe fixed the same night — a host path
# carried into a namespace where it does not exist. An operator's explicit
# TILLANDSIAS_REAL_PODMAN still wins; this only seats the resolved path when
# nobody has.
if [[ -n "$REAL_PODMAN_BIN" ]]; then
    export TILLANDSIAS_REAL_PODMAN="${TILLANDSIAS_REAL_PODMAN:-$REAL_PODMAN_BIN}"
fi
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
#
# CARRIAGE RETURNS ARE STRIPPED, and that is not defensive tidying -- it is the
# fix for a defect that made this runner report success without running.
# jq.exe on Windows writes CRLF, so every value read through this tier arrived
# with a trailing carriage return. Reproduce in two lines: pipe a one-key JSON
# object through `jq -r` and dump the result with `od -c`; the value is followed
# by CR and LF, not LF alone.
#
# Measured on yolanda 2026-09-04. Test names became "litmus:<name>" plus a CR,
# the lookup asked for a file whose name ended in CR before ".yaml", the file
# was NOT FOUND, and the test was logged SKIP. Skips are EXCLUDED FROM COVERAGE,
# so the run then printed PASS 100% (1/1 executed) having skipped the tests it
# was invoked to run. A gate that answers PASS while executing almost nothing is
# worse than a gate that is down, because nobody goes looking for it.
#
# It is not only the names: phase, host_kind and size come through here too, so
# a comparison against "pre-build" was really a comparison against "pre-build"
# plus a CR, and the phase and size filters were silently wrong on Windows in
# the same invisible direction.
#
# THIS IS ONE SITE OF A CLASS. 26 scripts under scripts/ pipe `jq -r` into shell
# values and every one of them is exposed on a Windows host; filed separately
# rather than swept here, because a sweep I cannot verify per-site is how a real
# fix becomes a claim.
_yaml_jq() {
    [[ -n "$LITMUS_PLAN_BIN" ]] || return 1
    command -v jq &>/dev/null || return 1
    local out
    out="$("$LITMUS_PLAN_BIN" yaml-json "$1" 2>/dev/null | jq -r "$2" 2>/dev/null)" || return 1
    printf '%s\n' "${out//$'\r'/}"
}
export TILLANDSIAS_NO_SINGLETON=1
export LITMUS_PODMAN_CALLS_FILE="${LITMUS_PODMAN_CALLS_FILE:-$PROJECT_ROOT/target/litmus-podman/calls.log}"

# Default timeout in seconds (can be overridden via --timeout)
# Increased from 30s to 600s (10 min) to handle slow tray feature compilation
# @trace spec:spec-traceability
TIMEOUT_SECONDS=600
VERBOSE=0
LIST_ONLY=0

# ORDER 956-llei. CPU stall accounting for the kill-time adjudicator, read
# from THIS cgroup's pressure file so a step run inside a container is
# judged by the container's contention, not the host's (the /proc/loadavg
# it replaced is not namespaced: a forge step was stamped with the host's
# runqueue). Prints the `some` stall counter in microseconds, or nothing
# when the kernel/cgroup does not expose it — the caller must then say
# UNCLASSIFIED, never fall back to a number that measures something else.
# LITMUS_PSI_FILE overrides the path so the hermetic fixture can inject
# counters (scripts/test-litmus-kill-adjudicator.sh).
_lt_cpu_stall_us() {
    local f="${LITMUS_PSI_FILE:-}"
    if [ -z "$f" ]; then
        # This process's OWN cgroup first: its `some` counter is time OUR
        # runnable tasks waited for a CPU, whoever was hogging it. The cgroup
        # root — the container's root inside a cgroup namespace, the whole
        # host outside one — is the fallback when the own path is not
        # exposed (measured on macuahuitl 2026-09-02: /proc/self/cgroup
        # names a ptyxis scope; root `some total=` also counts every
        # unrelated process's stall).
        local own
        own="$(sed -n 's/^0::\(.*\)$/\1/p' /proc/self/cgroup 2>/dev/null | head -1)"
        if [ -n "$own" ] && [ "$own" != "/" ] && [ -r "/sys/fs/cgroup${own}/cpu.pressure" ]; then
            f="/sys/fs/cgroup${own}/cpu.pressure"
        else
            f="/sys/fs/cgroup/cpu.pressure"
        fi
    fi
    [ -r "$f" ] || return 0
    awk '$1 == "some" { for (i = 2; i <= NF; i++) if ($i ~ /^total=/) { sub(/^total=/, "", $i); print $i; exit } }' "$f" 2>/dev/null
}

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
# 956-llei: set by the step runner when a step is killed at its budget, read
# by the per-test record so a timeout's duration is stored as CENSORED (rc 124)
# rather than as a measurement — the budget is a lower bound, not the time.
LITMUS_LAST_TEST_TIMED_OUT=0
TESTS_FAILED=0
TESTS_SKIPPED=0
# ORDER 1309-fhxb — STEP-level verdicts. Added beside the test-level counters,
# never replacing them: every existing line keeps its format and position.
STEPS_SKIPPED=0
STEPS_ADVISORY=0
TESTS_ADVISORY=0
TESTS_VERDICT_SKIPPED=0
# ORDER 1187-iij8. A SECOND DIMENSION ON THE SAME REDS, never a fourth bucket.
#
# Every test counted here is ALSO counted in TESTS_FAILED, deliberately. A
# step killed at its budget has not passed, and 820-c8q8 settled that it still
# FAILS — the rc=124 site says so in as many words ("Reported, never used to
# change the verdict"). Making this an exemption would turn a noisy count into
# a fail-open gate, which is strictly worse than the noise it replaced.
#
# What it buys: a closure row reads the COUNT, and "7 FAIL" cannot distinguish
# seven broken assertions from seven steps that ran out of clock. The second
# sends a fixer to re-fix something that is not broken — this row's whole
# complaint, measured by esmeraldinha at the Git Bash locus 2026-09-14 and by
# yoga across four files on a fat host 2026-09-15.
TESTS_BUDGET_KILLED=0
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
            printf '  %b[FAIL]%b spec=%s test=%s\n' "${RED}" "${NC}" "$spec_name" "$test_name" >&2   # rc-exempt: spec/test-level reporter — no step exit in scope, the caller passes a message
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
        yq eval "$path" "$file" 2>/dev/null | tr -d "
" || echo ""
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
# ORDER 1309-fhxb. Is this step's output a TERMINAL NON-FAILURE VERDICT — a named
# skip or a declared advisory — rather than a pass or a defect?
#
# THE DEFECT. A step that emitted `skip:no-cargo` on a host without cargo, and one
# that emitted `advisory:bash-hazards:pgrep-f-literal:pipelines=4:files=3` from a
# lint that calls itself advisory, were both scored FAIL — each having exited
# ZERO and asserted nothing. MEASURED: 144 corpus steps invoke a script that can
# emit a named skip while declaring an expectation that does not admit one (of
# 2580 steps, 104 skip-capable scripts, 20 expectations that admit the word). The
# exposure concentrates on floor and platform-minority hosts, because the absent
# precondition is usually the HOST — which makes it worst exactly where a red is
# least likely to be believed.
#
# WIDENING WHAT COUNTS AS A NON-FAILURE MUST NOT WIDEN WHAT COUNTS AS A PASS, and
# that is this function's whole burden. A skip is a question NOT ASKED. It is
# never a pass, never a failure, and it must never become a way to make a red
# disappear by printing six characters.
#
# SO A FAILURE VERDICT ANYWHERE IN THE OUTPUT WINS, whatever follows it: the
# fleet's own failure grammar (violation:/refused:/blocked:/FAIL) is checked
# FIRST and short-circuits. A step that genuinely failed and then printed a skip
# line — by accident or by fabrication — stays red. scripts/test-litmus-terminal-
# verdict.sh plants exactly that and asserts it.
#
# AND THE LINE MUST BE THE STEP'S OWN VERDICT, not a mention in passing: only the
# LAST non-empty line is consulted, which is where a script states its outcome.
step_terminal_verdict() { # <output> -> prints skip|advisory|"" on stdout
    local out="$1" last=""

    # A failure verdict anywhere outranks everything. Anchored at line start so a
    # script DESCRIBING the grammar (this fleet writes such scripts) is not read
    # as emitting it.
    if grep -qE '^(violation|refused|blocked):' <<<"$out" || grep -qE '^FAIL' <<<"$out"; then
        return 0
    fi

    last="$(grep -vE '^[[:space:]]*$' <<<"$out" | tail -n 1)"
    case "$last" in
        skip:[a-z0-9]*)     printf 'skip' ;;
        advisory:[a-z0-9]*) printf 'advisory' ;;
    esac
    return 0
}

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

# ORDER 1252-znbn. STRUCTURED ADJUDICATION — the replacement for
# behavior_matches_output's natural-language `case` arms.
#
# WHY. behavior_matches_output WAS a natural-language interpreter written in
# bash case arms. One arm meant "grep the first integer out of the output and
# require it to be at least two"; another meant "ignore the output entirely and
# honour the exit code"; another meant "grep the output for the word cargo".
# Which arm fired depended on which English words the sentence happened to
# contain, so REWORDING A SENTENCE CHANGED THE RULE THAT DECIDED THE VERDICT,
# with no diff anywhere saying the test now checked something else.
#
# Those arms are now DELETED (not bypassed) and every step that depended on one
# declares its rule below. The arms are deliberately not quoted verbatim
# anywhere in this file: the row closes on a grep for them returning nothing,
# and a comment reciting them would answer that grep forever.
#
# The fields here name the OUTPUT they check instead of describing it in prose:
#   assert_exit: <n>                exact exit status
#   assert_output_contains: "..."   literal substring, case-sensitive
#   assert_output_matches: "..."    ERE regex
# Declaring ANY of them adjudicates the step by those fields ONLY — the
# expected_behavior sentence beside them becomes documentation and cannot
# change the verdict, which is the whole point of the row.
#
# assert_output_matches EXISTS BECAUSE OF 868-p8xi. An expectation written as
# an `(a|b)` alternation was searched for VERBATIM by the fallback
# `grep -Fqi`, so it could never match and litmus:sidecar-arch-derivation
# failed while printing one of its own listed alternatives. A regex field is
# matched AS a regex.
#
# WHAT THIS CANNOT DO, AND WHY IT IS NOT AN OVERSIGHT. There is no
# assert_stdout_* / assert_stderr_* pair, because the runner redirects every
# step with `>"$step_capture" 2>&1` — the two streams are MERGED before
# adjudication can see them, so naming which stream matched is not information
# this runner still has. Separating them is order 1252-fg9e's executor; when a
# step's fds arrive separately these fields widen rather than change shape.
# A field absent by CONSTRAINT reads identically to one nobody thought of
# unless the code says which, so this paragraph is the difference.
#
# A TIMEOUT IS NOT AN ASSERTION FAILURE. timeout(1) reserves 124, and the
# runner already branches on it — but nothing in this tree is responsible for
# keeping that true, so it is asserted explicitly here rather than relied on.
# A step that times out reports that it timed out; it does not report that its
# output failed to match, which would send a reader to the wrong question.
structured_assert_declared() { # <exit> <contains> <matches>
    [[ -n "${1}${2}${3}" ]]
}

structured_assert_matches() { # <output> <exit_code> <a_exit> <a_contains> <a_matches> <a_nonempty>
    local output="$1" exit_code="$2" a_exit="$3" a_contains="$4" a_matches="$5" a_nonempty="${6:-}"

    if [[ "$exit_code" -eq 124 && "$a_exit" != "124" ]]; then
        printf '%s\n' "         assert: step TIMED OUT (rc=124) — not an assertion miss; raise timeout_ms or fix the step" >&2
        return 1
    fi
    if [[ -n "$a_exit" && "$exit_code" -ne "$a_exit" ]]; then
        printf '%s\n' "         assert_exit: expected ${a_exit}, got ${exit_code}" >&2
        return 1
    fi
    if [[ -n "$a_contains" ]] && ! grep -Fq -- "$a_contains" <<<"$output"; then
        printf '%s\n' "         assert_output_contains: literal not found: ${a_contains}" >&2
        return 1
    fi
    if [[ -n "$a_matches" ]] && ! grep -Eq -- "$a_matches" <<<"$output"; then
        printf '%s\n' "         assert_output_matches: regex did not match: ${a_matches}" >&2
        return 1
    fi
    # ORDER 1252-znbn. An EXPLICIT non-emptiness field. `assert_output_matches:
    # "."` expresses the same thing today and is why this exists: a reader
    # cannot tell a lone dot from a typo, and this row's whole point is that
    # what a step checks must be legible IN the step. It is the honest
    # translation for the interpreter arm that requires a specific artefact be
    # printed — where silence is the failure — as distinct from the arm that
    # honours the exit code.
    if [[ -n "$a_nonempty" && -z "${output//[[:space:]]/}" ]]; then
        printf '%s\n' "         assert_output_nonempty: the step printed nothing (silence is the failure for this step)" >&2
        return 1
    fi
    return 0
}

# ORDER 1293-wka4. DOES THIS STEP'S TOP-LEVEL PIPELINE END IN A CONSUMER THAT
# SWALLOWS ITS PRODUCER'S STATUS? Returns 0 when it does.
#
# WHY SHAPE-GATED AND NOT A BLANKET. `set -o pipefail` for every step would
# change the verdict of steps whose pipeline ends in the ASSERTION itself.
# Measured on this corpus: 25 steps declaring assert_exit have a top-level pipe,
# but only 3 end in a status-swallowing consumer. The other 22 end in `grep -q`,
# where grep IS the adjudicator — and several are negated (`! producer | grep`),
# where pipefail INVERTS the verdict: a failing producer currently makes the
# pipeline 0 and the negation 1 (fail), while under pipefail it becomes non-zero
# and the negation 0 (pass). A blanket would silently flip those.
#
# THE LIST IS THE CLAIM. A consumer here is one that reports its OWN success
# regardless of what fed it. grep is deliberately ABSENT: a step ending in grep
# is asserting on the match, which is a real verdict.
step_pipeline_swallows_status() {
    local cmd="$1"

    # Remove $(...) substitutions — a pipe inside one is not the adjudicated
    # pipeline. Repeat until stable so nested substitutions collapse too.
    local prev=""
    while [[ "$cmd" != "$prev" ]]; do
        prev="$cmd"
        cmd="$(printf '%s' "$cmd" | sed 's/\$([^()]*)//g')"
    done

    # `||` is not a pipeline.
    cmd="${cmd//||/ }"
    [[ "$cmd" == *"|"* ]] || return 1

    local tail_seg="${cmd##*|}"
    # First bare word of the last segment, minus quotes and a leading path.
    tail_seg="${tail_seg#"${tail_seg%%[![:space:]]*}"}"
    tail_seg="${tail_seg//\'/}"
    tail_seg="${tail_seg//\"/}"
    local consumer="${tail_seg%%[[:space:]]*}"
    consumer="${consumer##*/}"

    case "$consumer" in
        head|tail|tee|wc|cat|sort|uniq|tr|awk|sed|jq|column|fold|nl)
            return 0
            ;;
    esac
    return 1
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

    # ORDER 1252-znbn. The natural-language case arms that used to sit here are
    # DELETED, not bypassed — see the note above structured_assert_matches for
    # what they did and why it was wrong. Every step that depended on one now
    # declares assert_exit / assert_output_contains / assert_output_matches /
    # assert_output_nonempty, which structured_assert_matches adjudicates
    # BEFORE this function is reached. What remains is the honest fallback the
    # interpreter always ended in: case-insensitive fixed-string containment.

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
        # ORDER 1018-5f5a: the rc travels with the verdict. Without it a reader
        # sees [FAIL] and whatever the check chose to print, and must SUPPLY a
        # mechanism from memory — which is exactly how a step that returned 1
        # (no match) was reported fleet-wide as a SIGPIPE 141 on 2026-09-04 and
        # cost three hosts an afternoon.
        printf ' %b[FAIL]%b rc=%s\n' "${RED}" "${NC}" "$status" >&2
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
    # ORDER 1252-znbn. Structured assertions. Declared here and reset at EVERY
    # site that resets the other step fields. A field reset in three of four
    # places leaks into the next step, which is the same defect class as the
    # item-merge this parser was just fixed for.
    local current_step_assert_exit=""
    local current_step_assert_contains=""
    local current_step_assert_matches=""
    local current_step_assert_nonempty=""
    local -a step_names=()
    local -a step_commands=()
    local -a step_timeouts=()
    local -a step_expecteds=()
    local -a step_success_patterns=()
    local -a step_failure_patterns=()
    # ORDER 1252-znbn — parallel arrays for the structured assertion fields.
    local -a step_assert_exits=()
    local -a step_assert_contains_all=()
    local -a step_assert_matches_all=()
    local -a step_assert_nonempty_all=()
    local -a unparsed_step_names=()
    # ORDER 1252-znbn. critical_path items opened by a key other than `step:`.
    local -a malformed_items=()
    # ORDER 1274-cbk7. Keys seen in the CURRENT critical_path item, so a key
    # repeated inside one step can be named. A YAML loader rejects the whole
    # document for this; the line-based parser here silently takes the last
    # occurrence, so the file was `ok:litmus-parseable` and unloadable at once.
    local -a duplicate_keys=()
    local -a step_seen_keys=()
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
        step_assert_exits+=("$current_step_assert_exit")
        step_assert_contains_all+=("$current_step_assert_contains")
        step_assert_matches_all+=("$current_step_assert_matches")
        step_assert_nonempty_all+=("$current_step_assert_nonempty")
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
            current_step_assert_exit=""
            current_step_assert_contains=""
            current_step_assert_matches=""
            current_step_assert_nonempty=""
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
            current_step_assert_exit=""
            current_step_assert_contains=""
            current_step_assert_matches=""
            current_step_assert_nonempty=""
            in_critical_path=0
            in_gating_points=0
        fi

        if [[ $in_critical_path -eq 1 ]]; then
            # ORDER 1274-cbk7. A DUPLICATED MAPPING KEY inside one step. This
            # is deliberately independent of the value branches below: it keys
            # on the LINE, so it also catches a repeated key this parser does
            # not otherwise read. Matched at 4+ spaces so the `- step:` opener
            # (2 spaces + dash) and top-level keys cannot reach it, and `#`
            # comments are skipped.
            #
            # SCOPE, STATED BECAUSE THE GAP IS REAL: this sees duplicates
            # WITHIN one critical_path item only. A duplicated TOP-LEVEL key
            # still passes --parse-only and still reds the YAML gate. Covering
            # that needs care around folded scalars (`description: >`), whose
            # continuation lines can look like keys, and a false red here is
            # worse than the false green being closed (1274-cbk7 criterion 2).
            if [[ "$line" =~ ^[[:space:]]{4,}([a-zA-Z_][a-zA-Z0-9_]*): ]]; then
                _dupkey="${BASH_REMATCH[1]}"
                for _seen in ${step_seen_keys[@]+"${step_seen_keys[@]}"}; do
                    if [[ "$_seen" == "$_dupkey" ]]; then
                        duplicate_keys+=("${current_step_name}|${_dupkey}")
                        break
                    fi
                done
                step_seen_keys+=("$_dupkey")
            fi

            if [[ "$line" =~ ^[[:space:]]*-[[:space:]]step:\ \"(.+)\" ]]; then
                append_step
                current_step_name="${BASH_REMATCH[1]}"
                step_seen_keys=()   # ORDER 1274-cbk7
                current_step_command=""
                current_step_timeout=30000
                current_step_expected=""
                current_step_success_pattern=""
                current_step_failure_pattern=""
                current_step_assert_exit=""
                current_step_assert_contains=""
                current_step_assert_matches=""
                current_step_assert_nonempty=""
            elif [[ "$line" =~ ^[[:space:]]*-[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*): ]]; then
                # ORDER 1252-znbn. A critical_path ITEM may only be opened by
                # `- step: "..."`. An item opened by ANY other key — `- name:`
                # is the measured case — does not match the branch above, falls
                # through this chain, and its `command:`/`timeout_ms:`/... keys
                # OVERWRITE the step already in progress. The item MERGES
                # BACKWARDS into its predecessor, later keys win, and the file
                # yields one unlabelled step that can never pass.
                #
                # NOTHING CAUGHT THIS BEFORE. The YAML is well-formed, so
                # ./build.sh --check's metadata validator passes the file, and
                # the runner reported a step count that silently omitted the
                # merged item. A lost step and a step that was never written
                # produced identical output.
                #
                # `- step:` with an UNQUOTED value lands here too, by the same
                # fall-through and with the same silence, so it is refused here
                # rather than being allowed to merge.
                #
                # SAFE BY MEASUREMENT, not by assumption: across the 435 files
                # in openspec/litmus-tests, all 2514 critical_path items are
                # opened by `- step:` and all 2514 of their names are
                # double-quoted, so this refusal cannot redden the corpus.
                malformed_items+=("${BASH_REMATCH[1]}|${line}")
                # ORDER 1274-cbk7. A NEW LIST ITEM STARTS A NEW MAPPING IN YAML,
                # whatever key opens it — so the duplicate-key seen-set resets
                # here too, not only on `- step:`. Without this reset the
                # duplicate detector fires on the very file the arm above
                # describes: a `- name:` item MERGES into the previous step in
                # this parser, so its command:/timeout_ms:/expected_behavior:
                # look like repeats of the predecessor's keys — while a YAML
                # loader, which sees two separate items, accepts the file. That
                # is a FALSE duplicate report on valid YAML, and the 1252-znbn
                # item-opener fixture caught it.
                step_seen_keys=()
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
            # ORDER 1252-znbn — STRUCTURED ASSERTIONS. These are anchored at
            # the start of the line, unlike the timeout_ms/expected_behavior
            # branches above, so a value that merely CONTAINS the key name
            # cannot be mistaken for the key.
            elif [[ "$line" =~ ^[[:space:]]*assert_exit:[[:space:]]+([0-9]+) ]]; then
                current_step_assert_exit="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^[[:space:]]*assert_output_contains:[[:space:]]+\"(.+)\" ]]; then
                current_step_assert_contains="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^[[:space:]]*assert_output_matches:[[:space:]]+\"(.+)\" ]]; then
                current_step_assert_matches="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^[[:space:]]*assert_output_nonempty:[[:space:]]+(true|yes) ]]; then
                current_step_assert_nonempty="1"
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
    # ORDER 1252-znbn. Reported BEFORE the checks below: a merged item makes
    # the step count itself wrong, so every later verdict is over the wrong set.
    # ORDER 1274-cbk7. Reported FIRST: a duplicated key means a YAML loader
    # rejects this document outright, so any step count taken from it describes
    # a file that cannot be loaded. The incident this closes is an author who
    # ran --parse-only over the corpus, read 423 ok, and hit
    # blocked:yaml-load-failed in the gate fifteen minutes later.
    if [[ "${#duplicate_keys[@]}" -gt 0 ]]; then
        printf '  %b[PARSE ERROR]%b %s: duplicated mapping key in a critical_path item\n' "${RED}" "${NC}" "$test_file" >&2
        local dk dkstep dkkey
        for dk in "${duplicate_keys[@]}"; do
            dkstep="${dk%%|*}"
            dkkey="${dk#*|}"
            printf '%s\n' "         step '${dkstep}': key '${dkkey}' appears more than once" >&2
        done
        printf '%s\n' "         a YAML loader REJECTS this file; this parser would silently take the last occurrence" >&2
        printf '%s\n' "         verify with: scripts/check-litmus-yaml-parses.sh" >&2
        return 1
    fi

    if [[ "${#malformed_items[@]}" -gt 0 ]]; then
        printf '  %b[PARSE ERROR]%b %s: critical_path item not opened by `- step: "..."`\n' "${RED}" "${NC}" "$test_file" >&2
        local mi mkey mline
        for mi in "${malformed_items[@]}"; do
            mkey="${mi%%|*}"
            mline="$(printf '%s' "${mi#*|}" | sed 's/^[[:space:]]*//')"
            if [[ "$mkey" == "step" ]]; then
                printf '%s\n' "         ${mline}" >&2
                printf '%s\n' "         a step name must be a double-quoted scalar: - step: \"...\"" >&2
            else
                printf '%s\n' "         ${mline}" >&2
                printf '%s\n' "         only '- step:' opens an item; '- ${mkey}:' MERGES into the previous step and overwrites its keys" >&2
            fi
        done
        return 1
    fi

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

    # ORDER 1309-fhxb. A TEST's verdict is DERIVED from its steps, and the case
    # that forces this is the one a step-only count cannot see: a test whose every
    # executed step is a SKIP asked no question, and counting it PASSED is
    # 1273-4mak's vacuous green one level up. 1049-s35z's comment preserves that
    # exact shape — a suite reporting `1/1 executed, 100%, PASS` while two born-red
    # tests sat unobserved.
    local _t_pass=0 _t_skip=0 _t_advisory=0
    for idx in "${!step_commands[@]}"; do
        local step_name="${step_names[$idx]}"
        local step_command="${step_commands[$idx]}"
        local step_timeout_ms="${step_timeouts[$idx]}"
        local step_expected="${step_expecteds[$idx]}"
        local step_success_pattern="${step_success_patterns[$idx]}"
        local step_failure_pattern="${step_failure_patterns[$idx]}"
        local step_assert_exit="${step_assert_exits[$idx]}"
        local step_assert_contains="${step_assert_contains_all[$idx]}"
        local step_assert_matches="${step_assert_matches_all[$idx]}"
        local step_assert_nonempty="${step_assert_nonempty_all[$idx]}"
        # ORDER 1252-znbn. Non-empty when the step declares ANY structured
        # assertion, which takes precedence over every legacy arm below.
        local step_structured="${step_assert_exit}${step_assert_contains}${step_assert_matches}${step_assert_nonempty}"
        local step_output=""
        local exit_code=0

        step_index=$((step_index + 1))
        _LT_CUR_STEP=$step_index  # 1242-4x53: the step a failed test died on
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
        # 956-llei: stall counter + wall clock at launch, diffed at kill time.
        local _lt_psi0 _lt_t0
        _lt_psi0="$(_lt_cpu_stall_us)"; _lt_t0="$(date +%s)"
        # 956-llei: stdin is /dev/null, ALWAYS. The per-spec test loop feeds
        # its bound test names through a here-string on stdin, and a step that
        # reads stdin (a fixture with `read`, `cat`, an interactive-capable
        # tool) drained the rest of its spec's list: measured 2026-09-02, the
        # instant sweep executed 1 of the 29 tests bound to ci-release, and
        # reported PASS. Two born-red tests sat unobserved in that gap.
        # ORDER 1293-wka4. THE SPAWNED SHELL DOES NOT INHERIT pipefail FROM THIS
        # RUNNER. run-litmus-test.sh runs under `set -uo pipefail`, but that is a
        # property of THIS shell; the `bash -c` below starts clean, so
        # `producer | head` returned 0 when the producer exited non-zero and
        # assert_exit adjudicated head's status instead. Reproduction from the
        # row, which returned 0 before this line existed:
        #   bash -c 'sh -c "echo out; exit 7" 2>&1 | head -20'; echo $?
        #
        # APPLIED ONLY WHERE A STATUS-SWALLOWING CONSUMER WOULD OTHERWISE
        # ADJUDICATE — see step_pipeline_swallows_status for why a blanket is
        # wrong and which 22 steps it would invert.
        # NARROWED TO STEPS WHOSE VERDICT THE EXIT STATUS ACTUALLY DECIDES.
        # The shape test alone matches 206 of 2553 corpus steps, but most of
        # those are adjudicated by a pattern or a literal and never consult the
        # status — turning pipefail on for them changes nothing they read while
        # widening the blast radius for no gain. The status decides only when
        # the step declares assert_exit, or when it declares NO expectation at
        # all and falls to the strict-exit arm below. Anything else keeps the
        # shell it has always had.
        local step_shell_prelude=""
        if [[ -n "$step_assert_exit" \
              || ( -z "$step_structured" && -z "$step_success_pattern" && -z "$step_expected" ) ]] \
           && step_pipeline_swallows_status "${step_command}"; then
            step_shell_prelude="set -o pipefail; "
        fi
        LITMUS_STDLIB="${LITMUS_STDLIB}" timeout --kill-after=10s "${timeout_sec}s" bash -c 'source "$LITMUS_STDLIB"; '"${step_shell_prelude}${step_command}" </dev/null >"$step_capture" 2>&1 || exit_code=$?
        step_output="$(cat "$step_capture")"
        rm -f "$step_capture"
        combined_output+=$'\n'"[${step_index}:${step_name}]${step_output}"

        if [[ $exit_code -eq 124 ]]; then
            printf ' %b[TIMEOUT]%b\n' "${RED}" "${NC}" >&2
            LITMUS_LAST_TEST_TIMED_OUT=1
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
            # its budget, by construction. What can: how long this step's
            # cgroup had runnable tasks WAITING for a CPU while the step ran
            # (PSI `some` stall, diffed launch→kill). ORDER 956-llei retired
            # the load1-vs-ncpus rule that stood here: /proc/loadavg is not
            # namespaced (a forge step was judged by the HOST's runqueue);
            # load1 > ncpus is utilization, not starvation (a fully busy box
            # with no queueing stamped SATURATED); and its trailing 1-minute
            # window mostly measured the PREVIOUS step. The counter diff is
            # this step's own window, in this step's own cgroup. Reported,
            # never used to change the verdict: the step still FAILS, because
            # a step that cannot finish inside its budget has not passed.
            # Threshold: a quarter of the wall time spent queued means the
            # step saw at most ~75% of a CPU — tunable, LITMUS_STALL_CONTENDED_PCT.
            local _lt_psi1 _lt_elapsed _lt_stall_us _lt_stall_pct
            _lt_psi1="$(_lt_cpu_stall_us)"
            _lt_elapsed=$(( $(date +%s) - ${_lt_t0:-0} ))
            [ "$_lt_elapsed" -ge 1 ] 2>/dev/null || _lt_elapsed=1
            if [ -z "${_lt_psi0:-}" ] || [ -z "${_lt_psi1:-}" ] || [ "$_lt_psi1" -lt "$_lt_psi0" ] 2>/dev/null; then
                log_warn "  cpu.pressure unavailable in this cgroup — cause UNCLASSIFIED (slow step vs starved step); no fallback instrument, because none measures this step's contention"
            else
                _lt_stall_us=$(( _lt_psi1 - _lt_psi0 ))
                # percent of the step's wall time that SOME task in this cgroup
                # waited for a CPU; integer maths, bash 3.2 has no floats.
                _lt_stall_pct=$(( _lt_stall_us / (_lt_elapsed * 10000) ))
                if [ "$_lt_stall_pct" -ge "${LITMUS_STALL_CONTENDED_PCT:-25}" ]; then
                    log_warn "  cpu.pressure some-stall ${_lt_stall_us}us over ${_lt_elapsed}s (${_lt_stall_pct}%) in this cgroup — step CONTENDED at kill time; a step that is fast when idle can be starved here, so re-run before treating this as a regression"
                else
                    # ORDER 1358-9wzz. REPORT WHAT WAS MEASURED, DO NOT CONCLUDE
                    # WHAT WAS NOT. This branch used to say "step NOT contended
                    # at kill time; genuinely too slow for its Ns budget", and
                    # both halves were false about the step that produced them:
                    # litmus:proxy-crash-supervision-shape step 3 runs bare in 5s
                    # on macuahuitl and 4.98s on macbookair, and passes through
                    # the runner alone at 6.5s — against this same 60s budget. It
                    # reds only inside the FULL pre-build suite, so the cause is
                    # INTERFERENCE, which is exactly what the sentence declared
                    # absent.
                    #
                    # cpu.pressure `some` measures time runnable tasks waited FOR
                    # A CPU. A low reading excludes CPU STARVATION and nothing
                    # else — not I/O, not locks, not process-table pressure, not
                    # pattern-kill effects from concurrent fixtures.
                    #
                    # THIS MODULE'S OWN CONTRACT ALREADY SAID SO. The comment
                    # above _lt_cpu_stall_us: the caller "must then say
                    # UNCLASSIFIED, never fall back to a number that measures
                    # something else". Concluding "not contended" from a CPU
                    # counter is that fallback, one branch over.
                    #
                    # The UNAVAILABLE path below is the model: it has no data and
                    # says so honestly. The path with PARTIAL data must not
                    # produce more confidence than the path with none.
                    log_warn "  cpu.pressure some-stall ${_lt_stall_us}us over ${_lt_elapsed}s (${_lt_stall_pct}%) in this cgroup — CPU starvation EXCLUDED; cause otherwise UNCLASSIFIED, because this counter measures only waiting for a CPU and does not see I/O, locks, process-table pressure, or pattern-kill effects from concurrent steps. Re-run this step ALONE before treating it as too slow: a step that passes alone and reds in the suite is interference, not a budget."
                fi
            fi
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
        # ORDER 1309-fhxb. A named skip or a declared advisory is a TERMINAL
        # NON-FAILURE verdict and is decided BEFORE every arm below, because each
        # of those arms asks "did the output match what a PASS looks like" and a
        # skip is not a failed pass — it is a question not asked.
        #
        # EXCEPT where the step declared assert_exit and the status disagrees:
        # then the step asserted something and it was false, and no line the
        # script printed afterwards may overrule that. This is the ruling's
        # "a non-zero exit where the step declares assert_exit 0 still FAILS".
        step_verdict="$(step_terminal_verdict "$step_output")"
        if [[ -n "$step_verdict" && -n "$step_assert_exit" && "$exit_code" != "$step_assert_exit" ]]; then
            step_verdict=""
        fi
        if [[ -n "$step_verdict" ]]; then
            if [[ "$step_verdict" == "skip" ]]; then
                STEPS_SKIPPED=$((STEPS_SKIPPED+1)); _t_skip=$((_t_skip+1))
                printf ' %b[SKIP]%b %s\n' "${YELLOW}" "${NC}" "$(grep -vE '^[[:space:]]*$' <<<"$step_output" | tail -n 1)" >&2
            else
                STEPS_ADVISORY=$((STEPS_ADVISORY+1)); _t_advisory=$((_t_advisory+1))
                printf ' %b[ADVISORY]%b %s\n' "${YELLOW}" "${NC}" "$(grep -vE '^[[:space:]]*$' <<<"$step_output" | tail -n 1)" >&2
            fi
            continue
        fi

        if [[ -z "$step_structured" && $exit_code -ne 0 && -z "$step_success_pattern" && -z "$step_expected" ]]; then
            if [[ "${TILLANDSIAS_LITMUS_STRICT_EXIT:-1}" != "0" ]]; then
                # ORDER 1018-5f5a. This arm already NAMED the number on its
                # detail line, and that was not enough: a reader scanning for a
                # verdict, or a tool grepping one, reads the [FAIL] line. Making
                # the grammar uniform — every [FAIL] carries rc= — is what lets
                # "no rc on the line" mean "the runner did not know", instead of
                # "it is somewhere below, on some arms".
                printf ' %b[FAIL]%b rc=%s\n' "${RED}" "${NC}" "$exit_code" >&2
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
        if [[ -n "$step_structured" ]]; then
            if ! structured_assert_matches "$step_output" "$exit_code" \
                    "$step_assert_exit" "$step_assert_contains" "$step_assert_matches" \
                    "$step_assert_nonempty"; then
                printf ' %b[FAIL]%b rc=%s\n' "${RED}" "${NC}" "$exit_code" >&2
                printf '%s\n' "         output=${step_output}" >&2
                return 1
            fi
        elif [[ -n "$step_success_pattern" ]]; then
            if ! check_signal "$step_output" "$step_success_pattern" "$step_failure_pattern"; then
                # ORDER 1018-5f5a. A pattern miss and a CRASH look identical
                # here without the rc: both print [FAIL] and whatever the step
                # emitted. rc=1 says "ran, did not match"; rc=141 says "died of
                # SIGPIPE mid-write"; rc=124 says "the timeout killed it". Those
                # need three different responses, and the number is the only
                # thing that separates them — the step's own output cannot, and
                # on 2026-09-04 a step that piped through `tail -1` discarded
                # the very lines a reader needed.
                printf ' %b[FAIL]%b rc=%s\n' "${RED}" "${NC}" "$exit_code" >&2
                printf '%s\n' "         success_pattern=${step_success_pattern}" >&2
                [[ -n "$step_failure_pattern" ]] && printf '%s\n' "         failure_pattern=${step_failure_pattern}" >&2
                printf '%s\n' "         output=${step_output}" >&2
                return 1
            fi
        elif ! behavior_matches_output "$step_output" "$step_expected" "$exit_code"; then
            # ORDER 1018-5f5a: same reason as the success_pattern arm above.
            # behavior_matches_output already CONSUMES $exit_code to decide, so
            # printing it costs nothing and closes the gap between what the
            # runner knew and what it told the reader.
            printf ' %b[FAIL]%b rc=%s\n' "${RED}" "${NC}" "$exit_code" >&2
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
        _t_pass=$((_t_pass+1))
        printf ' %b[OK]%b\n' "${GREEN}" "${NC}" >&2
    done

    for failure in "${failure_criteria[@]}"; do
        if grep -qE "$failure" <<<"$combined_output"; then
            printf '  %b[FAIL]%b gating_points.failure matched: %s\n' "${RED}" "${NC}" "$failure" >&2   # rc-exempt: gating_points.failure regex matched the COMBINED output, not a step exit
            return 1
        fi
    done

    if [[ "${#success_criteria[@]}" -gt 0 ]]; then
        for success in "${success_criteria[@]}"; do
            if grep -qE "$success" <<<"$combined_output"; then
                return 0
            fi
        done
        printf '  %b[FAIL]%b no gating_points.success criterion matched combined output\n' "${RED}" "${NC}" >&2   # rc-exempt: gating_points.success — no criterion matched combined output, not a step exit
        local first_success="${success_criteria[0]}"
        printf '         tried: %s\n' "${success_criteria[*]}" >&2
        return 1
    fi

    # ORDER 1309-fhxb — THE TEST'S VERDICT, DERIVED FROM ITS STEPS.
    #   any failing step                      -> FAIL (returned above, 1)
    #   no passing step + >=1 skipped step    -> SKIPPED (2): the test asked no
    #                                            question, so it leaves the rate's
    #                                            denominator entirely. Counting it
    #                                            PASSED is the vacuous green
    #                                            1049-s35z's comment preserves —
    #                                            `1/1 executed, 100%, PASS` while
    #                                            two born-red tests sat unobserved.
    #   >=1 advisory step, no failing step    -> ADVISORY (3): a property HELD,
    #                                            with a note. Counts with passed.
    #   otherwise                             -> PASSED (0)
    # A test with SOME passing and SOME skipped steps is PASSED: a property held,
    # and a question beside it was not asked. The `Step Verdicts:` line is where a
    # reader sees which — that is why it is printed even when every test passes.
    if [[ "$_t_pass" -eq 0 && "$_t_skip" -gt 0 ]]; then
        return 2
    fi
    if [[ "$_t_advisory" -gt 0 ]]; then
        return 3
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

        # A BOUND NAME WITH NO FILE IS A CORPUS-INTEGRITY ERROR, NOT A SKIP
        # (order 1049-s35z). It used to be logged SKIP, and skips are EXCLUDED
        # FROM COVERAGE, so a run that could not find the tests it was invoked
        # to run still printed PASS. Measured on yolanda 2026-09-04, before the
        # CR fix that caused it: two of three bound tests unfindable, and the
        # verdict was
        #     Total: 3 (executed: 1, skipped: 2)
        #     Pass Rate: 100% (1/1 executed)
        #     Status: [PASS]
        #
        # The CR was one cause; this is the MECHANISM that turned it into a
        # green, and it would have turned the next cause into one too. A gate
        # that answers PASS while executing a third of its corpus is worse than
        # a gate that is down, because nobody goes looking for it.
        #
        # SAFE TO FAIL CLOSED, measured rather than assumed: all 476 names bound
        # in litmus-bindings.yaml resolve to a file on disk today, so this
        # refuses nothing that currently exists. A test file is tracked in the
        # repo, so absence means the binding and the corpus disagree — which is
        # exactly what a human needs told, on any platform.
        if [[ ! -f "$test_file" ]]; then
            log_test_result "$spec_id" "$test_name" "FAIL" "Test file not found (bound in litmus-bindings.yaml; corpus and bindings disagree)"
            printf '@trace spec:%s\n' "$spec_id" >&2
            if should_fail_fast_for_spec "$spec_id"; then
                return 21
            fi
            spec_failed=1
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
        # 956-llei: a test whose phase is `retired` runs ONLY when that phase is
        # asked for. The default phase filter is "all", and --diff-scope fails
        # CLOSED into exactly that default, so an escalated scoped run executed
        # every retired fixture in the corpus (12 on 2026-09-01) — none of which
        # anyone had asked for. Retired means kept for the record, not for the
        # verdict; `--phase retired` is the explicit way to run them.
        if [[ "$test_phase" == "retired" && "$FILTER_PHASE" != "retired" ]]; then
            log_test_result "$spec_id" "$test_name" "SKIP" "Phase retired: runs only under --phase retired"
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
        local _pt_t0 _pt_dur _pt_rc _lt_verdict _lt_status _lt_failed_step
        _pt_t0="$(timing_now_ms 2>/dev/null || echo 0)"
        LITMUS_LAST_TEST_TIMED_OUT=0
        _LT_CUR_STEP=0
        # ORDER 1309-fhxb: 2 = SKIPPED (asked no question), 3 = ADVISORY (held,
        # with a note). Both are non-failures and neither is a plain PASS.
        # `set -e` IS IN FORCE (:44). A BARE call whose function returns non-zero
        # exits the whole runner — and the old `if run_litmus_test_file; then`
        # suppressed that only because a condition context does. Returning 2 or 3
        # from the derivation therefore KILLED THE SUITE MID-RUN, silently: the
        # first ADVISORY test ended the stream with no summary and an exit status
        # that read as success downstream. Measured here 2026-09-20, and the only
        # symptom was output that stopped rather than output that complained.
        if run_litmus_test_file "$test_file" "$spec_id"; then _lt_verdict=0; else _lt_verdict=$?; fi
        # 1242-4x53: the per-test record carries HOW the test went and, for a
        # failure, WHICH step. ADVISORY (3) counts as pass here as it does in
        # the summary; a verdict SKIP (2) is recorded as skip, never as pass.
        case "$_lt_verdict" in 0|3) _lt_status=pass ;; 2) _lt_status=skip ;; *) _lt_status=fail ;; esac
        case "$_lt_verdict" in
            0)  _pt_rc=0
                log_test_result "$spec_id" "$test_name" "PASS" "" ;;
            2)  _pt_rc=0
                TESTS_VERDICT_SKIPPED=$((TESTS_VERDICT_SKIPPED+1))
                log_test_result "$spec_id" "$test_name" "SKIP" "every executed step was a named skip — no question asked (1309-fhxb)" ;;
            3)  _pt_rc=0
                TESTS_ADVISORY=$((TESTS_ADVISORY+1))
                log_test_result "$spec_id" "$test_name" "PASS" "" ;;
            *)  _pt_rc=1
                log_test_result "$spec_id" "$test_name" "FAIL" "Check implementation"
                spec_failed=1 ;;
        esac
        # 956-llei: a killed test's elapsed time is its budget — censored data.
        # Record rc 124 so the slowest-tests table and the timing consumer can
        # tell "took 30s" from "was stopped at 30s".
        if [[ "$_pt_rc" -ne 0 && "$LITMUS_LAST_TEST_TIMED_OUT" -eq 1 ]]; then
            _pt_rc=124
            # 1187-iij8: counted IN ADDITION to the FAIL already recorded above.
            # Note the ordering — log_test_result has already incremented
            # TESTS_FAILED and nothing here decrements it.
            TESTS_BUDGET_KILLED=$((TESTS_BUDGET_KILLED+1))
        fi
        if [[ "$_pt_t0" =~ ^[0-9]+$ && "$_pt_t0" -gt 0 ]]; then
            _pt_dur=$(( $(timing_now_ms 2>/dev/null || echo 0) - _pt_t0 ))
            [[ "$_pt_dur" -ge 0 && "$_pt_dur" -lt 86400000 ]] || _pt_dur=0
            _lt_failed_step=""
            [[ "$_lt_status" == fail ]] && _lt_failed_step="$_LT_CUR_STEP"
            # 1395-88tp: fields 6/7 are the litmus FILE and the spec it ran
            # under, digested once for the whole suite at emission so the
            # record names the bytes it ran against.
            _PER_TEST_LOG="${_PER_TEST_LOG}${_pt_dur}	${test_name}	${_pt_rc}	${_lt_status}	${_lt_failed_step}	${test_file}	${spec_id}
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
    # 1187-iij8: printed only when non-zero, and worded as a SUBSET of the FAIL
    # above rather than a sibling of it, so no reader can take it for a bucket
    # that softens the verdict.
    if [[ "$TESTS_BUDGET_KILLED" -gt 0 ]]; then
        printf '  %bBUDGET%b: %d of those FAILs were killed at their budget, not failed assertions (still FAIL — 820-c8q8)\n' \
            "${YELLOW}" "${NC}" "$TESTS_BUDGET_KILLED" >&2
    fi
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
    # ORDER 1309-fhxb. ADDED LINES, never a reshape of the ones above: the census
    # on the row names seven parsers of this surface, and
    # test-litmus-missing-bound-test-reds.sh asserts the LITERAL string
    # `Pass Rate: 100% (1/1 executed)`.
    #
    # STEP VERDICTS, and the definition is printed with them so nobody re-derives
    # the denominator from the numbers. An ADVISORY is a property that held with
    # a note, so it counts with passed. A SKIP is a question NOT ASKED, so it
    # leaves the denominator entirely — scoring it either way is a claim nobody
    # measured.
    # ORDER 1309-fhxb — the four TEST verdicts, commensurable with the rate above.
    # THE DENOMINATOR NARROWS BY CONSTRUCTION, not by arithmetic: total_executed is
    # TESTS_PASSED + TESTS_FAILED, and a SKIPPED test increments neither, so a test
    # that asked no question leaves the rate entirely. ADVISORY tests are logged
    # PASS and therefore counted with passed — a property held, with a note.
    # TWO POPULATIONS, TWO LABELS. TESTS_SKIPPED already counted things that were
    # NEVER ATTEMPTED — a test bound to several specs and already executed, and a
    # diff-scope skip — long before a verdict skip existed. Printing both under
    # the word "skipped" would put a definition on the line that is true of only
    # part of what it counts, which is 1049-s35z's shape with a footnote, and it
    # would make the test line's `skipped=` incommensurable with the step line's.
    # So: `skipped=` is VERDICT skips only, and `not-run=` is what was never
    # attempted. Neither is in the rate's denominator, and neither ever was.
    printf '%bTest Verdicts%b: passed=%d advisory=%d skipped=%d not-run=%d failed=%d\n' "${BOLD}" "${NC}" \
        "$((TESTS_PASSED - TESTS_ADVISORY))" "${TESTS_ADVISORY:-0}" "${TESTS_VERDICT_SKIPPED:-0}" \
        "$(( ${TESTS_SKIPPED:-0} - ${TESTS_VERDICT_SKIPPED:-0} ))" "${TESTS_FAILED:-0}" >&2
    printf '               skipped = its executed steps asked no question; not-run = never attempted (already executed for another spec, or out of diff scope); both outside the rate; advisory held its property and counts with passed\n' >&2
    if [[ "${STEPS_SKIPPED:-0}" -gt 0 || "${STEPS_ADVISORY:-0}" -gt 0 ]]; then
        printf '%bStep Verdicts%b: advisory=%d skipped=%d\n' "${BOLD}" "${NC}" \
            "${STEPS_ADVISORY:-0}" "${STEPS_SKIPPED:-0}" >&2
        printf '               advisory counts with passed (a property held, with a note); skipped is excluded from the rate (a question not asked)\n' >&2
    fi

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
            # 1395-88tp: column 8 is the sha256 of the litmus file's bytes, so the
            # CentiColon grader credits a green record only to the bytes that
            # ran (a record dies when the file changes). ONE hashing spawn for
            # the whole suite; a host with neither tool writes no digest, and
            # absence never reads as a verdict.
            _pt_files="$(awk -F'\t' -v root="$PROJECT_ROOT" 'NF >= 6 && $6 != "" {print $6; if ($7 != "") print root "/openspec/specs/" $7 "/spec.md"}' <<<"$_PER_TEST_LOG" | sort -u)"
            _pt_digests=""
            if [[ -n "$_pt_files" ]]; then
                if command -v sha256sum >/dev/null 2>&1; then
                    _pt_digests="$(tr '\n' '\0' <<<"$_pt_files" | xargs -0 sha256sum 2>/dev/null || true)"
                elif command -v shasum >/dev/null 2>&1; then
                    _pt_digests="$(tr '\n' '\0' <<<"$_pt_files" | xargs -0 shasum -a 256 2>/dev/null || true)"
                fi
            fi
            # The digest list is MULTI-LINE, so it travels through ENVIRON: BSD
            # awk rejects a newline inside a -v value ("newline in string"),
            # and on macOS that silently emptied every per-test record
            # (macbookair, 2026-09-26: 324 tests executed, 0 records written).
            _pt_rows="$(printf '%s' "$_PER_TEST_LOG" | PT_DIGESTS="$_pt_digests" awk -F'\t' \
                -v phase="${FILTER_PHASE:-unknown}" \
                -v host="${TILLANDSIAS_HOST_ID:-$(hostname 2>/dev/null || echo unknown)}" \
                -v root="$PROJECT_ROOT" \
                -v regime="$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' | sed 's/^mingw.*/msys/; s/^msys.*/msys/; s/^cygwin.*/msys/')" \
                'BEGIN { digests = ENVIRON["PT_DIGESTS"]; n = split(digests, dl, "\n"); for (i = 1; i <= n; i++) { h = dl[i]; f = dl[i]; sub(/[ \t].*$/, "", h); sub(/^[0-9a-f]+[ \t]+\*?/, "", f); if (h ~ /^[0-9a-f]+$/) dg[f] = h } }
                 NF >= 3 { name = $2; sub(/^litmus:/, "", name); sp = root "/openspec/specs/" $7 "/spec.md"; printf "litmus:%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", name, phase, $1, $3, host, $4, $5, (($6 in dg) ? dg[$6] : ""), regime, $7, ((sp in dg) ? dg[sp] : "") }')"
            # Rows went in and none came out: the producer failed. Say so —
            # the enclosing `2>/dev/null || true` is what hid the BSD case.
            if [[ -z "$_pt_rows" ]]; then
                echo "could-not-run:litmus-per-test-records:producer-emitted-nothing ($(grep -c . <<<"$_PER_TEST_LOG") rows in)"
            else
                printf '%s\n' "$_pt_rows" | bash "$PROJECT_ROOT/scripts/cycle-metrics.sh" --emit-timing-batch
            fi
        } 2>/dev/null || true
        # `|| true`: under `set -eo pipefail`, head's early close SIGPIPEs
        # sort/awk (rc 141) once the sweep is big enough to overflow ten
        # lines, aborting the runner AFTER it printed PASS — ci-full then
        # reported "litmus failures detected" over a log reading 100%
        # (measured 2026-08-25: full pre-build quick sweep exit 141, single
        # -spec runs unaffected because head never closes early on them).
        _slow_tests="$(printf '%s' "$_PER_TEST_LOG" | sort -rn | awk -F'\t' '$1 >= 500 {printf "  %7.1fs  %s%s\n", $1/1000, $2, ($3 == 124 ? "  (killed at budget — censored; the true time is longer)" : "")}' | head -10 || true)"
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
                echo "     --parse-only <file>... loads each file as YAML and REFUSES if it does not load, then reports whether THIS RUNNER can extract its steps (order 1303-2d5g)" >&2
                echo "                            scripts/check-litmus-yaml-parses.sh is the AUTHORITATIVE gate over the whole corpus; --parse-only answers for named files only" >&2
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
        # ORDER 1274-cbk7. SAY WHICH QUESTION THIS ANSWERS. The defect this
        # closes is not that an author forgot a rule — it is that two checks
        # answer two different questions and the one authors reach for did not
        # say which was which. A green here means THIS RUNNER can extract the
        # steps; it is not a YAML validity verdict, and a file can be
        # extractable and unloadable at the same time.
        # ORDER 1303-2d5g supersedes 1274-cbk7's wording. That note told the
        # reader to run the strict checker for YAML validity; since the load
        # below, this flag ANSWERS that question for the named files, so the
        # old text sent people to re-run a check this verdict had just made.
        # What remains true, and is the only thing worth saying here, is the
        # difference in SCOPE: this answers for the files named on the command
        # line, and the gate answers for the whole corpus.
        printf 'note:parse-only judges the FILES NAMED HERE (loads each as YAML, then reports extractability); scripts/check-litmus-yaml-parses.sh is the corpus-wide gate\n' >&2
        # ORDER 1303-2d5g. LOAD THE DOCUMENT BEFORE EXTRACTING FROM IT.
        #
        # 1274-cbk7 added the note above, on the theory that naming the
        # question was enough. It is not: MEASURED on esmeraldinha 2026-09-20,
        # a file that `tillandsias-plan validate-yaml` REFUSES (rc=1,
        # `blocked:yaml-load-failed: could not find expected ':'`) came back
        # from here as `ok:litmus-parseable:<f>:1 step(s)` — it even reported a
        # step count, because this runner's extraction is LINE-BASED and never
        # loads the document. The note was printed directly above that line and
        # did not help, because A READER ACTS ON THE VERDICT WORD. Two
        # instruments disagreeing about one file, with the looser one the one
        # authors reach for first, is how a broken litmus reaches a gate on one
        # host and is refused on another twenty minutes later (land 25).
        #
        # So the verdict may not say `ok:` for a file that is not YAML. The
        # load runs FIRST and its own message is passed through verbatim, so
        # this refusal names the same file and line the strict checker names
        # and the two instruments cannot disagree about the same file again.
        #
        # NO READER IS ITS OWN NAMED STATE, not a pass — and the wording and
        # the stand-aside both match scripts/check-litmus-yaml-parses.sh
        # deliberately, because two instruments answering the same question
        # must not differ on what "cannot answer" looks like. Extractability is
        # still reported, since that is this flag's own question and a fresh
        # clone must still be able to ask it.
        local parse_reader="${LITMUS_PLAN_BIN:-}"
        if [[ -z "$parse_reader" || ! -x "$parse_reader" ]]; then
            printf 'skip:parse-only:yaml-load-unchecked:no-runnable-reader (run scripts/cycle-preflight.sh) — the lines below answer extractability ONLY\n' >&2
        fi
        for parse_target in ${PARSE_ONLY_FILES[@]+"${PARSE_ONLY_FILES[@]}"}; do
            if [[ ! -f "$parse_target" ]]; then
                printf 'blocked:parse-only:missing:%s\n' "$parse_target" >&2
                parse_rc=1
                continue
            fi
            if [[ -n "$parse_reader" && -x "$parse_reader" ]]; then
                local parse_yaml_out=""
                # MUTATION ANCHOR, and it is load-bearing for a fixture that is
                # not this order's. scripts/test-litmus-parse-only-duplicate-key.sh
                # (order 1274-cbk7) proves its defect by building a PRE-FIX COPY
                # of this runner with the duplicate-key detector neutralised and
                # requiring the false green to come back. Once 1303-2d5g added
                # the document load above that detector, the load rejected the
                # duplicate first and that arm stopped reproducing anything —
                # TWO FIXES FOR ONE FILE, with the older fixture's mutation
                # mutating something no longer reachable.
                #
                # So the load is switched by a line of its own, which that
                # fixture seds to 0 alongside its own mutation. Keep this line
                # a single assignment on one line: a sed anchored on it is
                # matching text, and reflowing this breaks an arm in another
                # file that will not be obvious from here.
                local _parse_load_enabled=1  # LOAD-GATE-1303 (ARM 1 anchor)
                if [[ "$_parse_load_enabled" == "1" ]] \
                   && ! parse_yaml_out="$("$parse_reader" validate-yaml "$parse_target" 2>&1)"; then
                    printf 'blocked:parse-only:not-yaml:%s\n' "$parse_target" >&2
                    [[ -n "$parse_yaml_out" ]] && printf '%s\n' "$parse_yaml_out" >&2
                    parse_rc=1
                    continue
                fi
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

    # ORDER 871-wrmv: STAGE THE ROUTER SIDECAR BEFORE ANY STEP COMPILES RUST.
    #
    # `images/router/tillandsias-router-sidecar` is a BUILD ARTIFACT, gitignored
    # and never committed (710-w9kc), and tillandsias-headless/build.rs
    # hard-panics when it is absent. 29 litmus files invoke cargo against that
    # crate, so on a fresh clone — or any host whose target/ was wiped — each of
    # them fails for a reason that has nothing to do with what it tests.
    #
    # THIS IS WHY IT MATTERS BEYOND ONE RED TEST. 865-n8vq's ledger of seven
    # release blockers is only as trustworthy as its causes, and at least one of
    # those entries was an unstaged artifact on the running host rather than a
    # trunk defect. A gate that reports environmental failures as code failures
    # makes every entry in its own list less believable.
    #
    # ONCE PER RUN, NOT PER STEP. Patching 29 files would leave the 30th, and
    # the packet's own criterion offers the runner preflight as the alternative.
    # build.sh already stages before every compiling dispatch
    # (_stage_router_sidecar_if_compiling); this is the same call for the lane
    # that had none.
    #
    # SKIPPED WHEN ALREADY PRESENT, so the common case costs one `[[ -f ]]`.
    # NON-FATAL BY DESIGN: a host that cannot build the sidecar (no rust
    # toolchain) must still run the many litmus specs that never touch cargo,
    # so a staging failure is NAMED and the run continues — the affected steps
    # then fail with build.rs's own diagnostic, which already tells the reader
    # exactly what to do. Refusing the whole run here would trade 29 confusing
    # failures for a total outage on hosts that have no stake in them.
    if [[ ! -f "$PROJECT_ROOT/images/router/tillandsias-router-sidecar" ]]; then
        if [[ -f "$PROJECT_ROOT/scripts/build-sidecar.sh" ]]; then
            log_info "Staging router sidecar (build artifact, absent — 871-wrmv)..."
            if bash "$PROJECT_ROOT/scripts/build-sidecar.sh" >/dev/null 2>&1; then
                log_info "Router sidecar staged"
            else
                log_warn "could not stage images/router/tillandsias-router-sidecar (871-wrmv) — steps that compile tillandsias-headless will fail with build.rs's missing-asset panic, which is an ENVIRONMENT fault and not a code defect"
            fi
        else
            log_warn "images/router/tillandsias-router-sidecar is absent and scripts/build-sidecar.sh is missing (871-wrmv) — steps compiling tillandsias-headless will panic on the missing asset"
        fi
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
