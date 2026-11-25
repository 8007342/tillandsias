-- @env PATH HOME TILLANDSIAS_BIN CARGO_TARGET_DIR
-- @trace order:1139-xe5m, order:1179-yshc, order:815-gdjk, order:852-dk9z, spec:accel-capability-probe, order:2346-754w
--
-- test-capabilities-envelope-names-its-source.lua — `--capabilities` says whether its envelope
-- was measured or served from the cache. Ported from the .sh of the same name (2346-754w). The
-- probe really runs and reads this machine; XDG_CACHE_HOME (815-gdjk: the one cache-root
-- resolution) points into scratch, so this host's cache is neither read nor written.
--
--   1 a cold run says measured        2 a second says served
--   3 the replay is real: run 2 repeats run 1's timestamp
--   4 the STORED document claims neither
--   5 CLOSURE the two envelopes differ in accel_source and in nothing else
--   6 --fresh measures with a warm cache
--
-- Usage: tillandsias-plan script run scripts/lua/test-capabilities-envelope-names-its-source.lua
-- Verdict: ok:capabilities-envelope-names-its-source:<n> arms | violation:... | skip:... | could-not-run:... (exit 3)

local fixture = require "common.fixture"
local T = fixture.new("capabilities-envelope-names-its-source")
local d = T:scratch()
local E = { FIXTURE_ROOT = fixture.repo_root() }
for _, k in ipairs{ "PATH", "HOME", "TILLANDSIAS_BIN", "CARGO_TARGET_DIR" } do
    local v = env.get(k)
    if v and v ~= "" then E[k] = v end
end
-- test-envelope-suite-resolves-the-gates-artifact.lua cuts the block from `if [ -n` to its `fi`
-- out of this file: the DEFAULT goes through the shared probe, never a hardcoded target/ path.
local SCRIPT = [==[
set -uo pipefail
W=$PWD; ROOT="$FIXTURE_ROOT"; cd "$ROOT" || exit 90
if [ -n "${TILLANDSIAS_BIN:-}" ]; then
    BIN="$TILLANDSIAS_BIN"
else
    PROBE="$ROOT/scripts/plan-binary-probe.sh"
    if [ -r "$PROBE" ]; then
        . "$PROBE"
    else
        # A missing reader must not surface as a silent fallback to the old default.
        resolve_target_binary() { return 1; }
    fi
    BIN="$(resolve_target_binary tillandsias debug "$ROOT" 2>/dev/null)"
    [ -n "$BIN" ] || BIN="$ROOT/target/debug/tillandsias"
fi
[ -x "$BIN" ] || { echo "$BIN"; exit 9; }
"$BIN" --version </dev/null 2>/dev/null | grep -qiE "^tillandsias" || exit 8
export XDG_CACHE_HOME="$W/cache"
"$BIN" --capabilities >"$W/cold" 2>/dev/null </dev/null; echo $? >"$W/cold.rc"
"$BIN" --capabilities >"$W/warm" 2>/dev/null </dev/null
cp "$W/cache/tillandsias/capabilities.json" "$W/stored" 2>/dev/null
"$BIN" --capabilities --fresh >"$W/fresh" 2>/dev/null </dev/null
exit 0
]==]
local r = T:run{ fixture.posix_shell(), "-s", cwd = d.abs, stdin = SCRIPT, env = E, env_unset = { "TILLANDSIAS_*", "CARGO_TARGET_DIR" }, timeout_ms = 120000 }
if r.code == 9 then
    -- Exit 3: the gate step nominates it as its skip; exit 0 would be booked as a pass.
    T:cleanup()
    verdict.emit("could-not-run:capabilities-envelope-names-its-source:no-binary", 3)
end
-- A named binary that does not answer --version as tillandsias is not the subject (the preflight door
-- plants one). Only --version is asked: a product whose --capabilities broke is still red below.
if r.code == 8 then T:skip("the-named-binary-is-not-tillandsias") end
if r.code ~= 0 then T:refuse("setup-failed", "rc=" .. tostring(r.code) .. " " .. (r.stderr or "")) end
local function read(f) return fs.exists(d.rel .. "/" .. f) and fs.read(d.rel .. "/" .. f):gsub("\r", "") or "" end
local function first(f) return read(f):match("^[^\n]*") end
local function source(f) return (" " .. first(f)):match(" accel_source=(%S*)") end
local function stamp(f) return read(f):match('"timestamp": "([^"]*)"') end
local function rest(f)
    local out = {}
    for w in first(f):gmatch("%S+") do
        if w:sub(1, 13) ~= "accel_source=" then out[#out + 1] = w end
    end
    return table.concat(out, " ")
end
T:arm("1 a cold run exits 0 and says measured", text.trim(read("cold.rc")) == "0" and source("cold") == "measured", "rc=" .. read("cold.rc") .. first("cold"))
T:arm("2 a second run says served", source("warm") == "served", first("warm"))
T:arm("3 the served document repeats the first run's timestamp", stamp("cold") ~= nil and stamp("cold") == stamp("warm"), tostring(stamp("cold")) .. " then " .. tostring(stamp("warm")))
local stored = read("stored"):match('"envelope_source":%s*([^\n]*)')
T:arm("4 the stored document says envelope_source: null", stored ~= nil and stored:sub(1, 4) == "null", tostring(stored))
T:arm("5 the envelopes differ in accel_source and in no other key", first("cold") ~= "" and first("cold") ~= first("warm") and rest("cold") == rest("warm"), first("cold") .. " | " .. first("warm"))
T:arm("6 --fresh says measured with a warm cache", source("fresh") == "measured", first("fresh"))
T:finish()
