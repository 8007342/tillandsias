#!/usr/bin/env bash
# @trace order:1176-fn2p
# @trace order:1047-h88p (the job ceiling whose lowest rung is one job)
#
# REGIME: hermetic. Every arm feeds the two probes through their seams
# (--meminfo-from, --journal-from, --floor-mb) and reads build.sh and
# land-on-platform-branch.sh as TEXT. Nothing here provokes an OOM, runs a gate,
# or reads this host's real memory except in the one arm that says it does and
# asserts only that the host is ABOVE the floor. An OOM cannot be provoked on
# demand and the host that had one (lenovinha) is not this one, so stubs are the
# only honest construction for the positive case.
#
# NO ABSOLUTE TIMESTAMP IS ENCODED HERE. The stub journal line carries a date
# because kernel log lines do; no arm compares it against now, and the probes
# take their window as a relative --since.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

FLOOR="$ROOT/scripts/check-gate-memory-floor.sh"
OOM="$ROOT/scripts/check-oom-postmortem.sh"
for f in "$FLOOR" "$OOM"; do
    [ -x "$f" ] || { echo "could-not-run:gate-memory-refusal:missing:$f"; exit 3; }
done

W="$(mktemp -d "${TMPDIR:-/tmp}/gate-mem-refusal.XXXXXX")" || exit 3
trap 'rm -rf "$W"' EXIT

pass=0; fail=0
ok()  { printf 'ok:   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail+1)); }

printf 'MemTotal:       15490628 kB\nMemAvailable:     131072 kB\n' > "$W/starved"
printf 'MemTotal:       15490628 kB\nMemAvailable:   11979624 kB\n' > "$W/healthy"
printf 'MemTotal:       15490628 kB\nMemFree:          131072 kB\n' > "$W/no-memavailable"
printf 'sep 14 01:02:03 h kernel: Out of memory: Killed process 4123 (rustc) total-vm:9000000kB\n' > "$W/journal-oom"
printf 'sep 14 01:02:03 h kernel: usb 1-2: new high-speed USB device\n' > "$W/journal-quiet"

# ── 1. below the floor: refuse BY NAME, naming the floor and the reading ────
out="$("$FLOOR" --meminfo-from "$W/starved" 2>/dev/null)"; rc=$?
if [ "$rc" = "1" ] && case "$out" in *refused:gate:insufficient-memory*) true ;; *) false ;; esac; then
    case "$out" in
        *128MB*|*"floor 1024MB"*) ok "a host below the floor refuses by name, naming the floor and the reading" ;;
        *) bad "refused, but without the numbers a reader needs: $out" ;;
    esac
else
    bad "a starved host did not refuse by name (rc=$rc): $out"
fi

# ── 2. NEGATIVE CONTROL 1: a host ABOVE the floor sees no new refusal ───────
#    The floor must not become a second cliff. This is the arm that fails if
#    someone "tightens" the default into refusing hosts that would have finished.
out="$("$FLOOR" --meminfo-from "$W/healthy" 2>/dev/null)"; rc=$?
if [ "$rc" = "0" ] && case "$out" in ok:gate-memory:*) true ;; *) false ;; esac; then
    ok "NC1: a host above the floor is unaffected — no new refusal appears"
else
    bad "NC1: a healthy host was refused or mis-reported (rc=$rc): $out — the floor has become a second cliff"
fi

# ── 3. the default floor is far below a host known to COMPLETE this gate ────
#    Same control, stated as the property rather than as one reading: yoga
#    completes with 11-12 GiB available, so a default anywhere near that would
#    refuse a working host. Measured against the shipped default, not a literal.
avail_mb=$(( $(sed -n 's/^MemAvailable:[[:space:]]*\([0-9]*\).*/\1/p' "$W/healthy") / 1024 ))
default_floor="$(TILLANDSIAS_GATE_MEMORY_FLOOR_MB= "$FLOOR" --meminfo-from "$W/healthy" 2>/dev/null | sed -n 's/.*floor \([0-9]*\)MB.*/\1/p')"
if [ -n "$default_floor" ] && [ "$default_floor" -le $(( avail_mb / 4 )) ]; then
    ok "the default floor (${default_floor}MB) is well under a completing host's headroom (${avail_mb}MB)"
else
    bad "the default floor ${default_floor}MB is not comfortably below a completing host's ${avail_mb}MB — it risks refusing hosts that would finish"
fi

# ── 4. could-not-run is NOT a refusal and NOT a pass ────────────────────────
out="$("$FLOOR" --meminfo-from "$W/no-memavailable" 2>/dev/null)"; rc=$?
if [ "$rc" = "3" ] && case "$out" in *could-not-run:gate-memory:no-memavailable*) true ;; *) false ;; esac; then
    ok "a meminfo without MemAvailable is could-not-run, not a verdict (MemFree would under-report)"
else
    bad "a meminfo without MemAvailable did not route to could-not-run (rc=$rc): $out"
fi

# ── 5. the OOM post-mortem reports a kill the kernel recorded ──────────────
out="$("$OOM" --journal-from "$W/journal-oom" --victim rustc 2>/dev/null)"; rc=$?
if [ "$rc" = "1" ] && case "$out" in *refused:gate:oom-killed*) true ;; *) false ;; esac; then
    ok "a kernel OOM record yields refused:gate:oom-killed"
else
    bad "an OOM record did not produce the verdict (rc=$rc): $out"
fi

# ── 6. NEGATIVE CONTROL 2: an unrelated victim must NOT be laundered ───────
#    An OOM elsewhere on the host is not this gate's OOM. Without the victim
#    narrowing, any kill in the window would convert an ordinary failure into
#    refused:gate:oom-killed — which is exactly the laundering 1176-fn2p forbids.
out="$("$OOM" --journal-from "$W/journal-oom" --victim some-other-process 2>/dev/null)"; rc=$?
if [ "$rc" = "0" ]; then
    ok "NC2: an OOM naming a different victim is NOT reported as this gate's kill"
else
    bad "NC2: an unrelated OOM was laundered into this gate's verdict (rc=$rc): $out"
fi

# ── 7. a quiet journal is a clean answer, an unreadable one is not ─────────
out="$("$OOM" --journal-from "$W/journal-quiet" 2>/dev/null)"; rc=$?
[ "$rc" = "0" ] && ok "a readable, quiet journal answers ok:no-oom-record" \
                || bad "a quiet journal did not answer cleanly (rc=$rc): $out"
out="$("$OOM" --journal-from "$W/does-not-exist" 2>/dev/null)"; rc=$?
if [ "$rc" = "3" ]; then
    ok "an unreadable journal is could-not-run — never a confident not-OOM"
else
    bad "an unreadable journal did not route to could-not-run (rc=$rc): $out"
fi

# ── 8. WIRED: the floor runs before the first compile, and _run asks ───────
#    Structural, and labelled: this fixture cannot run ./build.sh. What it can
#    refuse is either half existing with nothing calling it.
_floor_line="$(/usr/bin/grep -n 'check-gate-memory-floor.sh' build.sh | head -1 | cut -d: -f1)"
_clippy_line="$(/usr/bin/grep -n 'cargo clippy' build.sh | head -1 | cut -d: -f1)"
if [ -z "$_floor_line" ]; then
    bad "build.sh never calls the memory floor — the refusal exists and nothing reaches it"
elif [ -n "$_clippy_line" ] && [ "$_floor_line" -lt "$_clippy_line" ]; then
    ok "the memory floor is checked before the first compile, where it can still save the run"
else
    bad "the memory floor runs at or after the first compile (floor:$_floor_line clippy:$_clippy_line) — too late to prevent the kill"
fi
if /usr/bin/grep -q 'check-oom-postmortem.sh' build.sh; then
    ok "build.sh consults the OOM record when a child dies on a signal"
else
    bad "build.sh never consults the OOM record — a SIGKILLed child still stops silently"
fi
if /usr/bin/grep -q 'check-oom-postmortem.sh' scripts/land-on-platform-branch.sh; then
    ok "the land driver consults the OOM record when the gate produced no verdict"
else
    bad "the land driver still cannot tell a died gate from a refused one"
fi

# ── 9. NC2, STRUCTURALLY: the driver asks ONLY when no failure line matched ─
#    Position is what stops the verdict laundering an ordinary failure, so the
#    position is asserted rather than trusted.
# BY LINE ORDER, not by a text range. The first cut ranged from the sentence
# "no violation/refusal line matched" to the next `fi`, and that sentence now
# lives in one of the case arms BELOW the consult — so the range started after
# the thing it was looking for and reported the consult missing. A matcher that
# anchors on text the change itself moved is measuring its own edit.
_if_line="$(/usr/bin/grep -n 'if \[ -n "\$_first_fail" \]; then' scripts/land-on-platform-branch.sh | head -1 | cut -d: -f1)"
_else_line="$(awk -v s="${_if_line:-0}" 'NR>s && /^        else$/ {print NR; exit}' scripts/land-on-platform-branch.sh)"
_oom_line="$(/usr/bin/grep -n 'check-oom-postmortem.sh' scripts/land-on-platform-branch.sh | head -1 | cut -d: -f1)"
_drv=""
[ -n "$_if_line" ] && [ -n "$_else_line" ] && [ -n "$_oom_line" ] && _drv="located"
if [ -z "$_drv" ]; then
    bad "could not locate the land driver's no-match branch (if:$_if_line else:$_else_line oom:$_oom_line) — arm 9 asserted nothing"
elif [ "$_oom_line" -gt "$_else_line" ]; then
    ok "NC2 structurally: the driver consults the OOM record only on the no-failing-line path"
else
    bad "the OOM consult is not inside the no-match branch — it could fire on an ordinary gate failure"
fi

total=$((pass+fail))
if [ "$fail" -eq 0 ]; then
    echo "PASS: gate memory refusal and OOM post-mortem $pass/$total (1176-fn2p)"
    exit 0
fi
echo "FAIL: gate memory refusal and OOM post-mortem $pass/$total (1176-fn2p)"
exit 1
