#!/usr/bin/env bash
# @trace spec:init-command
# @trace order:1276-2hc6
#
# Pin 1276-2hc6: the Windows headless launcher REFUSES --init on arrival and
# names the tray, instead of selecting a lane that cannot work and failing
# eight image builds downstream.
#
# PRE-FIX RESULT, from the operator's own transcript on esme 2026-09-19
# (v56.9.19.2): `tillandsias.exe --init` on a Windows host entered the host
# lane and produced EIGHT identical image-build failures, then a summary naming
# eight images and no cause. The supported command — the tray's
# --provision-once — appeared nowhere.
#
# EVERY SCAN HERE STRIPS COMMENTS FIRST, and that is not hygiene. The doc
# comment above the fixed function CONTAINS the refusal wording and the
# function's own name, so a scan that reads comments passes on a tree where the
# code has been deleted and only the prose remains. Measured as a repeating
# defect class in this tree; six instances in one session.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"

# TILLANDSIAS_HEADLESS_SRC exists so this fixture can be pointed at a
# SABOTAGED COPY and shown to go red. A guard nobody has watched fail is a
# guard nobody has tested; the override is the control, not a convenience.
SRC="${TILLANDSIAS_HEADLESS_SRC:-crates/tillandsias-headless/src/main.rs}"
[ -f "$SRC" ] || { echo "blocked:windows-host-lane-refusal:no-source:$SRC"; exit 1; }

CODE="$(mktemp)"; trap 'rm -f "$CODE"' EXIT
sed 's|//.*||' "$SRC" > "$CODE"

fail=0
_ok()   { echo "ok: $1"; }
_fail() { echo "FAIL: $1"; fail=1; }

# ARM 1 — THE ORDER, which is the whole defect. A refusal that runs AFTER lane
# selection still prints a lane line and still enters the lane; the row is
# about refusing ON ARRIVAL. Line numbers come from the comment-stripped copy.
run_init_ln=$(grep -n '^fn run_init' "$CODE" | head -1 | cut -d: -f1)
if [ -z "$run_init_ln" ]; then
    _fail "no 'fn run_init' in $SRC — the function this row is about is gone or renamed"
else
    refusal_ln=$(awk -v s="$run_init_ln" 'NR>s && /windows_host_lane_refusal\(\)/ {print NR; exit}' "$CODE")
    desktop_ln=$(awk -v s="$run_init_ln" 'NR>s && /require_desktop_user_session\(/ {print NR; exit}' "$CODE")
    lane_ln=$(awk    -v s="$run_init_ln" 'NR>s && /report_runtime_lane\(/          {print NR; exit}' "$CODE")
    if [ -z "$refusal_ln" ]; then
        _fail "run_init does not call windows_host_lane_refusal() at all (pre-fix state)"
    else
        for pair in "require_desktop_user_session:$desktop_ln" "report_runtime_lane:$lane_ln"; do
            nm="${pair%%:*}"; ln="${pair##*:}"
            if [ -z "$ln" ]; then
                _ok "$nm is absent from run_init — nothing for the refusal to precede"
            elif [ "$refusal_ln" -lt "$ln" ]; then
                _ok "the refusal (line $refusal_ln) precedes $nm (line $ln)"
            else
                _fail "the refusal (line $refusal_ln) comes AFTER $nm (line $ln) — the lane is entered before refusing"
            fi
        done
    fi
fi

# ARM 2 — CARDINALITY, not existence. There must be exactly TWO cfg arms: the
# Windows one that refuses and the non-Windows one that does not. One arm alone
# either refuses everywhere or nowhere, and both compile.
win_arm=$(grep -c '#\[cfg(target_os = "windows")\]' "$CODE")
not_win_arm=$(grep -c '#\[cfg(not(target_os = "windows"))\]' "$CODE")
defs=$(grep -c '^fn windows_host_lane_refusal' "$CODE")
if [ "$defs" -eq 2 ]; then
    _ok "windows_host_lane_refusal has exactly 2 cfg-gated definitions"
else
    _fail "expected 2 definitions of windows_host_lane_refusal, found $defs"
fi
[ "$win_arm" -ge 1 ] && [ "$not_win_arm" -ge 1 ] \
    && _ok "both a windows and a not(windows) cfg arm are present" \
    || _fail "missing a cfg arm (windows=$win_arm not-windows=$not_win_arm)"

# ARM 3 — THE REFUSAL NAMES THE WORKING COMMAND. A refusal that does not say
# what to run instead is the failure this row exists to fix, one message later.
if grep -q 'refused:windows-host-lane' "$CODE"; then
    _ok "the refusal carries its grammar token refused:windows-host-lane"
else
    _fail "no refused:windows-host-lane token in code (comments stripped)"
fi
if grep -q 'tillandsias-tray.exe --provision-once' "$CODE"; then
    _ok "the refusal names the working command (tillandsias-tray.exe --provision-once)"
else
    _fail "the refusal does not name tillandsias-tray.exe --provision-once"
fi

# ARM 4 — NEGATIVE CONTROL, structural: the non-Windows arm must return None,
# or Linux --init would refuse too and the fleet's own gate would stop.
none_arm=$(awk '/#\[cfg\(not\(target_os = "windows"\)\)\]/{f=1} f&&/^fn windows_host_lane_refusal/{g=1} g&&/None/{print "yes"; exit}' "$CODE")
[ "$none_arm" = "yes" ] && _ok "the not(windows) arm returns None (Linux keeps its lane)" \
                        || _fail "the not(windows) arm does not return None"

# ARM 5 — BEHAVIOURAL, msys only. The arms above are structural; this is the
# only one that RUNS the thing. It is skipped by NAME off Windows rather than
# silently, so a green run off-msys cannot be read as a behavioural pass.
case "$(uname -s)" in
  MINGW*|MSYS*)
    BIN=""
    # The bin is named `tillandsias`, NOT after its crate — and that name is the
    # defect's own subject: the operator ran tillandsias.exe because it sat beside
    # tillandsias-tray.exe and looked like the product. A fixture that probed for
    # tillandsias-headless.exe would skip forever on a host where the binary is
    # built and the arm would never run (measured here, first attempt).
    for c in target/release/tillandsias.exe target/debug/tillandsias.exe; do
        [ -f "$c" ] && BIN="$c" && break
    done
    if [ -z "$BIN" ]; then
        echo "skip: behavioural arm — no native tillandsias-headless.exe built at this locus"
    else
        out="$($BIN --init 2>&1)"; rc=$?
        if [ "$rc" -eq 0 ]; then
            _fail "BEHAVIOURAL: --init exited 0 on a Windows host; it must refuse"
        else
            _ok "BEHAVIOURAL: --init exited non-zero ($rc)"
        fi
        case "$out" in
            *refused:windows-host-lane*) _ok "BEHAVIOURAL: the refusal is printed" ;;
            *) _fail "BEHAVIOURAL: no refusal in output: $out" ;;
        esac
        case "$out" in
            *"tillandsias-tray.exe --provision-once"*) _ok "BEHAVIOURAL: the working command is named" ;;
            *) _fail "BEHAVIOURAL: the output does not name the tray command" ;;
        esac
        # The pre-fix signature was eight BUILD failures. Zero is the fix.
        builds=$(printf '%s\n' "$out" | grep -ciE 'building image|failed to spawn build' || true)
        [ "${builds:-0}" -eq 0 ] && _ok "BEHAVIOURAL: no image-build lines (pre-fix: eight)" \
                                 || _fail "BEHAVIOURAL: $builds image-build line(s) — the lane was entered"
    fi
    ;;
  *)
    echo "skip: behavioural arm — not an msys locus (the refusal is #[cfg(target_os = \"windows\")])"
    ;;
esac

[ "$fail" -eq 0 ] && echo "ok:windows-host-lane-refusal:all" || echo "FAIL:windows-host-lane-refusal"
exit "$fail"
