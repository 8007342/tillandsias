-- @trace order:2065-skdk
--
-- test-relay-preflight-tray-trigger.lua — relay-preflight runs its
-- tray,listen-vsock cargo pass when the diff touches any tillandsias-headless
-- source, not only src/tray/.
--
-- MEASURED 2026-11-08: #1034 (2055-grzz) passed ./build.sh --preflight on
-- yoga and was then evicted at the land gate. Three tray::tests pin the exact
-- MCP tool count under --features tray,listen-vsock, and grzz added two tools
-- in mcp_socket.rs and audio_studio.rs, which are outside src/tray/. The
-- trigger matched only ^crates/tillandsias-headless/src/tray/, so the pass
-- never ran.
--
-- The fixture runs relay-preflight.sh's own trigger (BEGIN/END-TRAY-TRIGGER)
-- in bash against a DIFF_ALL it chooses and reads _tray_touched:
--   1 PRE-FIX   the trigger rebuilt with the old src/tray/ pattern gives 0 for
--               an mcp_socket.rs-only diff (the broken world exists)
--   2 FIXED     the trigger as it stands gives 1 for that diff
--   3 FIXED     gives 1 for src/tray/, tests/ and Cargo.toml diffs too
--   4 CONTROL   gives 0 for a diff with no headless source (the cost stays
--               scoped): other crates, scripts, a look-alike crate name, an empty diff
--   5 WIRING    both consumers, the --plan listing and the cargo run, key on
--               _tray_touched
--
-- Terminal line: ok:relay-preflight-tray-trigger:<n> or
-- refused:relay-preflight-tray-trigger:<failed>.
--
-- Usage: tillandsias-plan script run scripts/lua/test-relay-preflight-tray-trigger.lua

local ROOT = text.trim(proc.run({ argv = { "git", "rev-parse", "--show-toplevel" } }).stdout or "")
local REL = "target/plan-scratch/relay-tray-trigger-" .. tostring(math.random(100000, 999999)) .. tostring(math.random(100000, 999999))
local S = ROOT .. "/" .. REL
fs.mkdir(REL)
local passed, failed = 0, 0
local function ok(m) out.line("ok: " .. m); passed = passed + 1 end
local function bad(m) out.line("FAIL: " .. m); failed = failed + 1 end
local function finish()
    proc.run({ argv = { "rm", "-rf", S } })
    if failed == 0 then verdict.emit("ok:relay-preflight-tray-trigger:" .. passed, 0) end
    verdict.emit("refused:relay-preflight-tray-trigger:" .. failed, 1)
end

local src = fs.read("scripts/relay-preflight.sh") or ""
local block = src:match("# BEGIN%-TRAY%-TRIGGER\n(.-)# END%-TRAY%-TRIGGER\n")
local grep_line = block and block:match("(grep [^\n]*_tray_touched=1)")
if not block or not grep_line then
    bad("premise: the BEGIN/END-TRAY-TRIGGER block, or its grep line setting _tray_touched=1, was not found in scripts/relay-preflight.sh")
    finish()
end
local pre = block:gsub(grep_line:gsub("%p", "%%%0"),
    (("grep -q '^crates/tillandsias-headless/src/tray/' <<<\"$DIFF_ALL\" && _tray_touched=1"):gsub("%%", "%%%%")), 1)
-- No pre ~= block guard: arm 1 asserts the rebuilt trigger's behaviour, and a
-- guard here would turn a reverted fix into a premise failure, not arm 2's red.

local function touched(name, body, diff)
    fs.write(REL .. "/" .. name, "DIFF_ALL=\"$1\"\n" .. body .. "printf 'touched=%s\\n' \"$_tray_touched\"\n")
    local r = proc.run({ argv = { "bash", S .. "/" .. name, diff }, timeout_ms = 30000 })
    return (r.stdout or ""):match("touched=(%d)"), (r.stdout or "") .. (r.stderr or "")
end

local MCP = "crates/tillandsias-headless/src/audio_studio.rs\ncrates/tillandsias-headless/src/mcp_socket.rs\nimages/audio-studio/Containerfile"

local v, o = touched("pre.sh", pre, MCP)
if v == "0" then ok("pre-fix trigger skips an mcp_socket.rs-only diff (the #1034 shape)")
else bad("pre-fix trigger did not skip the #1034 diff, so the control proves nothing: " .. o:sub(1, 200)) end

v, o = touched("fix.sh", block, MCP)
if v == "1" then ok("fixed trigger runs the tray pass for an mcp_socket.rs-only diff")
else bad("fixed trigger skips the #1034 diff: " .. o:sub(1, 200)) end

for _, d in ipairs({
    "crates/tillandsias-headless/src/tray/mod.rs",
    "crates/tillandsias-headless/tests/cloud_usage_never_mints.rs",
    "crates/tillandsias-headless/Cargo.toml",
}) do
    v, o = touched("fix.sh", block, "scripts/x.sh\n" .. d)
    if v == "1" then ok("fixed trigger runs the tray pass for " .. d)
    else bad("fixed trigger skips " .. d .. ": " .. o:sub(1, 200)) end
end

for _, d in ipairs({
    "crates/tillandsias-plan/src/main.rs\nscripts/relay-preflight.sh",
    "crates/tillandsias-headless-shim/src/lib.rs",
    "docs/crates/tillandsias-headless/src/note.md",
    "crates/tillandsias-headless/Cargo.toml.orig",
    "",
}) do
    v, o = touched("fix.sh", block, d)
    if v == "0" then ok("fixed trigger skips a diff with no headless source: " .. (d == "" and "<empty>" or d:gsub("\n", " + ")))
    else bad("fixed trigger runs for a non-headless diff " .. d:gsub("\n", " + ") .. ": " .. o:sub(1, 200)) end
end

local _, uses = src:gsub('%[ "%$_tray_touched" = 1 %]', "")
if uses >= 2 and src:find('&& echo "plan:crate:tillandsias-headless+tray,listen-vsock"', 1, true) then
    ok("both the --plan listing and the cargo run key on _tray_touched (" .. uses .. " uses)")
else bad("the tray pass consumers no longer key on _tray_touched (" .. uses .. " uses)") end

finish()
