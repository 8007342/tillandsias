-- @env PATH
-- @trace order:1445-7u63, order:2080-zcur
--
-- test-forge-src-budget-report.lua — when a forge clone fails, the forge
-- names a full /home/forge/src tmpfs (forge_src_budget_report in
-- images/default/lib-common.sh) instead of letting it read as a mirror or
-- network fault. The function is cut out by name and run with a stub df.
--   ARM1 a full source tmpfs is named, with its numbers
--   ARM2 a source tmpfs with room says nothing
--   ARM3 an unreadable df reports nothing rather than guessing
--   ARM4 both clone-failure paths name the budget before failing
-- Ported from scripts/test-forge-src-budget-report.sh onto common.fixture.
--
-- Usage: tillandsias-plan script run scripts/lua/test-forge-src-budget-report.lua
-- Verdict: ok:forge-src-budget-report:<n> arms | violation:forge-src-budget-report:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("forge-src-budget-report")
local lines = text.lines(fs.read("images/default/lib-common.sh") or "")
local buf, inside = {}, false
for _, l in ipairs(lines) do
    if not inside and l:find("^forge_src_budget_report%(%) {") then inside = true end
    if inside then
        buf[#buf + 1] = l
        if l == "}" then break end
    end
end
if #buf == 0 then T:refuse("function-not-found", "forge_src_budget_report not found in images/default/lib-common.sh") end

local W = T:scratch()
fs.mkdir(W.rel .. "/bin"); fs.mkdir(W.rel .. "/src")
fs.write(W.rel .. "/fn.sh", table.concat(buf, "\n") .. "\n")
fs.write(W.rel .. "/drive.sh", '. "$1"\nforge_src_budget_report "$2"\n')
local PATH = W.abs .. "/bin:" .. (env.get("PATH") or "/usr/bin:/bin")
local function stub_df(used)
    if used == "fail" then
        fs.write(W.rel .. "/bin/df", "#!/bin/sh\nexit 1\n")
    else
        fs.write(W.rel .. "/bin/df", '#!/bin/sh\necho "Filesystem Size Used Avail Use% Mounted on"\necho "tmpfs 256M 249M 7M '
            .. used .. '% /home/forge/src"\n')
    end
    T:must{ "chmod", "+x", W.abs .. "/bin/df" }
end
local function report()
    local r = T:run{ "bash", W.abs .. "/drive.sh", W.abs .. "/fn.sh", W.abs .. "/src", env = { PATH = PATH } }
    return r.code, text.trim(r.stdout or "")
end

stub_df("97")
local rc, out = report()
T:arm("ARM1 a full source tmpfs is named, with its numbers",
    rc == 0 and text.contains(out, "FULL: 249M of 256M (97%)") and text.contains(out, "not a mirror or network fault"),
    "rc=" .. tostring(rc) .. " out='" .. out .. "'")
stub_df("40")
rc, out = report()
T:arm("ARM2 a source tmpfs with room says nothing", rc == 1 and out == "", "rc=" .. tostring(rc) .. " out='" .. out .. "'")
stub_df("fail")
rc, out = report()
T:arm("ARM3 an unreadable df reports nothing rather than guessing", rc == 1 and out == "",
    "rc=" .. tostring(rc) .. " out='" .. out .. "'")

local n, w, prev = 0, 0, ""
for _, l in ipairs(lines) do
    if text.is_match(l, [[echo "\[forge\] FATAL: (filesystem clone failed|git clone failed from git:)]]) then
        n = n + 1
        if prev:find("forge_src_budget_report", 1, true) then w = w + 1 end
    end
    prev = l
end
T:arm("ARM4 both clone-failure paths name the budget before failing", n == 2 and w == 2, w .. "/" .. n .. " (want 2/2)")
T:finish()
