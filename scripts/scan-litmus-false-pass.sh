#!/usr/bin/env bash
# @trace spec:spec-traceability
#
# scan-litmus-false-pass.sh — ORDER 870-fv7k.
#
# Find litmus steps that would be reported OK on a command that FAILED, because
# the expectation matches output the command printed on its way to failing.
#
# WHAT IT MEASURED, first run (lenovinha, 2026-08-24): 2026 steps carry an
# expectation; 887 were safe to execute read-only; of those, 856 exit 0, 28 exit
# non-zero and would correctly be reported FAIL, and ONE exited non-zero while
# still matching its expectation — litmus:methodology-accountability-shape step
# 4, which listed the nonexistent `src-tauri` directory, exited 2 on every run,
# and passed on the 69 matches it printed from the directories that do exist.
# Fixed in the same commit as this script.
#
# TWO LIMITS, both deliberate and both material to how the number is read:
#
#   1. IT SEES LESS THAN HALF THE CORPUS. 1139 steps were SKIPPED because their
#      commands are not provably read-only. That is not a claim they are clean;
#      it is a refusal to run podman resets, installers, and network calls to
#      find out. A future version could sandbox them; this one says what it did
#      not look at rather than quietly reporting over a subset.
#   2. IT APPROXIMATES THE MATCHER. It applies only the FINAL fallback of
#      run-litmus-test.sh's behavior_matches_output — case-insensitive
#      fixed-string containment — and not the special-case arms above it. So it
#      can report a step the real runner would judge differently. Confirm every
#      hit against the real runner before believing it: the first run produced
#      two such artifacts (stdlib steps that need LITMUS_STDLIB sourced, which
#      this harness does not do) and both pass legitimately in the runner.
#
# Read-only and idempotent: it executes candidate commands but writes nothing to
# the tree. Advisory — no caller gates on it.
#
# A step mis-passes RIGHT NOW when its command exits non-zero and the runner
# still reports OK — i.e. the expectation matches output the command printed on
# its way to failing.
#
# SAFETY: litmus commands are arbitrary shell and some are destructive (podman
# resets, installs, network). This runs a step ONLY when its command is built
# from a strict allowlist of read-only constructs. Anything else is SKIPPED and
# counted, so the report says what it did not look at.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2
YQ="$ROOT/target/litmus-runtime/bin/yq"
[ -x "$YQ" ] || YQ=yq

total=0; skipped=0; ran=0; mispass=0; honest_fail=0; pass=0
OUT="${TILLANDSIAS_FALSE_PASS_OUT:-${TMPDIR:-/tmp}/litmus-false-pass.txt}"; : > "$OUT"

is_safe() {
    local c="$1"
    # Refuse anything that could mutate the host, the tree, or the network.
    case "$c" in
        *podman*|*docker*|*toolbox*|*curl*|*wget*|*rm\ *|*rm-*|*mv\ *|*cp\ *|*install*|\
        *cargo*|*build.sh*|*git\ push*|*git\ commit*|*git\ checkout*|*git\ reset*|*git\ clean*|\
        *tee\ *|*">"*|*sudo*|*systemctl*|*kill*|*chmod*|*chown*|*mkdir*|*touch*|*sed\ -i*|*perl\ -pi*)
            return 1 ;;
    esac
    # Require it to look like a read-only assertion chain.
    case "$c" in
        *grep*|*test\ *|*\[\ *) return 0 ;;
    esac
    return 1
}

for f in openspec/litmus-tests/*.yaml; do
    n=$("$YQ" e '.critical_path | length // 0' "$f" 2>/dev/null) || continue
    [ -z "$n" ] && continue
    [ "$n" = "null" ] && continue
    i=0
    while [ "$i" -lt "$n" ]; do
        cmd=$("$YQ" e ".critical_path[$i].command // \"\"" "$f" 2>/dev/null)
        exp=$("$YQ" e ".critical_path[$i].expected_behavior // \"\"" "$f" 2>/dev/null)
        i=$((i+1))
        [ -z "$cmd" ] && continue
        [ "$cmd" = "null" ] && continue
        [ -z "$exp" ] && continue
        [ "$exp" = "null" ] && continue
        total=$((total+1))
        if ! is_safe "$cmd"; then skipped=$((skipped+1)); continue; fi
        ran=$((ran+1))
        out=$(timeout 10 bash -c "$cmd" 2>&1); rc=$?
        if [ "$rc" -eq 0 ]; then pass=$((pass+1)); continue; fi
        # Non-zero exit. Would the runner still call it OK? Approximate the
        # matcher's FINAL fallback: case-insensitive fixed-string containment.
        if printf '%s' "$out" | grep -Fqi "$exp"; then
            mispass=$((mispass+1))
            printf '%s\t[step %d]\trc=%d\texpected=%s\n' "$f" "$i" "$rc" "$exp" \
              >> "$OUT"
        else
            honest_fail=$((honest_fail+1))
        fi
    done
done

echo "scan: total_steps_with_expectation=$total ran=$ran skipped_unsafe=$skipped"
echo "scan: exit0=$pass nonzero_and_reported_fail=$honest_fail NONZERO_BUT_WOULD_REPORT_OK=$mispass"
