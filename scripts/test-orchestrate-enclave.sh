#!/usr/bin/env bash
# @trace order:1170-e5im
#
# test-orchestrate-enclave.sh — hermetic fixture for
# scripts/orchestrate-enclave.sh Step 5 (the forge launch).
#
# THE DEFECT THIS PINS (829-dkuc sweep finding, packet 1170-e5im). Step 5's
# real interactive forge `podman run` used to sit inside
# `if [ -n "$STATUS_CHECK_MODE" ]; then ... fi` — a variable
# (TILLANDSIAS_STATUS_CHECK) scripts/check-dead-env-branches.sh reports READ
# and never ASSIGNED anywhere in this tree, so the guard was never true on a
# real invocation and the forge launch never ran.
#
# ARMS:
#   1. POSITIVE — with TILLANDSIAS_STATUS_CHECK unset (the production
#      state), the interactive forge `podman run` (--interactive --tty --rm
#      --name tillandsias-<project>-forge) IS reached: calls.log carries its
#      line. Pre-fix this FAILS — the launch sat under the never-taken
#      guard.
#   2. NEGATIVE — the guard legitimately protects something else: a
#      status-check health probe (a separate, --entrypoint /bin/bash
#      `podman run`) and two Step 4 refinements (a skip-runtime-pulls env
#      var and a wait-for-health call). With TILLANDSIAS_STATUS_CHECK SET,
#      all three still happen — proving the fix left what the guard is FOR
#      alone, and that the always-on forge launch also still runs.
#   3. MUTATION CONTROL, built FROM THE CURRENT SCRIPT'S CONTENT (never from
#      git): "revert-the-denesting" — re-wrap the forge launch back under
#      the STATUS_CHECK_MODE guard, the exact defect this packet fixes.
#      `cmp` proves the mutant differs from the fixed script; arm 1's own
#      assertion must then RED against the mutant, proof the fixture has
#      teeth rather than being a rubber stamp.
#
# HERMETIC BY CONSTRUCTION. Each arm gets its own scratch root (HOME,
# TMPDIR, a throwaway project dir) mirroring just enough of scripts/ for
# BASH_SOURCE-relative sourcing to succeed (common.sh, lib-ca-path.sh,
# lib/enclave-proxy.sh, lib/tool-dispatch.sh, nvidia-cdi-ensure.sh are real,
# unmodified copies of this checkout's files — only the candidate
# orchestrate-enclave.sh under test is swapped in), plus a PATH-prefixed
# stub dir shadowing every external command the Step 5 path reaches: podman
# (everything), openssl (CA cert generation), tillandsias (inference tier
# probe), nvidia-smi (GPU probe from nvidia-cdi-ensure.sh). Every stub logs
# its argv (printf %q, one call per line) to calls.log and exits 0.
#
# Regime: bash 3.2 clean, no sed -i (mutant written via awk to a fresh
# file), mutants built from file content, never from git.
#
# Verdict grammar, one line on stdout:
#   PASS: orchestrate-enclave N/N (1170-e5im)
#   FAIL: orchestrate-enclave <k>/N (1170-e5im)
# Findings go to stderr. Exit 0 on PASS, 1 on FAIL.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_SCRIPT="$SCRIPT_DIR/orchestrate-enclave.sh"
PROJECT_NAME="orchtest"

TOTAL=3
PASS_COUNT=0
FAIL_COUNT=0

CLEANUP_DIRS=""
cleanup() {
    # shellcheck disable=SC2086
    [ -n "$CLEANUP_DIRS" ] && rm -rf $CLEANUP_DIRS
}
trap cleanup EXIT

note() { echo "  $*" >&2; }
arm_fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "FAIL(arm $1): $2" >&2
}
arm_pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "ok(arm $1): $2" >&2
}

# ---------------------------------------------------------------------------
# build_harness ROOT CANDIDATE_SCRIPT
#
# Mirrors just enough of scripts/ into ROOT for BASH_SOURCE-relative
# sourcing to succeed, drops CANDIDATE_SCRIPT in as
# ROOT/scripts/orchestrate-enclave.sh, and stubs every external command it
# reaches on the Step 5 path.
# ---------------------------------------------------------------------------
build_harness() {
    local root="$1"
    local candidate="$2"
    local calls="$root/calls.log"

    mkdir -p "$root/scripts/lib" "$root/bin" "$root/home" "$root/tmp" "$root/project"
    cp "$SCRIPT_DIR/common.sh" "$root/scripts/common.sh"
    cp "$SCRIPT_DIR/lib-ca-path.sh" "$root/scripts/lib-ca-path.sh"
    cp "$SCRIPT_DIR/lib/enclave-proxy.sh" "$root/scripts/lib/enclave-proxy.sh"
    cp "$SCRIPT_DIR/lib/tool-dispatch.sh" "$root/scripts/lib/tool-dispatch.sh"
    cp "$SCRIPT_DIR/nvidia-cdi-ensure.sh" "$root/scripts/nvidia-cdi-ensure.sh"
    printf '0.0.0-orchtest\n' > "$root/VERSION"
    printf 'harmless fixture project file\n' > "$root/project/README"
    cp "$candidate" "$root/scripts/orchestrate-enclave.sh"
    chmod +x "$root/scripts/orchestrate-enclave.sh" "$root/scripts/nvidia-cdi-ensure.sh"

    : > "$calls"

    cat > "$root/bin/podman" <<STUB
#!/usr/bin/env bash
{ printf 'podman'; printf ' %q' "\$@"; printf '\n'; } >> "$calls"
case "\$1" in
    images)
        printf '%s\n' \\
            'localhost/tillandsias-proxy:v0.0.0-orchtest' \\
            'localhost/tillandsias-git:v0.0.0-orchtest' \\
            'localhost/tillandsias-inference:v0.0.0-orchtest'
        exit 0
        ;;
    network)
        case "\$2" in
            exists) exit 1 ;;
            inspect) printf 'true\n'; exit 0 ;;
            *) exit 0 ;;
        esac
        ;;
    *) exit 0 ;;
esac
STUB

    cat > "$root/bin/openssl" <<STUB
#!/usr/bin/env bash
{ printf 'openssl'; printf ' %q' "\$@"; printf '\n'; } >> "$calls"
_prev=""
for _a in "\$@"; do
    case "\$_prev" in
        -keyout|-out) : > "\$_a" ;;
    esac
    _prev="\$_a"
done
exit 0
STUB

    # A harmless "legacy_tier":"cpu" payload -- NOT to steer the tier probe
    # (cpu is already the script's own default) but because the real
    # orchestrate-enclave.sh pipes this through `grep -m1 -o ... | sed ...`
    # under `set -euo pipefail`, and a stub that answers nothing makes grep
    # find no match and exit 1, which -e then treats as this whole script
    # failing -- a real, pre-existing Step 4 fragility this fixture must not
    # trip over while it is only here to pin Step 5.
    cat > "$root/bin/tillandsias" <<STUB
#!/usr/bin/env bash
{ printf 'tillandsias'; printf ' %q' "\$@"; printf '\n'; } >> "$calls"
printf '{"legacy_tier": "cpu"}\n'
exit 0
STUB

    cat > "$root/bin/nvidia-smi" <<STUB
#!/usr/bin/env bash
{ printf 'nvidia-smi'; printf ' %q' "\$@"; printf '\n'; } >> "$calls"
exit 0
STUB

    chmod +x "$root/bin/podman" "$root/bin/openssl" "$root/bin/tillandsias" "$root/bin/nvidia-smi"
}

# ---------------------------------------------------------------------------
# run_harness ROOT STATUS_CHECK_VALUE
#
# Invokes ROOT/scripts/orchestrate-enclave.sh with TILLANDSIAS_STATUS_CHECK
# set to STATUS_CHECK_VALUE. "" is the production state: the script reads it
# as "${TILLANDSIAS_STATUS_CHECK:-}", which treats set-to-empty and
# genuinely-unset identically, so passing "" here is faithful to "unset".
# env -i wipes the rest of this process's environment so no operator-host
# TILLANDSIAS_* or PATH state can leak into the run.
# ---------------------------------------------------------------------------
run_harness() {
    local root="$1"
    local scv="$2"
    env -i \
        PATH="$root/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        HOME="$root/home" \
        TMPDIR="$root/tmp" \
        TILLANDSIAS_CA_DIR="$root/ca" \
        TILLANDSIAS_STATUS_CHECK="$scv" \
        bash "$root/scripts/orchestrate-enclave.sh" "$root/project" "$PROJECT_NAME" \
        > "$root/stdout.log" 2> "$root/stderr.log"
    return $?
}

FORGE_RUN_PATTERN='run --interactive --tty --rm --name tillandsias-orchtest-forge'
PROBE_ENTRYPOINT_PATTERN='--entrypoint /bin/bash'
SKIP_PULLS_PATTERN='TILLANDSIAS_INFERENCE_SKIP_RUNTIME_PULLS=1'
INFERENCE_WAIT_PATTERN='wait --condition=healthy tillandsias-inference'

# `--` before every pattern below is load-bearing, not decoration:
# PROBE_ENTRYPOINT_PATTERN starts with "--", and both GNU grep and this
# host's ugrep shell wrapper parse a leading "--" pattern as an option
# string and refuse it ("unrecognized option") without the `--`
# end-of-options marker forcing it to be read as PATTERNS instead.
forge_reached() { grep -qF -- "$FORGE_RUN_PATTERN" "$1/calls.log" 2>/dev/null; }
probe_reached() { grep -qF -- "$PROBE_ENTRYPOINT_PATTERN" "$1/calls.log" 2>/dev/null; }
skip_pulls_present() { grep -qF -- "$SKIP_PULLS_PATTERN" "$1/calls.log" 2>/dev/null; }
inference_wait_present() { grep -qF -- "$INFERENCE_WAIT_PATTERN" "$1/calls.log" 2>/dev/null; }

# ===========================================================================
# Arm 1 — POSITIVE: forge launch reached with TILLANDSIAS_STATUS_CHECK unset.
# ===========================================================================
h1="$(mktemp -d "${TMPDIR:-/tmp}/orch-test-arm1.XXXXXX")"
CLEANUP_DIRS="$CLEANUP_DIRS $h1"
build_harness "$h1" "$REAL_SCRIPT"
run_harness "$h1" ""
rc1=$?
if forge_reached "$h1"; then
    arm_pass 1 "forge podman run reached with TILLANDSIAS_STATUS_CHECK unset (script rc=$rc1)"
else
    arm_fail 1 "forge podman run NOT reached with TILLANDSIAS_STATUS_CHECK unset (script rc=$rc1)"
    note "calls.log:"
    note "$(cat "$h1/calls.log" 2>/dev/null)"
    note "stderr.log:"
    note "$(cat "$h1/stderr.log" 2>/dev/null)"
fi

# ===========================================================================
# Arm 2 — NEGATIVE: whatever the guard legitimately protects still behaves
# with TILLANDSIAS_STATUS_CHECK SET, and the always-on launch still runs too.
# ===========================================================================
h2="$(mktemp -d "${TMPDIR:-/tmp}/orch-test-arm2.XXXXXX")"
CLEANUP_DIRS="$CLEANUP_DIRS $h2"
build_harness "$h2" "$REAL_SCRIPT"
run_harness "$h2" "1"
rc2=$?
arm2_ok=1
if probe_reached "$h2"; then
    note "arm 2: status-check probe (--entrypoint /bin/bash) reached"
else
    arm2_ok=0
    note "arm 2: status-check probe NOT reached"
fi
if skip_pulls_present "$h2"; then
    note "arm 2: Step 4 TILLANDSIAS_INFERENCE_SKIP_RUNTIME_PULLS=1 still applied"
else
    arm2_ok=0
    note "arm 2: Step 4 skip-runtime-pulls env var missing"
fi
if inference_wait_present "$h2"; then
    note "arm 2: Step 4 inference health wait still runs"
else
    arm2_ok=0
    note "arm 2: Step 4 inference health wait missing"
fi
if forge_reached "$h2"; then
    note "arm 2: forge launch also still reached with the variable set (expected)"
else
    arm2_ok=0
    note "arm 2: forge launch NOT reached with the variable set"
fi
if [ "$arm2_ok" -eq 1 ]; then
    arm_pass 2 "everything the guard legitimately protects (probe, skip-pulls env, inference wait) still behaves, and the always-on forge launch also still runs (script rc=$rc2)"
else
    arm_fail 2 "the guard's legitimate behaviour regressed when TILLANDSIAS_STATUS_CHECK is set (script rc=$rc2)"
    note "calls.log:"
    note "$(cat "$h2/calls.log" 2>/dev/null)"
fi

# ===========================================================================
# Arm 3 — MUTATION CONTROL, built from the CURRENT script's content.
# "revert-the-denesting": re-wrap the forge launch back under the
# STATUS_CHECK_MODE guard — the exact defect 1170-e5im fixes.
# ===========================================================================
BEGIN_MARK='# forge-launch-unconditional-begin'
END_MARK='# forge-launch-unconditional-end'

mutant_dir="$(mktemp -d "${TMPDIR:-/tmp}/orch-test-arm3-mutant.XXXXXX")"
CLEANUP_DIRS="$CLEANUP_DIRS $mutant_dir"
mutant_script="$mutant_dir/orchestrate-enclave.sh"

if grep -qF -- "$BEGIN_MARK" "$REAL_SCRIPT" && grep -qF -- "$END_MARK" "$REAL_SCRIPT"; then
    awk -v begin="$BEGIN_MARK" -v end="$END_MARK" '
        $0 == begin { print; print "if [ -n \"$STATUS_CHECK_MODE\" ]; then"; next }
        $0 == end   { print "fi"; print; next }
        { print }
    ' "$REAL_SCRIPT" > "$mutant_script"

    if cmp -s "$REAL_SCRIPT" "$mutant_script"; then
        arm_fail 3 "mutation tool (revert-the-denesting no-op strip) produced a byte-identical copy of the fixed script"
    else
        h3="$(mktemp -d "${TMPDIR:-/tmp}/orch-test-arm3.XXXXXX")"
        CLEANUP_DIRS="$CLEANUP_DIRS $h3"
        build_harness "$h3" "$mutant_script"
        run_harness "$h3" ""
        rc3=$?
        if forge_reached "$h3"; then
            arm_fail 3 "mutant (forge launch re-wrapped under the dead guard, cmp-confirmed different from the fixed script) STILL reached the forge run -- the fixture has no teeth (script rc=$rc3)"
        else
            arm_pass 3 "mutant reds as predicted: re-wrapping the forge launch under STATUS_CHECK_MODE (cmp-confirmed different from the fixed script) makes it unreachable again (script rc=$rc3)"
        fi
    fi
else
    arm_fail 3 "mutation anchors ($BEGIN_MARK / $END_MARK) not found in $REAL_SCRIPT -- expected only pre-fix, before 1170-e5im's diff lands"
fi

# ===========================================================================
# Verdict
# ===========================================================================
if [ "$FAIL_COUNT" -eq 0 ] && [ "$PASS_COUNT" -eq "$TOTAL" ]; then
    echo "PASS: orchestrate-enclave $PASS_COUNT/$TOTAL (1170-e5im)"
    exit 0
else
    echo "FAIL: orchestrate-enclave $PASS_COUNT/$TOTAL (1170-e5im)"
    exit 1
fi
