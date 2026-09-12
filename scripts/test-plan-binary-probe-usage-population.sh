#!/usr/bin/env bash
# @trace order:1128-j9fc
#
# test-plan-binary-probe-usage-population.sh — does the probe-usage guard
# actually WALK the surfaces it claims to?
#
# WHY THIS EXISTS. check-plan-binary-probe-usage.sh has now been found too
# narrow three times, each time by a human noticing a file that resolved the
# binary by hand while the guard was green (751-vega litmus commands, 1060-428m
# mention-vs-use, 1128-j9fc the gate entry point). Every one of those was
# invisible because an unwalked surface and a clean surface produce the SAME
# verdict. This fixture makes the population falsifiable: plant a violation on
# each surface and require the guard to find it.
#
# THE .step ARM IS THE ONE THAT MATTERS MOST. gate-steps.d/*.step files are
# shell run by the gate and live UNDER scripts/ — a directory the guard already
# scanned — yet no `find -name '*.sh'` walk can ever match them. The extension
# hid them, not the location. Three hosts reasoned about directories all night
# while a whole surface sat inside one they had already agreed to scan.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/scripts/check-plan-binary-probe-usage.sh"
fail=0

_mkroot() {
    _d="$(mktemp -d)"
    mkdir -p "$_d/scripts/gate-steps.d" "$_d/openspec/litmus-tests"
    # The probe must exist: the guard skips it by name, and a compliant file
    # must have something real to source.
    printf 'resolve_plan_binary() { echo /bin/true; }\n' > "$_d/scripts/plan-binary-probe.sh"
    printf '%s\n' "$_d"
}

_expect() {
    _name="$1"; _want_rc="$2"; _want_sub="$3"; shift 3
    _out="$("$@" 2>&1)"; _rc=$?
    if [ "$_rc" = "$_want_rc" ] && case "$_out" in *"$_want_sub"*) true ;; *) false ;; esac; then
        echo "ok: $_name ($_out)"
    else
        echo "FAIL: $_name — wanted rc=$_want_rc containing '$_want_sub', got rc=$_rc: $_out"
        fail=1
    fi
}

# ARM 1 — a hardcoded resolution in a repo-ROOT shell file is REFUSED.
# This is 1128-j9fc's surface: build.sh is the gate entry point and was outside
# its own guard's population.
d="$(_mkroot)"
printf '#!/usr/bin/env bash\nif [ -x "$R/target/release/tillandsias-plan" ]; then :; fi\n' > "$d/build.sh"
_expect "root-shell-file-is-walked" 1 "violation:plan-binary-probe-usage:1" \
    env PLAN_PROBE_ROOT="$d" bash "$GUARD"
rm -rf "$d"

# ARM 2 — a hardcoded resolution in a gate-steps.d/*.step is REFUSED.
# The extension arm. Under scripts/, which was already scanned, and still
# unreachable by a '*.sh' walk.
d="$(_mkroot)"
printf '#!/usr/bin/env bash\nif [ -x "$R/target/release/tillandsias-plan" ]; then :; fi\n' > "$d/scripts/gate-steps.d/099-probe.step"
_expect "gate-step-extension-is-walked" 1 "violation:plan-binary-probe-usage:1" \
    env PLAN_PROBE_ROOT="$d" bash "$GUARD"
rm -rf "$d"

# ARM 3 — NEGATIVE CONTROL, and it is the load-bearing one. A clean tree must
# pass, and the verdict must NAME the entry surface. Without this arm, arms 1
# and 2 are satisfied by a guard that refuses everything.
d="$(_mkroot)"
printf '#!/usr/bin/env bash\n. scripts/plan-binary-probe.sh\nP="$(resolve_plan_binary)"\n' > "$d/build.sh"
_expect "clean-tree-passes-and-names-the-entry-surface" 0 "entry=" \
    env PLAN_PROBE_ROOT="$d" bash "$GUARD"
rm -rf "$d"

# ARM 4 — the SCOPED-CALL SEAM is preserved. An explicit positional scan dir
# keeps the pre-1128 semantics (scripts only), so a caller that asked for one
# directory does not silently get the entry surface too.
d="$(_mkroot)"
printf '#!/usr/bin/env bash\nif [ -x "$R/target/release/tillandsias-plan" ]; then :; fi\n' > "$d/build.sh"
_expect "explicit-scan-dir-stays-scoped" 0 "entry=0/0" \
    env PLAN_PROBE_ROOT="$d" bash "$GUARD" scripts
rm -rf "$d"

[ "$fail" = 0 ] && echo "ok:plan-binary-probe-usage-population:4"
exit "$fail"
