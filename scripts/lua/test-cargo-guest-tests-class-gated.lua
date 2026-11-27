-- @env PATH HOME
-- @trace order:2437-v9vv, order:2175-ctin, order:2174-dail
--
-- test-cargo-guest-tests-class-gated.lua — the guest-feature-set cargo pass (1713-1dnx) skips
-- against a fresh full proof when no change touches what tillandsias-headless reads, exactly as
-- the feature-gated pass does, and runs when one does.
--
-- WHY (2437-v9vv). Of the cargo phases only the feature-gated pass asked the class selector; the
-- guest pass tests the same crate closure and ran on every land, scripts-only included (run 110,
-- 2026-11-27). A feature changes which code compiles, not which repo files the crate reads, so the
-- same scanned list (_CARGO_FEATURE_TEST_INPUTS, held to the sources by step 954) judges it.
--   1 WIRED   the guest pass's _step runs only in the else of _class_may_skip cargo-guest-feature-tests
--             against _CARGO_FEATURE_TEST_INPUTS (red on trunk: it had no gate)
--   2 SKIPS   a scripts/lua change the crate does not read, with a fresh full marker: skip
--   3 RUNS    a crates/ change: run
--   4 RUNS    with no fresh full gate (marker absent): run, whatever changed
--
-- Usage: tillandsias-plan script run scripts/lua/test-cargo-guest-tests-class-gated.lua
-- Verdict: ok:cargo-guest-tests-class-gated:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("cargo-guest-tests-class-gated")
local SH = fixture.posix_shell()
local src = fs.read("build.sh"):gsub("\r", "")

local gate_at = src:find("if _class_may_skip cargo-guest-feature-tests $_CARGO_FEATURE_TEST_INPUTS; then", 1, true)
local step_at = src:find('_step "Running guest-feature-set tests (listen-vsock, no tray)', 1, true)
local else_at = gate_at and src:find("\n    else\n", gate_at, true)
T:arm("1 WIRED the guest pass runs only in the else of its class gate", gate_at ~= nil and step_at ~= nil and else_at ~= nil and gate_at < else_at and else_at < step_at,
    "gate=" .. tostring(gate_at) .. " else=" .. tostring(else_at) .. " step=" .. tostring(step_at))

-- The rule, with build.sh's own data and the real library, in a scratch repo.
local inputs = src:match('\n(_CARGO_FEATURE_TEST_INPUTS="[^\n]*")\n')
local keep = src:match("\n(_CLASS_KEEP_UNCONDITIONAL='.-\n')\n")
local fns = {}
for _, f in ipairs{ "_class_set_once", "_class_may_skip" } do fns[#fns + 1] = src:match("\n(" .. f .. "%(%)%s*{\n.-\n})\n") end
T:arm("0 build.sh data and helpers are found", inputs ~= nil and keep ~= nil and #fns == 2)
if not (inputs and keep and #fns == 2) then T:finish() end
local d = T:scratch()
fs.write(d.rel .. "/rule.sh", inputs .. "\n" .. keep .. "\n_CLASS_SET_MEMO=\"\"\n" .. table.concat(fns, "\n") .. "\n")
local body = [==[
set -uo pipefail
A="$1/$3"; ROOT="$2"; mkdir -p "$A"
g() { git -c user.name=f -c user.email=f@l -c commit.gpgsign=false "$@"; }
g init -q -b linux-next "$A/w"; cd "$A/w" || exit 2
mkdir -p scripts/lua crates/x/src; cp "$ROOT/scripts/change-class.sh" "$ROOT/scripts/gate-stamp.sh" scripts/
echo x > scripts/lua/x.lua; echo 'pub fn f() {}' > crates/x/src/lib.rs; g add -A; g commit -qm base
BASE=$(git rev-parse HEAD)
case "$3" in
  lua|nomarker) echo y >> scripts/lua/x.lua ;;
  crate) echo '// y' >> crates/x/src/lib.rs ;;
esac
g commit -qam change
export TILLANDSIAS_CLASS_BASE="$BASE"
if [ "$3" = nomarker ]; then export TILLANDSIAS_FULL_GATE_MARKER="$A/none"; else date -u +%s > "$A/marker"; export TILLANDSIAS_FULL_GATE_MARKER="$A/marker"; fi
. scripts/change-class.sh
. "$1/rule.sh"
if _class_may_skip cargo-guest-feature-tests $_CARGO_FEATURE_TEST_INPUTS; then echo DECISION=skip; else echo DECISION=run; fi
]==]
local function decide(mode)
    local r = T:run{ SH, "-s", "--", d.abs, fixture.repo_root(), mode, stdin = body, env_unset = { "TILLANDSIAS_*", "GIT_*" }, timeout_ms = 60000 }
    local o = (r.stdout or "") .. (r.stderr or "")
    return o:match("DECISION=(%a+)") or "none", o
end
local v, o = decide("lua")
T:arm("2 SKIPS a scripts/lua change the crate does not read", v == "skip", v .. " " .. o:sub(-300))
v, o = decide("crate")
T:arm("3 RUNS a crates/ change", v == "run", v .. " " .. o:sub(-300))
v, o = decide("nomarker")
T:arm("4 RUNS with no fresh full gate", v == "run", v .. " " .. o:sub(-300))
T:finish()
