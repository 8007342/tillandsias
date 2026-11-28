-- @env PATH HOME
-- @trace order:2440-8893, order:2437-v9vv, order:2174-dail
--
-- test-cargo-clippy-class-gated.lua — both clippy passes (strict; strict + listen-vsock) skip against
-- a fresh full proof when nothing that COMPILES IN changed, and run when something does.
--
-- WHY (2440-8893). Clippy ran on every land, scripts-only included (82 s + 48 s on macuahuitl's
-- trace). It compiles and runs nothing, so its inputs are rust, the manifests and toolchain, every
-- include*! target and what build.rs reads: _CARGO_CLIPPY_INPUTS, scanned --compile-only and held
-- by step 954 (test-scan-cargo-test-repo-roots.lua arms 5-6, a dropped include target is refused).
--   1 WIRED  each clippy _step runs only in the else of its _class_may_skip (red on trunk)
--   2 SKIPS  a scripts/lua change nothing compiles in, with a fresh full marker: skip
--   3 RUNS   a crates/ change: run
--   4 RUNS   a change to a compiled-in scripts/ file (scripts/build-image.sh, an include target): run
--   5 RUNS   with no fresh full gate: run
--
-- Usage: tillandsias-plan script run scripts/lua/test-cargo-clippy-class-gated.lua
-- Verdict: ok:cargo-clippy-class-gated:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("cargo-clippy-class-gated")
local SH = fixture.posix_shell()
local src = fs.read("build.sh"):gsub("\r", "")

for _, w in ipairs{
    { "cargo-clippy-strict", '_step "Running clippy (strict; includes the workspace type-check)' },
    { "cargo-clippy-listen-vsock", '_step "Running clippy (strict + listen-vsock)' },
} do
    local g = src:find("if _class_may_skip " .. w[1] .. " $_CARGO_CLIPPY_INPUTS; then", 1, true)
    local s = src:find(w[2], 1, true)
    local e = g and src:find("\n    else\n", g, true)
    T:arm("1 WIRED " .. w[1] .. " runs only in the else of its class gate", g ~= nil and s ~= nil and e ~= nil and g < e and e < s,
        "gate=" .. tostring(g) .. " else=" .. tostring(e) .. " step=" .. tostring(s))
end

local inputs = src:match('\n(_CARGO_CLIPPY_INPUTS="[^\n]*")\n')
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
echo x > scripts/lua/x.lua; echo 'pub fn f() {}' > crates/x/src/lib.rs; echo 'echo b' > scripts/build-image.sh
g add -A; g commit -qm base
BASE=$(git rev-parse HEAD)
case "$3" in
  lua|nomarker) echo y >> scripts/lua/x.lua ;;
  crate) echo '// y' >> crates/x/src/lib.rs ;;
  include) echo 'echo c' >> scripts/build-image.sh ;;
esac
g commit -qam change
export TILLANDSIAS_CLASS_BASE="$BASE"
if [ "$3" = nomarker ]; then export TILLANDSIAS_FULL_GATE_MARKER="$A/none"; else date -u +%s > "$A/marker"; export TILLANDSIAS_FULL_GATE_MARKER="$A/marker"; fi
. scripts/change-class.sh
. "$1/rule.sh"
if _class_may_skip cargo-clippy-strict $_CARGO_CLIPPY_INPUTS; then echo DECISION=skip; else echo DECISION=run; fi
]==]
local function decide(mode)
    local r = T:run{ SH, "-s", "--", d.abs, fixture.repo_root(), mode, stdin = body, env_unset = { "TILLANDSIAS_*", "GIT_*" }, timeout_ms = 60000 }
    local o = (r.stdout or "") .. (r.stderr or "")
    return o:match("DECISION=(%a+)") or "none", o
end
local v, o = decide("lua")
T:arm("2 SKIPS a scripts/lua change nothing compiles in", v == "skip", v .. " " .. o:sub(-300))
v, o = decide("crate")
T:arm("3 RUNS a crates/ change", v == "run", v .. " " .. o:sub(-300))
v, o = decide("include")
T:arm("4 RUNS a change to a compiled-in scripts/ file", v == "run", v .. " " .. o:sub(-300))
v, o = decide("nomarker")
T:arm("5 RUNS with no fresh full gate", v == "run", v .. " " .. o:sub(-300))
T:finish()
