#!/usr/bin/env bash
# @trace spec:init-command
# @trace order:1276-2hc6
#
# THE CONTROLS for scripts/test-windows-host-lane-refusal.sh. A guard nobody
# has watched fail is a guard nobody has tested, so these sabotage a COPY of
# the source and require the fixture to go red for the RIGHT REASON.
#
# THEY LIVE IN A SCRIPT, NOT IN THE LITMUS `command:`, for two measured
# reasons. First, the move sabotage needs a multi-line awk program, and
# embedding one in a double-quoted YAML scalar produced a file that
# scripts/check-litmus-yaml-parses.sh rejected while the runner's own
# --parse-only still said ok — two instruments disagreeing about the same
# file, with the stricter one right. Second, the first version of that step
# used `python3 -c`, which the no-Python-runtime policy (1087-h2z9) correctly
# refuses; the gate caught it and the land was refused.
#
# EVERY CONTROL ASSERTS ITS OWN EDIT LANDED before trusting the red. An earlier
# attempt here exited 1 because a failed heredoc never wrote the sabotaged
# copy, so the fixture read a MISSING FILE: correct exit code, no sabotage, and
# a control that proved nothing.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"

SRC="crates/tillandsias-headless/src/main.rs"
FIXTURE="scripts/test-windows-host-lane-refusal.sh"
[ -f "$SRC" ]     || { echo "blocked:controls:no-source:$SRC"; exit 1; }
[ -x "$FIXTURE" ] || { echo "blocked:controls:no-fixture:$FIXTURE"; exit 1; }

D="$(mktemp -d)"; trap 'rm -rf "$D"' EXIT
fail=0

# CONTROL 1 — the refusal call is REMOVED from run_init: the pre-fix state.
sed 's|    if let Some(refusal) = windows_host_lane_refusal() {|    if false {|' "$SRC" > "$D/removed.rs"
if cmp -s "$SRC" "$D/removed.rs"; then
    echo "FAIL: control-1 sabotage changed nothing — it proves nothing"; fail=1
else
    out="$(TILLANDSIAS_HEADLESS_SRC="$D/removed.rs" bash "$FIXTURE" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "FAIL: control-1 — the fixture PASSED a source with no refusal call"; fail=1
    elif printf '%s' "$out" | grep -q 'does not call windows_host_lane_refusal'; then
        echo "ok: control-1 red when the refusal call is removed"
    else
        echo "FAIL: control-1 red for the wrong reason: $out"; fail=1
    fi
fi

# CONTROL 2 — the refusal is MOVED below lane selection. This is the control
# worth having: the TEXT arms stay green, so a litmus that only grepped for the
# refusal wording would pass a source that enters the lane before refusing.
awk '
  /^    if let Some\(refusal\) = windows_host_lane_refusal\(\) \{$/ { skip=3; got=1; next }
  skip>0 { skip--; next }
  { print }
  /^    report_runtime_lane\("--init", debug\);$/ && got && !done {
      print "    if let Some(refusal) = windows_host_lane_refusal() {"
      print "        return Err(refusal);"
      print "    }"
      done=1
  }
' "$SRC" > "$D/moved.rs"
if cmp -s "$SRC" "$D/moved.rs"; then
    echo "FAIL: control-2 sabotage changed nothing — it proves nothing"; fail=1
else
    out="$(TILLANDSIAS_HEADLESS_SRC="$D/moved.rs" bash "$FIXTURE" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "FAIL: control-2 — a refusal BELOW lane selection passed"; fail=1
    elif ! printf '%s' "$out" | grep -q 'comes AFTER'; then
        echo "FAIL: control-2 red for the wrong reason: $out"; fail=1
    elif ! printf '%s' "$out" | grep -q 'names the working command'; then
        echo "FAIL: control-2 — expected the TEXT arms to stay GREEN under a move sabotage; if they went red this control no longer isolates position"; fail=1
    else
        echo "ok: control-2 red on position while the text arms stay green"
    fi
fi

[ "$fail" -eq 0 ] && echo "ok:windows-host-lane-refusal-controls:2/2" || echo "FAIL:windows-host-lane-refusal-controls"
exit "$fail"
