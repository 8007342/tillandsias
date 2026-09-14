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
# HOW THIS DRIVES THE CALL SITE. The routing under test is EXTRACTED FROM
# build.sh AT RUN TIME and executed here against stub scripts. It is not a copy:
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

if [ ! -s "$work/branch.sh" ] || ! grep -q 'check-fragment-events-land.sh' "$work/branch.sh"; then
    bad "could not extract the call site from build.sh — the anchors moved; this fixture is measuring nothing"
    echo "FAIL: fragment-events-land call site ${pass} passed, ${fail} failed (1021-a944)"
    exit 1
fi
ok "extracted the live call site from build.sh (not a copy of it)"

# ---- harness: the build.sh helpers the branch calls ------------------------
cat > "$work/harness.sh" <<'HARNESS'
SCRIPT_DIR="$STUB_DIR"
_step() { :; }
_info() { echo "INFO $*"; }
_warn() { echo "WARN $*"; }
_error() { echo "ERROR $*"; }
_run() { "$@"; }
HARNESS

drive() {   # $1 = exit code the stub returns, $2 = stdout line it prints
    local rc="$1" line="$2"
    mkdir -p "$work/stub/scripts"
    printf '#!/usr/bin/env bash\necho "%s"\nexit %s\n' "$line" "$rc" \
        > "$work/stub/scripts/check-fragment-events-land.sh"
    chmod +x "$work/stub/scripts/check-fragment-events-land.sh"
    STUB_DIR="$work/stub" bash -c '. "$1"; . "$2"' _ "$work/harness.sh" "$work/branch.sh" 2>&1
}

# ---- ARM 1: exit 2 is could-not-run, and says so --------------------------
out2="$(drive 2 'blocked:fragment-events-land:no-fresh-plan-binary')"
if printf '%s' "$out2" | grep -q 'COULD NOT RUN'; then
    ok "exit 2 -> named as could-not-run"
else
    bad "exit 2 -> not named as could-not-run; got: $out2"
fi

# THE DEFECT ITSELF. The exit-2 run must NOT claim anything about the ledger.
if printf '%s' "$out2" | grep -q 'an event is attached to no packet'; then
    bad "exit 2 still claims 'an event is attached to no packet' — the 1021-a944 defect"
else
    ok "exit 2 makes NO substantive claim about the ledger"
fi

# The script's own verdict line must be surfaced, not paraphrased away.
if printf '%s' "$out2" | grep -q 'no-fresh-plan-binary'; then
    ok "exit 2 surfaces the script's own verdict line"
else
    bad "exit 2 hides which could-not-run cause fired; got: $out2"
fi

# And the remedy has to be actionable in the locus that hit it.
if printf '%s' "$out2" | grep -q 'cycle-preflight'; then
    ok "exit 2 names the cycle-preflight remedy"
else
    bad "exit 2 gives the operator no remedy; got: $out2"
fi

# ---- ARM 2: exit 1 is still the substantive violation ---------------------
# The negative control for ARM 1: a fix that simply stopped claiming anything
# would pass every assertion above and destroy the check. This is the arm that
# forbids that.
out1="$(drive 1 'blocked:fragment-events-land:2 event(s) attached to no packet')"
if printf '%s' "$out1" | grep -q 'an event is attached to no packet'; then
    ok "exit 1 still reports the substantive violation"
else
    bad "exit 1 no longer reports the violation — the check has been hollowed out; got: $out1"
fi
if printf '%s' "$out1" | grep -q 'COULD NOT RUN'; then
    bad "exit 1 mislabelled as could-not-run — the two arms are swapped"
else
    ok "exit 1 is NOT labelled could-not-run"
fi

# ---- ARM 3: exit 0 passes -------------------------------------------------
out0="$(drive 0 'ok:fragment-events-land:12 fragment(s) checked')"
if printf '%s' "$out0" | grep -q 'All fragment events land'; then
    ok "exit 0 -> passes"
else
    bad "exit 0 no longer passes; got: $out0"
fi

# ---- ARM 4: the real script really does emit exit 2 -----------------------
# Stubs prove the ROUTING. This proves the routing has a real caller: the
# script's could-not-run channel is reachable, via the documented
# TILLANDSIAS_PLAN_BIN seam (a named binary passes through on existence alone,
# so a nonexistent one is a resolve failure). Without this arm the fixture
# would pin a branch that nothing can trigger.
real_out="$(TILLANDSIAS_PLAN_BIN=/nonexistent-plan-binary-1021-a944 \
    bash scripts/check-fragment-events-land.sh 2>&1)"
real_rc=$?
if [ "$real_rc" -eq 2 ] && printf '%s' "$real_out" | grep -q 'no-fresh-plan-binary'; then
    ok "the real script reaches exit 2 with its documented verdict"
else
    bad "the real script did not produce exit 2 / no-fresh-plan-binary (rc=$real_rc, out=$real_out)"
fi

if [ "$fail" -eq 0 ]; then
    echo "PASS: fragment-events-land call site ${pass}/${pass} (1021-a944)"
    exit 0
fi
echo "FAIL: fragment-events-land call site ${pass} passed, ${fail} failed (1021-a944)"
exit 1
