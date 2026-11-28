-- @env PATH HOME
-- @trace order:2429-u3rp, order:2174-dail
--
-- test-land-gate-class-base-is-the-candidate.lua — a land gate's class selector judges the
-- CANDIDATE's own change against the trunk it is gated on, plus what reached trunk ungated.
--
-- WHY (2429-u3rp). gate_env_for exported TILLANDSIAS_CLASS_BASE=<daily proof commit>, so the
-- changed set was proof..candidate: every land since the proof as well. MEASURED on yoga
-- 2026-11-27: against the newest proof (352 trunk commits back) it was 436 paths in every class,
-- and the operator-approved scoped tier skipped nothing in a week (0 skips in 15 gate logs).
-- Judging the candidate against trunk is sound because every first-parent trunk commit since
-- the proof is either a land MERGE (which gated its own diff) or a single-parent plan-lane commit
-- (which ran no gate); the second kind's paths are added to the set.
--
-- The functions are cut from scripts/land-queue.sh and run over a scratch remote:
--   proof P (attested, fresh) -> land merge adding Rust -> plan-lane commit (plan/ only) = trunk T;
--   candidate = T + a scripts/ change.
--   1 the functions are found
--   2 SCOPED   the candidate's class set is build-scripts plus the ungated plan-ledger; no rust
--              (red on trunk: the proof base adds rust from the land)
--   3 UNGATED  the plan-lane commit's class (plan-ledger) is in the set
--   4 CONTROL  with no proof, the gate still runs everything (the marker reads "never")
--   5 FAIL-CLOSED a named ungated-paths file that cannot be read fails the set (FULL)
--
-- Usage: tillandsias-plan script run scripts/lua/test-land-gate-class-base-is-the-candidate.lua
-- Verdict: ok:land-gate-class-base-is-the-candidate:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("land-gate-class-base-is-the-candidate")
local SH = fixture.posix_shell()
local src = "\n" .. fs.read("scripts/land-queue.sh"):gsub("\r", "")
local got, lost = {}, {}
for _, f in ipairs{ "_newest_attest", "daily_proof", "_ungated_paths", "gate_env_for" } do
    local body = src:match("\n(" .. f .. "%(%)%s*{[^\n]*\n.-\n})\n")
    if body then got[#got + 1] = body else lost[#lost + 1] = f end
end
-- _ungated_paths is new with the fix; on trunk it is absent and stubbed, so arm 2 fails on
-- what the selector SEES, not on a missing name.
local missing_ok = (#lost == 1 and lost[1] == "_ungated_paths")
T:arm("1 the land-queue functions are found", #lost == 0 or missing_ok, table.concat(lost, " "))
if not (#lost == 0 or missing_ok) then T:finish() end
if missing_ok then got[#got + 1] = "_ungated_paths() { :; }" end

local d = T:scratch()
fs.write(d.rel .. "/fns.sh", table.concat(got, "\n") .. "\n")
local A = d.abs
local body = [==[
set -uo pipefail
A="$1/$3"; ROOT="$2"; mkdir -p "$A"; cp "$1/fns.sh" "$A/fns.sh"
g() { git -c user.name=f -c user.email=f@l -c commit.gpgsign=false "$@"; }
git init -q --bare "$A/remote.git"
g init -q -b linux-next "$A/w"; cd "$A/w" || exit 2
mkdir -p scripts crates/x/src plan docs
cp "$ROOT/scripts/change-class.sh" "$ROOT/scripts/gate-stamp.sh" scripts/
echo base > docs/a.md; g add -A; g commit -qm proof; P=$(git rev-parse HEAD)
g switch -q -c feat; echo 'pub fn f() {}' > crates/x/src/lib.rs; g add -A; g commit -qm rust
g switch -q linux-next; g merge -q --no-ff -m 'land(1): feat' feat
mkdir -p plan/index.d; echo 'x: 1' > plan/index.d/x.yaml; g add -A; g commit -qm 'plan(h): 1 fragment'
TR=$(git rev-parse HEAD)
g remote add origin "$A/remote.git"; g push -q origin linux-next
now=$(date -u +%s)
[ "$3" = noproof ] || g push -q origin "$P:refs/attest/daily-full/$now"
g fetch -q origin
g switch -q -c cand "$TR"; echo 'echo hi' > scripts/foo.sh; g add -A; g commit -qm cand
REMOTE=origin TRUNK=linux-next DAILY_SKIP=1 DAILY_NS=refs/attest/daily-full DAILY_RED_NS=refs/attest/daily-red DAILY_MAX_AGE_S=86400
_RUNDIR="$A/run-$3"; mkdir -p "$_RUNDIR"
. "$A/fns.sh"
gate_env_for "$TR"
. scripts/change-class.sh
echo "CLASSES=$(change_class_set | tr '\n' ' ')"
echo "AGE=$(change_class_full_run_age_s)"
if [ -n "${TILLANDSIAS_CLASS_UNGATED_PATHS:-}" ]; then
    rm -f "$TILLANDSIAS_CLASS_UNGATED_PATHS"; change_class_set >/dev/null 2>&1; echo "UNREADABLE_RC=$?"
fi
]==]
local function run(mode)
    local r = T:run{ SH, "-s", "--", A, fixture.repo_root(), mode, stdin = body, env_unset = { "TILLANDSIAS_*", "GIT_*" }, timeout_ms = 120000 }
    return (r.stdout or "") .. (r.stderr or "")
end
local o = run("proof")
local classes = o:match("CLASSES=([^\n]*)") or ""
T:arm("2 SCOPED a scripts-only candidate's set has build-scripts and no rust", text.contains(classes, "build-scripts") and not text.contains(classes, "rust"), "classes=[" .. classes .. "] " .. o:sub(-300))
T:arm("3 UNGATED the plan-lane commit since the proof adds plan-ledger", text.contains(classes, "plan-ledger"), "classes=[" .. classes .. "]")
T:arm("5 a named ungated-paths file that cannot be read fails the set (FULL), never reads as nothing", text.contains(o, "UNREADABLE_RC=1"), o:match("UNREADABLE_RC=%d*") or "no UNREADABLE_RC line")
local o2 = run("noproof")
T:arm("4 CONTROL with no proof the selector's last full gate is never (everything runs)", text.contains(o2, "AGE=never"), o2:sub(-300))
T:finish()
