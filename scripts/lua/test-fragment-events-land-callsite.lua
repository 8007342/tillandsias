-- @trace order:1021-a944, order:965-sxec, order:1631-6w8z, order:2356-d66j
--
-- test-fragment-events-land-callsite.lua — a gate that could not RUN a check must never
-- assert what it would have FOUND. Measured by esme-windows: no fresh plan binary printed
-- "an event is attached to no packet" on a run where no fragment was read. Ported from the
-- .sh (2356-d66j).
--
-- The routing is EXTRACTED from build.sh at run time and driven with stubs, never copied;
-- an extraction that finds nothing refuses.
--   1 exit 2 and 3 are could-not-run: they say so, surface the decider's own line, name
--     the remedy, and claim nothing about the ledger
--   2 NEGATIVE: exit 1 is still the substantive violation, and is not could-not-run
--   3 exit 0 passes
--   4 the real decider does reach its could-not-run (no runner handed in)
--   5 freshness is decided BEFORE any plan binary runs, and the fresh one is handed in
--   6 a REAL stale binary with no cargo is refused by the pre-port .sh (from history) and
--     by the call site, before the decider is invoked
--
-- Verdict: ok:fragment-events-land-callsite:<n> arms | violation:fragment-events-land-callsite:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("fragment-events-land-callsite")
local ROOT = fixture.repo_root()
local SH = fixture.posix_shell()
local BASH = fixture.posix_shell("/bin/bash")
local PLAN = fixture.plan_binary()
if PLAN == "" then T:refuse("no-plan-binary") end
local W = T:scratch()
local function has(o, s) return o:find(s, 1, true) ~= nil end

local branch, on = {}, false
for l in (fs.read("build.sh") .. "\n"):gmatch("([^\n]*)\n") do
    if l:find('_step "Checking every fragment event lands on a real packet', 1, true) then on = true end
    if on then branch[#branch + 1] = l end
    if on and l:find('_info "All fragment events land"', 1, true) then on = "closed"; break end
end
branch = table.concat(branch, "\n") .. "\n"
if on ~= "closed" or not has(branch, "check-fragment-events-land.lua") then
    T:refuse("no-call-site", "could not extract the call site from build.sh: the anchors moved")
end
fs.write(W.rel .. "/branch.sh", branch)
fs.write(W.rel .. "/harness.sh", [[
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
]])
fs.write(W.rel .. "/drive.sh", '. "$1"\n. "$2"\n')
-- Run the branch over `dir`; its output and what the decider was invoked with.
local function branch_over(sh, dir, rc, line, path)
    local r = T:run{ sh, W.abs .. "/drive.sh", W.abs .. "/harness.sh", W.abs .. "/branch.sh", cwd = W.abs .. "/" .. dir,
        env = { STUB_DIR = W.abs .. "/" .. dir, STUB_RC = tostring(rc), STUB_LINE = line, PATH = path },
        env_unset = { "TILLANDSIAS_*", "CARGO_TARGET_DIR" } }
    local f = W.rel .. "/" .. dir .. "/invoked"
    return (r.stdout or "") .. (r.stderr or ""), fs.exists(f) and fs.read(f) or ""
end
local n = 0
local function drive(rc, line, fresh)
    n = n + 1
    fs.mkdir(W.rel .. "/stub" .. n .. "/scripts")
    fs.write(W.rel .. "/stub" .. n .. "/scripts/plan-binary-probe.sh",
        "ensure_fresh_plan_binary() { " .. (fresh == false and "return 2" or "echo /stub/fresh-plan") .. "; }\n")
    return branch_over(SH, "stub" .. n, rc, line)
end
local CLAIM = "an event is attached to no packet"
local CNR = "COULD NOT RUN"
local OK = "ok:fragment-events-land:1 fragment(s) checked"
local function flat(o, inv) return o:gsub("\n", " | ") .. " invoked=[" .. (inv or "") .. "]" end

local o, inv = drive(2, "could-not-run:fragment-events-land:check-did-not-answer")
T:arm("1 exit 2 is named as could-not-run", has(o, CNR), flat(o))
T:arm("1 exit 2 makes NO substantive claim about the ledger", not has(o, CLAIM), flat(o))
T:arm("1 exit 2 surfaces the decider's own verdict line", has(o, "check-did-not-answer"), flat(o))
T:arm("1 exit 2 names the cycle-preflight remedy", has(o, "cycle-preflight"), flat(o))
o = drive(3, "could-not-run:lua-decider:check-fragment-events-land.lua:no-script-runner")
T:arm("1 exit 3 (no script runner) is could-not-run with no ledger claim", has(o, CNR) and not has(o, CLAIM), flat(o))
o = drive(1, "blocked:fragment-events-land:2 event(s) attached to no packet")
T:arm("2 NEGATIVE exit 1 still reports the substantive violation", has(o, CLAIM), flat(o))
T:arm("2 NEGATIVE exit 1 is not labelled could-not-run", not has(o, CNR), flat(o))
o = drive(0, "ok:fragment-events-land:12 fragment(s) checked")
T:arm("3 exit 0 passes", has(o, "All fragment events land"), flat(o))

local r = T:run{ PLAN, "script", "run", "scripts/lua/check-fragment-events-land.lua", cwd = ROOT, env_unset = { "TILLANDSIAS_SCRIPT_RUNNER_BIN" } }
o = (r.stdout or "") .. (r.stderr or "")
T:arm("4 the real decider reaches exit 2 with its documented verdict", r.code == 2 and has(o, "could-not-run:fragment-events-land:no-plan-binary"), "rc=" .. tostring(r.code) .. " " .. flat(o))

o, inv = drive(0, OK, false)
T:arm("5 no fresh plan binary is could-not-run, and the decider is never invoked", has(o, CNR) and has(o, "no-fresh-plan-binary") and inv == "", flat(o, inv))
o, inv = drive(0, OK)
T:arm("5 the decider is handed the binary ensure_fresh_plan_binary produced", has(inv, "plan-bin=/stub/fresh-plan"), flat(o, inv))

-- 6: the real probe library, a runnable binary OLDER than its source, and no cargo.
local S = W.rel .. "/stale"
for _, d in ipairs{ "scripts", "target/release", "crates/tillandsias-plan/src" } do fs.mkdir(S .. "/" .. d) end
fs.write(S .. "/scripts/plan-binary-probe.sh", fs.read("scripts/plan-binary-probe.sh"))
fs.write(S .. "/target/release/tillandsias-plan", "#!/bin/sh\nexit 0\n")
T:must{ "chmod", "+x", W.abs .. "/stale/target/release/tillandsias-plan" }
T:must{ "touch", "-t", "200001010000", W.abs .. "/stale/target/release/tillandsias-plan" }
fs.write(S .. "/crates/tillandsias-plan/src/main.rs", "fn main() {}\n")
fs.write(S .. "/Cargo.lock", "")
local OLD = "scripts/check-fragment-events-land.sh"
local ref = "HEAD"
if T:run{ "git", "-C", ROOT, "cat-file", "-e", "HEAD:" .. OLD }.code ~= 0 then
    ref = text.trim(T:run{ "git", "-C", ROOT, "rev-list", "-1", "HEAD", "--", OLD }.stdout or "") .. "^"
end
local pre = T:run{ "git", "-C", ROOT, "show", ref .. ":" .. OLD }
if pre.code ~= 0 or (pre.stdout or "") == "" then
    T:arm("6 the pre-port .sh is readable from history", false, ref)
else
    fs.write(S .. "/" .. OLD, pre.stdout)
    r = T:run{ BASH, OLD, cwd = W.abs .. "/stale", env = { PATH = "/usr/bin:/bin" }, env_unset = { "TILLANDSIAS_*", "CARGO_TARGET_DIR" } }
    o = (r.stdout or "") .. (r.stderr or "")
    T:arm("6 pre-port: the .sh refuses a stale binary it cannot rebuild", r.code == 2 and has(o, "no-fresh-plan-binary"), "rc=" .. tostring(r.code) .. " " .. flat(o))
end
o, inv = branch_over(BASH, "stale", 0, OK, "/usr/bin:/bin")
T:arm("6 post-port: the call site refuses it before invoking the decider", has(o, CNR) and has(o, "no-fresh-plan-binary") and inv == "", flat(o, inv))
T:finish()
