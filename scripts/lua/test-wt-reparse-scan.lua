-- @env PATH HOME
-- @trace order:823-u5zf, order:2332-ae6r
--
-- test-wt-reparse-scan.lua — scripts/lua/check-wt-reparse-workarounds-deleted.lua reds on a LIVE
-- symbol and stays green on a comment that names it. Ported from the .sh of the same name.
-- A grep satisfies 823-u5zf's words and fails its intent both ways: it reds on the comments that
-- record the deletion, and its natural repair is to delete them. A scan that always says ok
-- would pass arm 1 alone (1055-6yp8), so arms 2-3 plant live symbols and arm 5 breaks the scan.
--
-- Usage: tillandsias-plan script run scripts/lua/test-wt-reparse-scan.lua
-- Verdict: ok:wt-reparse-scan:<n> arms | violation:wt-reparse-scan:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("wt-reparse-scan")
local ROOT, PLAN = fixture.repo_root(), fixture.plan_binary()
local SCAN = "scripts/lua/check-wt-reparse-workarounds-deleted.lua"
if not fs.exists(SCAN) then T:refuse("scan-missing", SCAN) end
if PLAN == "" then T:refuse("no-plan-binary") end
local W = T:scratch()

local function scan(dir, script)
    local r = T:run{ PLAN, "script", "run", script or SCAN, "--", dir, cwd = ROOT }
    return r.code, text.trim(r.stdout or ""), tostring(r.stderr)
end
local function verdict(dir, script)
    local rc, o, e = scan(dir, script)
    if rc == 0 and o:find("^ok:wt%-reparse%-workarounds%-deleted:") then return "ok" end
    if rc == 1 and o:find("^violation:wt%-reparse%-workaround%-live:") then return "violation" end
    return "other: rc=" .. tostring(rc) .. " " .. o .. " " .. e
end
local function tree(name, body)
    fs.mkdir(W.rel .. "/" .. name .. "/src")
    fs.write(W.rel .. "/" .. name .. "/src/lib.rs", body)
    return W.rel .. "/" .. name
end
local function arm(name, want, got) T:arm(name, got == want, got) end

local comments = tree("comments", "// The argv_survives_wt_reparse guard (order 795-zshi) is deleted: every lane\n"
    .. "// now emits a verbatim argv, so it always returned true.\n"
    .. "/// Historical note: wt_safe_title used to sanitise the tab title.\npub fn spawn() {}\n")
arm("1 a tree that only comments on the symbols is clean", "ok", verdict(comments))
local live = tree("live", "// A comment mentioning argv_survives_wt_reparse must not be what trips this.\n"
    .. "fn argv_survives_wt_reparse(argv: &[String]) -> bool {\n    argv.iter().all(|a| !a.is_empty())\n}\n")
arm("2 a live definition reds", "violation", verdict(live))
arm("2 a live call reds", "violation", verdict(tree("call",
    "pub fn spawn(argv: &[String]) {\n    if argv_survives_wt_reparse(argv) { wt(); } else { conhost(); }\n}\n")))
arm("2 the second symbol reds", "violation", verdict(tree("title",
    "fn wt_safe_title(t: &str) -> String { t.to_string() }\n")))
arm("3 code with a trailing comment still reds", "violation", verdict(tree("trailing",
    "pub fn spawn(argv: &[String]) {\n    let ok = argv_survives_wt_reparse(argv); // legacy guard, see 795-zshi\n    let _ = ok;\n}\n")))
local rc4, o4 = scan("crates")
T:arm("4 the real workspace is clean, and its comments were seen",
    rc4 == 0 and tonumber(o4:match("^ok:.*deleted:(%d+) mention") or 0) > 0, o4)

-- MUTATION: a scan that no longer strips comments, and one that knows no symbol.
local src = fs.read(SCAN):gsub("\r\n", "\n")
local function mutant(name, from, to)
    local a, b = src:find(from, 1, true)
    if not a then T:refuse("mutation-anchor-missing", name) end
    local p = W.rel .. "/" .. name .. ".lua"
    fs.write(p, src:sub(1, a - 1) .. to .. src:sub(b + 1))
    return p
end
arm("5 MUTATION a scan that does not strip comments reds the comment tree", "violation",
    verdict(comments, mutant("nostrip", '"//"', '"//never//"')))
arm("5 MUTATION a scan with no symbols passes the live tree", "ok",
    verdict(live, mutant("nosym", '{ "argv_survives_wt_reparse", "wt_safe_title" }', "{}")))

T:finish()
