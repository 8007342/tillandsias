-- @trace spec:default-image, order:2047-ci2k
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
-- A reference counts when it appears on a non-comment line of any .sh under
-- the image directory. Verdict, one line on stdout:
--   ok:forge-lib-copies:<n> libs                         exit 0
--   violation:forge-lib-copies:<lib>[,<lib>]             exit 1
--   blocked:forge-lib-copies:<file>-unreadable           exit 2

local DIR = env.get("TILLANDSIAS_FORGE_IMAGE_DIR") or "images/default"
local CF = DIR .. "/Containerfile"
if not fs.exists(CF) then
    verdict.emit("blocked:forge-lib-copies:" .. CF .. "-unreadable", 2)
end
local containerfile = fs.read(CF)

local wanted = {}
for _, path in ipairs(fs.walk(DIR, { suffix = ".sh" }) or {}) do
    local text = fs.read(path)
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        if not line:match("^%s*#") then
            for name in line:gmatch("(lib%-[%w%-]+%.sh)") do
                if fs.exists(DIR .. "/" .. name) then wanted[name] = true end
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

if #missing > 0 then
    verdict.emit("violation:forge-lib-copies:" .. table.concat(missing, ","), 1)
end
verdict.emit(string.format("ok:forge-lib-copies:%d libs", #names), 0)
