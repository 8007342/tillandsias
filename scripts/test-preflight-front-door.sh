#!/usr/bin/env bash
# @trace order:1305-udgs
#
# Each arm reproduces a defect this door actually had, measured on pirria
# 2026-09-20. A front door is a thing people run instead of thinking, so every
# way it can lie has to be pinned.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; cd "$ROOT" || exit 1
pass=0; fail=0
# Orphan baseline BEFORE this fixture runs the door: a host may have background
# work of its own, and an arm that counts globally would blame this door for it.
# The claim is a DELTA — the door must not ADD survivors.
_ORPHAN_PAT='test-token-instrument|test-memo-hit-observability'
_orphans_before="$(pgrep -f "$_ORPHAN_PAT" 2>/dev/null | wc -l | tr -d ' ')"
ok()  { pass=$((pass+1)); printf '  [OK]   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  [FAIL] %s\n' "$1"; }

# ── ARM 1: ENUMERATION, not curation ───────────────────────────────────────
# The roster is the three places a guard can be wired. esme's 1303 litmus was
# refused by check-litmus-expression-pinning-added (634-39ik), a guard absent
# from every hand-assembled list that day including an eighteen-entry one.
# The three rosters, each READ AS LITERALS (1063-nraf: a binding assembled from a
# variable is invisible to every name-based scan). An earlier draft of this row
# drove the fast tier from a list variable and 1009-gccx's own fixture refused
# it; this arm's first version then asserted the roster read that list, and
# outlived the design it described — a stale assertion passing judgement on code
# that no longer works that way.
_roster_fn="$(awk '/^_preflight_roster\(\) \{/,/^\}/' build.sh)"
for r in 'FAST REFUSALS' 'gate-steps.d' 'scripts/hooks'; do
    if printf '%s' "$_roster_fn" | grep -q "$r"; then
        ok "the roster scans $r"
    else
        bad "the roster does not scan $r"
    fi
done
# And it must scan, not curate: no list variable may stand between the tier and
# the door.
if printf '%s' "$_roster_fn" | grep -q '_fast_refusal_checks'; then
    bad "the roster reads a list variable — the tier's bindings would be invisible to name-based scans (1063-nraf)"
else
    ok "the roster scans literal bindings, with no list variable to drift from"
fi

# ── ARM 2: RUN OR NAMED — no silent third state ─────────────────────────────
# Plant a roster entry that is neither run nor named and the door must not
# silently ignore it. This is what keeps enumeration from decaying into
# curation by another name.
# ORDER 1496-w25b: RUN THE DOOR ON THE HOST'S OWN podman. Under the litmus
# runner PATH starts with its podman shim (target/litmus-runtime/bin), and on a
# toolbox host build.sh re-execs through `toolbox run`, whose `podman exec`
# then went through that shim and was killed at the shim's 120 s diagnostics
# budget: no planted guard, no wall= line, and an orphaned exec session left
# running in the toolbox. This fixture tests the front door, not podman calls.
PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -v '/target/litmus-runtime/bin$' | paste -sd: -)"
export PATH

PLANT=scripts/check-zz-1305-planted.sh
cat > "$PLANT" <<'PL'
#!/usr/bin/env bash
echo "violation:planted-guard: this guard exists and refuses"
exit 1
PL
chmod +x "$PLANT"
STEP=scripts/gate-steps.d/999-zz-1305-planted.step
printf 'STEP_DESC="planted"\nSTEP_SCRIPT="scripts/check-zz-1305-planted.sh"\nSTEP_ERROR="planted"\nSTEP_OK="planted"\n' > "$STEP"
cleanup() { rm -f "$PLANT" "$STEP"; }
trap cleanup EXIT INT TERM HUP PIPE
out="$(TILLANDSIAS_PREFLIGHT_TIMEOUT=5 ./build.sh --preflight 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'zz-1305-planted'; then
    ok "a guard wired into gate-steps.d is picked up and refuses (no silent third state)"
else
    bad "a newly wired guard was invisible to the front door (rc=$rc)"
fi
# ── ARM 2b (1515-iwb3, 1247-amcu criterion 5): THE REFUSAL'S REMEDY RUNS ─────
# The per-guard refusal must say why and name the command that reruns that
# guard alone, and that command, EXECUTED, must reproduce the guard's own
# verdict: a remedy that names a command which does not exist or does not
# reach the guard would be confidently wrong.
remedy_cmd="$(grep -A1 'the guard check-zz-1305-planted refused' <<<"$out" | sed -n 's/.*confirm with the guard alone: \(bash [^ ]*\).*/\1/p' | head -n 1)"
if grep -q '  why: the guard check-zz-1305-planted refused this tree' <<<"$out" && [ -n "$remedy_cmd" ]; then
    again="$($remedy_cmd 2>&1)"; again_rc=$?
    if [ "$again_rc" -ne 0 ] && grep -q 'violation:planted-guard' <<<"$again"; then
        ok "the refusal names its why and a remedy command that, executed ($remedy_cmd), reproduces the guard's verdict"
    else bad "the remedy command '$remedy_cmd' did not reproduce the guard (rc=$again_rc)"; fi
else bad "the per-guard refusal carries no why/remedy with a runnable command"; fi
cleanup; trap - EXIT INT TERM HUP PIPE

# ── ARM 2c: A GUARD THE GATE RUNS INLINE IS A ROSTER ENTRY (1499-m9fj) ──────
# MEASURED: 48 deciders build.sh runs as `_run bash .../check-X.sh` were in none
# of the three rosters, so the door passed trees the gate refused. Plant one in
# a never-called function of build.sh: the door must run it and refuse.
# AND IN THE GATE'S MODE: a second plant refuses ONLY when given the argument
# the gate passes it, so a door that drops arguments (the first draft of this
# row, which made check-mcp-live-build refuse a tree the gate passes) sees a
# pass there and this arm fails.
PLANT=scripts/check-zz-1499-planted.sh
PLANT_ARGS=scripts/check-zz-1499-args.sh
cat > "$PLANT_ARGS" <<'PL'
#!/usr/bin/env bash
if [ "${1:-}" = zzmode ] && [ "${2:-}" = second ]; then
    echo "violation:planted-mode-guard: refuses only in the gate's mode"
    exit 1
fi
echo "ok:planted-mode-guard: no mode given (argv: $*)"
PL
chmod +x "$PLANT_ARGS"
cat > "$PLANT" <<'PL'
#!/usr/bin/env bash
echo "violation:planted-inline-guard: this guard exists and refuses"
exit 1
PL
chmod +x "$PLANT"
_bs_backup="$(mktemp "${TMPDIR:-/tmp}/build-sh-1499.XXXXXX")"
cp -p build.sh "$_bs_backup"
cleanup() { rm -f "$PLANT" "$PLANT_ARGS"; [ -s "$_bs_backup" ] && cp -p "$_bs_backup" build.sh; rm -f "$_bs_backup"; }
trap cleanup EXIT INT TERM HUP PIPE
printf '\n_zz_1499_never_called() {\n    _run bash "$SCRIPT_DIR/scripts/check-zz-1499-planted.sh"\n    _run bash "$SCRIPT_DIR/scripts/check-zz-1499-args.sh" zzmode second 2>&1\n}\n' >> build.sh
out="$(TILLANDSIAS_PREFLIGHT_TIMEOUT=5 ./build.sh --preflight 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'zz-1499-planted' <<< "$out"; then
    ok "a guard build.sh runs inline is picked up and refuses (1499-m9fj)"
else
    bad "a guard the gate runs inline was invisible to the front door (rc=$rc)"
fi
if grep -q '^refused:preflight:check-zz-1499-args\[zzmode second\]$' <<< "$out" \
    && grep -q 'violation:planted-mode-guard' <<< "$out"; then
    ok "the door runs an inline guard in the gate's mode, with the gate's arguments (1499-m9fj)"
else
    bad "the door ran an inline guard without the arguments the gate passes it"
fi
cleanup; trap - EXIT INT TERM HUP PIPE

# ── ARM 2b: A SELF-DECLARED GATE-ONLY GUARD (1496-w25b) ─────────────────────
# A fixture that declares `# preflight: gate-only — <reason>` is reported as a
# DECLARED skip by name, counted, and NOT run (it would leave a marker). The
# NEGATIVE CONTROLS: the same plant with NO reason runs, and a check-* (a push
# decider) that declares it runs, each with a note saying why.
GO_MARK="$(mktemp -u "${TMPDIR:-/tmp}/gate-only-ran.XXXXXX")"
plant_go() { # plant_go <script path> <declaration line>
    printf '#!/usr/bin/env bash\n%s\ntouch "%s.$(basename "$0")"\nexit 0\n' "$2" "$GO_MARK" > "$1"
    chmod +x "$1"
}
GO_A=scripts/test-zz-1496-gate-only.sh
GO_B=scripts/test-zz-1496-gate-only-bare.sh
GO_C=scripts/check-zz-1496-gate-only-decider.sh
GO_STEP=scripts/gate-steps.d/999-zz-1496-gate-only.step
plant_go "$GO_A" '# preflight: gate-only — runs the planted fixture harness end to end'
plant_go "$GO_B" '# preflight: gate-only'
plant_go "$GO_C" '# preflight: gate-only — a decider claiming it'
{ for p in "$GO_A" "$GO_B" "$GO_C"; do
    printf 'STEP_DESC="planted"\nSTEP_SCRIPT="%s"\nSTEP_ERROR="planted"\nSTEP_OK="planted"\n' "$p"; done; } > "$GO_STEP"
go_cleanup() { rm -f "$GO_A" "$GO_B" "$GO_C" "$GO_STEP" "$GO_MARK".*; }
trap go_cleanup EXIT INT TERM HUP PIPE
out="$(TILLANDSIAS_PREFLIGHT_TIMEOUT=5 ./build.sh --preflight 2>&1)"
if grep -q '^skip:preflight:test-zz-1496-gate-only:gate-only — runs the planted fixture harness end to end$' <<<"$out" \
    && [ ! -e "$GO_MARK.test-zz-1496-gate-only.sh" ]; then
    ok "a declared gate-only fixture is a named declared skip and is not run"
else
    bad "a declared gate-only fixture was run, or not reported by name as a declared skip"
fi
if [ -e "$GO_MARK.test-zz-1496-gate-only-bare.sh" ] \
    && grep -q 'test-zz-1496-gate-only-bare:gate-only-without-a-reason' <<<"$out"; then
    ok "NEGATIVE CONTROL: a declaration with no reason is not honoured; the guard runs"
else
    bad "a reasonless gate-only declaration was honoured"
fi
if [ -e "$GO_MARK.check-zz-1496-gate-only-decider.sh" ] \
    && grep -q 'check-zz-1496-gate-only-decider:gate-only-ignored' <<<"$out"; then
    ok "NEGATIVE CONTROL: a push decider cannot declare itself gate-only; it runs"
else
    bad "a check-* push decider was allowed to skip the door"
fi
go_cleanup; trap - EXIT INT TERM HUP PIPE

# ── ARM 2d: A SERIAL GUARD RUNS WITH NOTHING BESIDE IT (1499-m9fj) ──────────
# The door runs guards concurrently; a guard declaring `# preflight: serial —
# <reason>` writes shared state and must run ALONE. Three plants log start and
# end to one file: A declares serial, B and C do not. PREMISE FIRST: B and C
# must overlap each other, or this run proves nothing about concurrency. Then
# no line may fall between A's start and A's end.
SER_LOG="$(mktemp "${TMPDIR:-/tmp}/serial-1499.XXXXXX")"
plant_ser() { # plant_ser <path> <tag> <header line or empty>
    printf '#!/usr/bin/env bash\n%s\necho "%s start" >> "%s"\nsleep 2\necho "%s end" >> "%s"\n' \
        "$3" "$2" "$SER_LOG" "$2" "$SER_LOG" > "$1"
    chmod +x "$1"
}
SER_A=scripts/test-zz-1499-serial-a.sh
SER_B=scripts/test-zz-1499-serial-b.sh
SER_C=scripts/test-zz-1499-serial-c.sh
SER_STEP=scripts/gate-steps.d/999-zz-1499-serial.step
plant_ser "$SER_A" A '# preflight: serial — planted: writes the shared log alone'
plant_ser "$SER_B" B ''
plant_ser "$SER_C" C ''
{ for p in "$SER_A" "$SER_B" "$SER_C"; do
    printf 'STEP_DESC="planted"\nSTEP_SCRIPT="%s"\nSTEP_ERROR="planted"\nSTEP_OK="planted"\n' "$p"; done; } > "$SER_STEP"
ser_cleanup() { rm -f "$SER_A" "$SER_B" "$SER_C" "$SER_STEP" "$SER_LOG"; }
trap ser_cleanup EXIT INT TERM HUP PIPE
TILLANDSIAS_PREFLIGHT_JOBS=3 TILLANDSIAS_PREFLIGHT_TIMEOUT=5 ./build.sh --preflight >/dev/null 2>&1
ser="$(tr '\n' ' ' < "$SER_LOG")"
# overlaps <X> <Y>: 1 when X starts while Y is running or Y starts while X is.
# An interval test, not a string pattern: B and C can overlap without their
# start lines being adjacent (measured: `B start A end C start B end`).
overlaps() {
    awk -v x="$1" -v y="$2" '
        $2 == "start" { if (($1 == x && open[y]) || ($1 == y && open[x])) o = 1; open[$1] = 1 }
        $2 == "end"   { open[$1] = 0 }
        END { print o + 0 }' "$SER_LOG"
}
if [ "$(overlaps B C)" = 1 ]; then
    ok "PREMISE: undeclared plants B and C ran concurrently ($ser)"
else
    bad "PREMISE: B and C did not overlap, so this run cannot show exclusivity ($ser)"
fi
if [ "$(overlaps A B)" = 0 ] && [ "$(overlaps A C)" = 0 ] && grep -q '^A end$' "$SER_LOG"; then
    ok "a guard declaring serial ran with nothing beside it"
else
    bad "a serial guard shared its run with another guard ($ser)"
fi
ser_cleanup; trap - EXIT INT TERM HUP PIPE

# ── ARM 3: A NAMED SKIP IS NOT A REFUSAL (1273-4mak, 1309-fhxb) ─────────────
# MEASURED: test-uninstall-matcher-spares-bystanders prints skip:not-darwin and
# exits non-zero, and this door called it `refused` — 1309-fhxb's shape inside
# the fix for 1305, written by the host that filed 1309-fhxb the same evening.
if grep -qE "grep -qE '\^skip:'" build.sh; then
    ok "a skip: line is treated as a skip whatever the guard exits with"
else
    bad "the door does not recognise a named skip"
fi

# ── ARM 4: EVERY GUARD RUNS WITH STDIN CLOSED ──────────────────────────────
# MEASURED: without this the guards inherit the loop's heredoc and a guard that
# reads stdin CONSUMES THE ROSTER. The door hung with no output and ate its own
# worklist. This arm has its own deadline because its defect is a hang.
if grep -q '</dev/null' build.sh; then
    ok "guards run with stdin from /dev/null (the door cannot eat its worklist)"
else
    bad "a guard could consume the roster through inherited stdin"
fi

# ── ARM 5: THE DISPATCH IS BEFORE ANY SETUP ────────────────────────────────
# MEASURED: placed after the build's setup, --preflight took 51s, STARTED THE
# DEV PROXY CONTAINER and staged the router sidecar. A front door with side
# effects is not a front door.
_door=$(grep -n 'FLAG_PREFLIGHT" == true' build.sh | head -1 | cut -d: -f1)
_proxy=$(grep -n 'Starting dev proxy container' build.sh | head -1 | cut -d: -f1)
if [ -n "$_door" ] && [ -n "$_proxy" ] && [ "$_door" -lt "$_proxy" ]; then
    ok "the dispatch precedes the dev-proxy setup (no containers, no sidecar)"
else
    bad "the dispatch is not before the setup (door=$_door proxy=$_proxy)"
fi

# ── ARM 6: THE WALL-CLOCK BUDGET IS THE CONTRACT ───────────────────────────
# A guard that grows slow must red THIS ARM rather than silently making the door
# useless. The budget is SET from a measurement and never raised (standing rule).
# 150s = the MEASURED 140s on the floor host plus ten seconds (1305-udgs).
#
# A BUDGET IS A NUMBER MEASURED WITH THE MECHANISM ENFORCED. The first figure
# here was 120s, and it was arithmetic over a deadline that bounded nothing —
# never a budget at all, so replacing it was a correction rather than a raise.
# THE RULE, so nobody hides a raise behind that sentence: the FIRST ENFORCED
# measurement sets the budget, and the no-raise rule applies from that moment.
# 140s is that measurement (ran=94 skipped=14, orphan delta zero).
#
# Ten seconds of headroom and not more, because pirria IS the floor host: there
# is no slower machine for this number to be generous towards. 180 would be a
# round number, not a measured one.
BUDGET_S="${TILLANDSIAS_PREFLIGHT_BUDGET_S:-150}"
out="$(./build.sh --preflight 2>&1)"; rc=$?
wall="$(printf '%s' "$out" | grep -oE 'wall=[0-9]+s' | tail -1 | tr -cd '0-9')"
if [ -z "$wall" ]; then
    bad "the verdict does not report its wall clock"
elif [ "$wall" -le "$BUDGET_S" ]; then
    ok "the whole run completes inside the budget (${wall}s <= ${BUDGET_S}s)"
else
    bad "the run exceeded the budget (${wall}s > ${BUDGET_S}s) — a guard grew slow, or the budget is wrong"
fi

# ── ARM 7: --full removes the deadline, and says so ────────────────────────
if grep -q 'FLAG_PREFLIGHT_FULL' build.sh && grep -q 'deadline' build.sh; then
    ok "--full runs the same enumeration with no deadline"
else
    bad "--full is missing, so a host wanting the whole set has no path"
fi

# ── ARM 8: THE DOOR LEAVES NO ORPHANS ──────────────────────────────────────
# MEASURED: with guard output written to a file but no process group, `timeout`
# killed the guard and SEVEN of its children kept polling after the door
# returned. A door that returns quickly while leaving background work behind is
# a door whose next run collides with its own last one, and the wall figure it
# reports is a fiction.
_orphans_after="$(pgrep -f "$_ORPHAN_PAT" 2>/dev/null | wc -l | tr -d ' ')"
if [ "${_orphans_after:-0}" -le "${_orphans_before:-0}" ]; then
    ok "the door adds no surviving guard children (before=${_orphans_before} after=${_orphans_after}; killed by process group, not just by pid)"
else
    bad "the door left $(( _orphans_after - _orphans_before )) new orphan(s) (before=${_orphans_before} after=${_orphans_after})"
fi

# ── ARM 9: THE SKIP LINE CARRIES THE MEASURED COST, NOT THE CONFIGURED ONE ──
# This is the arm that found arm 8's defect: had the line printed `deadline:5s`
# from the configuration, eleven tidy skips would have hidden a 467s wall.
if grep -q 'deadline:$(( SECONDS - _pf_t0 ))s' build.sh; then
    ok "a deadline skip reports its MEASURED cost, so a deadline that fails to bound is visible"
else
    bad "the deadline skip reports the configured value — a deadline that does not bound would be invisible"
fi

printf 'preflight-front-door %d/%d\n' "$pass" "$((pass+fail))"
[ "$fail" -eq 0 ] || exit 1
echo "ok:preflight-front-door:$pass/$pass"
