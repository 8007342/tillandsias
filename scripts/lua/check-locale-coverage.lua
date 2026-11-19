-- @trace order:2096-pq2g, spec:shell-prompt-localization-fr, spec:shell-prompt-localization-ja, spec:help-system-localization
--
-- check-locale-coverage.lua — the forge's locale bundles and help scripts are
-- complete and parse. Ported from scripts/test-locale-coverage.sh (2096-pq2g),
-- which no gate ran and which had gone red unseen: it looked for the help
-- scripts under scripts/ after they moved to images/default/.
--
--   1 COVERAGE  every L_* name en.sh defines is defined in each FULL bundle
--               (es, de, fr, ja). The other bundles are deliberate stubs.
--   2 SYNTAX    `bash -n` accepts en.sh and every full bundle.
--   3 HELP      images/default/help{,-es,-fr,-de,-ja}.sh exist and parse.
--   4 CONTROL   the coverage comparison names a variable removed from a copy of
--               en.sh's list, so arm 1 cannot pass by comparing nothing.
--
-- Usage: tillandsias-plan script run scripts/lua/check-locale-coverage.lua

local LOC = "images/default/locales"
local FULL = { "es", "de", "fr", "ja" }
local HELP = { "help.sh", "help-es.sh", "help-fr.sh", "help-de.sh", "help-ja.sh" }

if not fs.exists(LOC .. "/en.sh") then
    verdict.emit("blocked:locale-coverage:no-en-bundle", 2, LOC .. "/en.sh does not exist")
end

local passed, failed = {}, {}
local function check(name, cond, why)
    if cond then passed[#passed + 1] = name; out.line("ok:   " .. name)
    else failed[#failed + 1] = name; out.line("FAIL: " .. name .. " — " .. why) end
end

local function names(src)
    local set, n = {}, 0
    for _, l in ipairs(text.lines(src or "")) do
        local k = text.captures_all(l, "^(L_[A-Za-z0-9_]+)=")[1]
        if k and not set[k] then set[k] = true; n = n + 1 end
    end
    return set, n
end
local function missing(want, have)
    local m = {}
    for k in pairs(want) do if not have[k] then m[#m + 1] = k end end
    table.sort(m)
    return m
end
local function parses(path)
    local r = proc.run({ argv = { "bash", "-n", path }, timeout_ms = 30000 })
    return r.status == "exited" and r.code == 0, text.trim((r.stderr or ""))
end

local en, en_n = names(fs.read(LOC .. "/en.sh"))
check("en.sh defines L_* names", en_n > 0, "no L_* assignment found")

for _, loc in ipairs(FULL) do
    local p = LOC .. "/" .. loc .. ".sh"
    if not fs.exists(p) then
        check(loc .. ".sh coverage", false, p .. " does not exist")
    else
        local m = missing(en, (names(fs.read(p))))
        check(loc .. ".sh coverage (" .. en_n .. " names)", #m == 0, "missing " .. table.concat(m, ", "))
    end
end

for _, loc in ipairs({ "en", table.unpack(FULL) }) do
    local p = LOC .. "/" .. loc .. ".sh"
    if fs.exists(p) then
        local ok, err = parses(p)
        check(loc .. ".sh parses", ok, err)
    end
end

for _, h in ipairs(HELP) do
    local p = "images/default/" .. h
    if not fs.exists(p) then
        check(h .. " parses", false, p .. " does not exist")
    else
        local ok, err = parses(p)
        check(h .. " parses", ok, err)
    end
end

-- 4 CONTROL: drop one name from a copy and require the comparison to name it.
local any
for k in pairs(en) do any = k; break end
if any then
    local short = {}
    for k in pairs(en) do if k ~= any then short[k] = true end end
    local m = missing(en, short)
    check("CONTROL: a removed name is reported by name", #m == 1 and m[1] == any,
        "expected [" .. any .. "], got [" .. table.concat(m, ", ") .. "]")
end

if #failed > 0 then
    verdict.emit("violation:locale-coverage:" .. #failed .. ":of:" .. (#passed + #failed), 1,
        "failed: " .. table.concat(failed, "; "))
end
verdict.ok("locale-coverage", #passed)
