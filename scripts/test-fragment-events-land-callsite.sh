#!/usr/bin/env bash
# ORDER 1021-a944. A gate that could not RUN a check must never assert what the
# check would have FOUND.
#
# Measured by esme-windows on the floor: scripts/check-fragment-events-land.sh
# exits 2 with `blocked:fragment-events-land:no-fresh-plan-binary` when
# ensure_fresh_plan_binary cannot produce a binary current for this tree, and
# build.sh's `if ! _run ...` collapsed that into the violation arm — printing
# "an event is attached to no packet — invisible, not merely unfolded" on a run
# where not one fragment was read. The agent it stopped then went looking for a
# broken fragment that did not exist. This is 965-sxec's shape on a second call
# site: the could-not-run channel existed and the routing never reached it.
#
# ORDER 1631-6w8z: the decider is now scripts/lua/check-fragment-events-land.lua,
# run INSIDE a tillandsias-plan. A stale binary cannot judge its own currency,
# so the call site runs ensure_fresh_plan_binary BEFORE invoking any plan
# binary and hands the fresh one in. ARM 5 pins that order with stubs, and
# ARM 6 with the REAL probe library over a stale binary and no cargo, against
# both the ported call site and the pre-port .sh (read from history).
#
# HOW THIS DRIVES THE CALL SITE. The routing under test is EXTRACTED FROM
# build.sh AT RUN TIME and executed here against stubs. It is not a copy:
# a copy is how two implementations come to disagree, which is the failure this
# repo keeps paying for (704-zcgi's four probes, 805-r98w's two fingerprints).
# If someone edits the branch in build.sh, this fixture runs the edited branch.
# If they delete or rename it, the extraction finds nothing and the fixture
# fails loudly rather than passing over an empty window — the anchor trap.
#
# Prints one PASS/FAIL summary line and exits 0/1.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)" || exit 1
cd "$ROOT" || exit 1

pass=0
fail=0
ok()  { echo "ok   $*"; pass=$((pass + 1)); }
bad() { echo "FAIL $*"; fail=$((fail + 1)); }

work="$(mktemp -d "${TMPDIR:-/tmp}/fel-callsite.XXXXXX")"
trap 'rm -rf "$work"' EXIT INT TERM

# ---- extract the branch from build.sh -------------------------------------
# From the _step line to the _info that closes it. Both are load-bearing
# anchors; if either moves, the window empties and ARM 0 says so.
awk '/_step "Checking every fragment event lands on a real packet/{f=1}
     f{print}
     f && /_info "All fragment events land"/{exit}' build.sh > "$work/branch.sh"

if [ ! -s "$work/branch.sh" ] || ! grep -q 'check-fragment-events-land.lua' "$work/branch.sh"; then
    bad "could not extract the call site from build.sh — the anchors moved; this fixture is measuring nothing"
    echo "FAIL: fragment-events-land call site ${pass} passed, ${fail} failed (1021-a944)"
    exit 1
fi
ok "extracted the live call site from build.sh (not a copy of it)"

# ---- harness: the build.sh helpers the branch calls ------------------------
# _run_lua_decider is stubbed: it records that it was invoked, and with which
# TILLANDSIAS_PLAN_BIN, then prints STUB_LINE and returns STUB_RC.
cat > "$work/harness.sh" <<'HARNESS'
SCRIPT_DIR="$STUB_DIR"
_step() { :; }
_info() { echo "INFO $*"; }
_warn() { echo "WARN $*"; }
_error() { echo "ERROR $*"; }
_afford() { echo "AFFORD $*"; }
_run() { "$@"; }
_run_lua_decider() {
    echo "invoked $1 plan-bin=${TILLANDSIAS_PLAN_BIN:-}" >> "$STUB_DIR/invoked"
    echo "$STUB_LINE"
    return "$STUB_RC"
}
HARNESS
cat > "$work/drive.sh" <<'DRIVE'
. "$1"
. "$2"
DRIVE

stub_probe() {   # $1 = ok|fail
    mkdir -p "$work/stub/scripts"
    rm -f "$work/stub/invoked"
    if [ "$1" = ok ]; then
        printf 'ensure_fresh_plan_binary() { echo /stub/fresh-plan; }\n' > "$work/stub/scripts/plan-binary-probe.sh"
    else
        printf 'ensure_fresh_plan_binary() { return 2; }\n' > "$work/stub/scripts/plan-binary-probe.sh"
    fi
}
drive() {   # $1 = exit code the decider returns, $2 = stdout line it prints
    stub_probe ok
    STUB_DIR="$work/stub" STUB_RC="$1" STUB_LINE="$2" \
        bash "$work/drive.sh" "$work/harness.sh" "$work/branch.sh" 2>&1
}

# ---- ARM 1: exit 2 is could-not-run, and says so --------------------------
out2="$(drive 2 'could-not-run:fragment-events-land:compact-did-not-run')"
if grep -q 'COULD NOT RUN' <<<"$out2"; then
    ok "exit 2 -> named as could-not-run"
else
    bad "exit 2 -> not named as could-not-run; got: $out2"
fi

# THE DEFECT ITSELF. The exit-2 run must NOT claim anything about the ledger.
if grep -q 'an event is attached to no packet' <<<"$out2"; then
    bad "exit 2 still claims 'an event is attached to no packet' — the 1021-a944 defect"
else
    ok "exit 2 makes NO substantive claim about the ledger"
fi

# The decider's own verdict line must be surfaced, not paraphrased away.
if grep -q 'compact-did-not-run' <<<"$out2"; then
    ok "exit 2 surfaces the decider's own verdict line"
else
    bad "exit 2 hides which could-not-run cause fired; got: $out2"
fi

# And the remedy has to be actionable in the locus that hit it.
if grep -q 'cycle-preflight' <<<"$out2"; then
    ok "exit 2 names the cycle-preflight remedy"
else
    bad "exit 2 gives the operator no remedy; got: $out2"
fi

# exit 3 is _run_lua_decider's own could-not-run (no script runner)
out3="$(drive 3 'could-not-run:lua-decider:check-fragment-events-land.lua:no-script-runner')"
if grep -q 'COULD NOT RUN' <<<"$out3" && ! grep -q 'an event is attached to no packet' <<<"$out3"; then
    ok "exit 3 (no script runner) -> could-not-run, no ledger claim"
else
    bad "exit 3 (no script runner) was not routed to could-not-run; got: $out3"
fi

# ---- ARM 2: exit 1 is still the substantive violation ---------------------
# The negative control for ARM 1: a fix that simply stopped claiming anything
# would pass every assertion above and destroy the check. This is the arm that
# forbids that.
out1="$(drive 1 'blocked:fragment-events-land:2 event(s) attached to no packet')"
if grep -q 'an event is attached to no packet' <<<"$out1"; then
    ok "exit 1 still reports the substantive violation"
else
    bad "exit 1 no longer reports the violation — the check has been hollowed out; got: $out1"
fi
if grep -q 'COULD NOT RUN' <<<"$out1"; then
    bad "exit 1 mislabelled as could-not-run — the two arms are swapped"
else
    ok "exit 1 is NOT labelled could-not-run"
fi

# ---- ARM 3: exit 0 passes -------------------------------------------------
out0="$(drive 0 'ok:fragment-events-land:12 fragment(s) checked')"
if grep -q 'All fragment events land' <<<"$out0"; then
    ok "exit 0 -> passes"
else
    bad "exit 0 no longer passes; got: $out0"
fi

# ---- ARM 4: the real decider really does reach its could-not-run ----------
# Stubs prove the ROUTING. This proves the routing has a real caller: run with
# no runner handed in, the .lua reaches exit 2 with its documented verdict.
_plan="$(. scripts/plan-binary-probe.sh && resolve_plan_binary 2>/dev/null)" || _plan=""
if [ -z "$_plan" ]; then
    bad "no tillandsias-plan resolves, so the real decider could not be run (cargo build --release -p tillandsias-plan)"
else
    real_out="$(env -u TILLANDSIAS_SCRIPT_RUNNER_BIN "$_plan" script run scripts/lua/check-fragment-events-land.lua 2>&1)"
    real_rc=$?
    if [ "$real_rc" -eq 2 ] && grep -q 'could-not-run:fragment-events-land:no-plan-binary' <<<"$real_out"; then
        ok "the real decider reaches exit 2 with its documented verdict"
    else
        bad "the real decider did not produce exit 2 / no-plan-binary (rc=$real_rc, out=$real_out)"
    fi
fi

# ---- ARM 5: freshness is decided BEFORE any plan binary runs (1631-6w8z) --
stub_probe fail
out5="$(STUB_DIR="$work/stub" STUB_RC=0 STUB_LINE='ok:fragment-events-land:1 fragment(s) checked' \
    bash "$work/drive.sh" "$work/harness.sh" "$work/branch.sh" 2>&1)"
if grep -q 'COULD NOT RUN' <<<"$out5" && grep -q 'no-fresh-plan-binary' <<<"$out5" \
   && [ ! -f "$work/stub/invoked" ]; then
    ok "no fresh plan binary -> could-not-run, and the decider was never invoked"
else
    bad "a stale or absent plan binary reached the decider, or was not named (invoked=$(cat "$work/stub/invoked" 2>/dev/null)); got: $out5"
fi
out5b="$(drive 0 'ok:fragment-events-land:1 fragment(s) checked')"
if grep -q 'plan-bin=/stub/fresh-plan' "$work/stub/invoked" 2>/dev/null; then
    ok "the decider is handed the binary ensure_fresh_plan_binary produced"
else
    bad "the decider was not handed the fresh binary (invoked=$(cat "$work/stub/invoked" 2>/dev/null)); got: $out5b"
fi

# ---- ARM 6: a REAL stale binary, pre-port and post-port --------------------
# A scratch root with the real probe library, a runnable plan binary OLDER than
# a crates/tillandsias-plan source, and no cargo on PATH, so it can be neither
# trusted nor rebuilt. Both the pre-port .sh and the ported call site must say
# could-not-run; the ported one must not invoke the decider.
stale="$work/stale"
mkdir -p "$stale/scripts" "$stale/target/release" "$stale/crates/tillandsias-plan/src"
cp scripts/plan-binary-probe.sh "$stale/scripts/"
printf '#!/bin/sh\nexit 0\n' > "$stale/target/release/tillandsias-plan"
chmod +x "$stale/target/release/tillandsias-plan"
touch -t 200001010000 "$stale/target/release/tillandsias-plan"
printf 'fn main() {}\n' > "$stale/crates/tillandsias-plan/src/main.rs"
: > "$stale/Cargo.lock"
_pre_ref=HEAD
if ! git cat-file -e "HEAD:scripts/check-fragment-events-land.sh" 2>/dev/null; then
    _pre_ref="$(git rev-list -1 HEAD -- scripts/check-fragment-events-land.sh)^"
fi
if git show "$_pre_ref:scripts/check-fragment-events-land.sh" > "$stale/scripts/check-fragment-events-land.sh" 2>/dev/null \
   && [ -s "$stale/scripts/check-fragment-events-land.sh" ]; then
    pre_out="$(cd "$stale" && env -u TILLANDSIAS_PLAN_BIN -u CARGO_TARGET_DIR PATH=/usr/bin:/bin \
        bash scripts/check-fragment-events-land.sh 2>&1)"
    pre_rc=$?
    if [ "$pre_rc" -eq 2 ] && grep -q 'no-fresh-plan-binary' <<<"$pre_out"; then
        ok "pre-port: the .sh refuses a stale binary it cannot rebuild (exit 2, no-fresh-plan-binary)"
    else
        bad "pre-port: the .sh did not refuse the stale binary (rc=$pre_rc, out=$pre_out)"
    fi
else
    bad "could not read the pre-port .sh from history ($_pre_ref)"
fi
rm -f "$stale/invoked"
post_out="$(cd "$stale" && env -u TILLANDSIAS_PLAN_BIN -u CARGO_TARGET_DIR PATH=/usr/bin:/bin \
    STUB_DIR="$stale" STUB_RC=0 STUB_LINE='ok:fragment-events-land:1 fragment(s) checked' \
    /bin/bash "$work/drive.sh" "$work/harness.sh" "$work/branch.sh" 2>&1)"
if grep -q 'COULD NOT RUN' <<<"$post_out" && grep -q 'no-fresh-plan-binary' <<<"$post_out" \
   && [ ! -f "$stale/invoked" ]; then
    ok "post-port: the call site refuses the same stale binary before invoking the decider"
else
    bad "post-port: the stale binary was not refused, or reached the decider (invoked=$(cat "$stale/invoked" 2>/dev/null)); got: $post_out"
fi

if [ "$fail" -eq 0 ]; then
    echo "PASS: fragment-events-land call site ${pass}/${pass} (1021-a944, 1631-6w8z)"
    exit 0
fi
echo "FAIL: fragment-events-land call site ${pass} passed, ${fail} failed (1021-a944, 1631-6w8z)"
exit 1
