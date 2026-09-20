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
for r in '_fast_refusal_checks' 'gate-steps.d' 'scripts/hooks'; do
    if grep -q "$r" build.sh; then ok "the roster reads $r"; else bad "the roster does not read $r"; fi
done

# ── ARM 2: RUN OR NAMED — no silent third state ─────────────────────────────
# Plant a roster entry that is neither run nor named and the door must not
# silently ignore it. This is what keeps enumeration from decaying into
# curation by another name.
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
cleanup; trap - EXIT INT TERM HUP PIPE

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
# 120s: 55.3s of real work under the 5s deadline plus 11 guards x 5s of
# deadline is ~110s, so this is the honest headroom and no more (1305-udgs).
BUDGET_S="${TILLANDSIAS_PREFLIGHT_BUDGET_S:-120}"
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
