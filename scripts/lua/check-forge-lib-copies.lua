-- @trace spec:default-image, order:2047-ci2k, order:2049-xjsb
-- @env TILLANDSIAS_FORGE_IMAGE_DIR
--
-- check-forge-lib-copies.lua — every images/default/lib-*.sh that the image's
-- shell names in code is COPYed into /usr/local/lib/tillandsias/.
--
-- lib-common.sh sources its siblings from its own directory and the MCP
-- wrappers fall back to /usr/local/lib/tillandsias/, so a lib that exists in
-- the source tree but is never COPYed works in a checkout and silently
-- degrades in a built forge. MEASURED 2026-11-08 (2047-ci2k): four libs —
-- lib-embed-endpoint, lib-experts-probe, lib-ledger-freshness and
-- lib-mcp-build-id — were sourced and never copied.
--
-- 2049-xjsb (forge-lua-helpers task 2.2): every lua/<name>.lua module a
-- wrapper names is shipped too — it exists under <image>/lua/ AND the
-- Containerfile copies lua/ to /usr/local/lib/tillandsias/lua/. A wrapper
-- that falls back to a module missing from the image reports the helper as
-- absent, so the same silent degrade applies. It is listed as lua/<name>.lua.
--
-- A reference counts when it appears on a non-comment line of any .sh under
-- the image directory (lib-*.sh and lua/*.lua alike). Verdict, one line on stdout:
--   ok:forge-lib-copies:<n> libs,<m> lua modules             exit 0
--   violation:forge-lib-copies:<lib>[,<lib>]             exit 1
--   blocked:forge-lib-copies:<file>-unreadable           exit 2

local DIR = env.get("TILLANDSIAS_FORGE_IMAGE_DIR") or "images/default"
local CF = DIR .. "/Containerfile"
if not fs.exists(CF) then
    verdict.emit("blocked:forge-lib-copies:" .. CF .. "-unreadable", 2)
end
local containerfile = fs.read(CF)

local wanted, wanted_lua = {}, {}
for _, path in ipairs(fs.walk(DIR, { suffix = ".sh" }) or {}) do
    local text = fs.read(path)
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        if not line:match("^%s*#") then
            for name in line:gmatch("(lib%-[%w%-]+%.sh)") do
                if fs.exists(DIR .. "/" .. name) then wanted[name] = true end
            end
            for mod in line:gmatch("lua/([%w_%-]+%.lua)") do
                wanted_lua["lua/" .. mod] = true
            end
        end
    end
end

local names = {}
for n in pairs(wanted) do names[#names + 1] = n end
table.sort(names)

local missing = {}
for _, n in ipairs(names) do
    local esc = n:gsub("%p", "%%%0")
    if not containerfile:match("\nCOPY%s+" .. esc .. "%s+/usr/local/lib/tillandsias/" .. esc .. "%s") then
        missing[#missing + 1] = n
    end
end

local lua_dir_copied = containerfile:match("\nCOPY%s+lua/%s+/usr/local/lib/tillandsias/lua/%s") ~= nil
local mods = {}
for m in pairs(wanted_lua) do mods[#mods + 1] = m end
table.sort(mods)
for _, m in ipairs(mods) do
    if not (lua_dir_copied and fs.exists(DIR .. "/" .. m)) then
        missing[#missing + 1] = m
    end
end

if #missing > 0 then
    verdict.emit("violation:forge-lib-copies:" .. table.concat(missing, ","), 1)
end
verdict.emit(string.format("ok:forge-lib-copies:%d libs,%d lua modules", #names, #mods), 0)
