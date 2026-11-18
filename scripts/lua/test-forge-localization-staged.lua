-- @trace order:792-7bt5, spec:default-image, order:2080-zcur
--
-- test-forge-localization-staged.lua — every localized asset the forge
-- DISPATCHES to is STAGED by both image paths (792-7bt5: 440 lines of
-- translated help lived outside the build context and were staged by nothing,
-- and the nix path staged 2 of 17 locale bundles and no help at all).
--   1 each images/default/help-<xx>.sh is COPYed by the Containerfile and cp'd by flake.nix
--   2 help.sh dispatches to help-${_LOCALE}.sh under the directory both paths stage into
--   3 flake.nix stages EVERY locale bundle (a glob), not a hand list
--   4 no stray copy of the help dispatcher exists outside images/default
-- Ported from scripts/test-forge-localization-staged.sh onto common.fixture.
--
-- Usage: tillandsias-plan script run scripts/lua/test-forge-localization-staged.lua
-- Verdict: ok:forge-localization-staged:<n> arms | violation:forge-localization-staged:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("forge-localization-staged")
local CF = fs.read("images/default/Containerfile") or ""
local FL = fs.read("flake.nix") or ""

-- b is a word on a COPY line: right after `COPY ` or after whitespace.
local function copied(b)
    for _, l in ipairs(text.lines(CF)) do
        if l:sub(1, 5) == "COPY " then
            for w in l:gmatch("%S+") do if w == b then return true end end
        end
    end
    return false
end

local helps, missing = {}, {}
for _, n in ipairs(fs.list("images/default") or {}) do
    local b = n:match("([^/]+)$")
    if b:match("^help%-.+%.sh$") then helps[#helps + 1] = b end
end
for _, b in ipairs(helps) do
    if not copied(b) then missing[#missing + 1] = "Containerfile does not COPY " .. b end
    if not FL:find("/usr/local/share/tillandsias/" .. b, 1, true) then
        missing[#missing + 1] = "flake.nix does not stage " .. b
    end
end
T:arm("1: " .. #helps .. " translated help files, each staged by both paths",
    #helps >= 4 and #missing == 0,
    #helps < 4 and ("found " .. #helps .. " translated help files (want >= 4)") or table.concat(missing, "; "))

T:arm("2: help.sh dispatches under /usr/local/share/tillandsias",
    text.contains(fs.read("images/default/help.sh") or "", "/usr/local/share/tillandsias/help-${_LOCALE}.sh"),
    "help.sh no longer dispatches where both paths stage")

T:arm("3: flake.nix stages every locale bundle",
    text.contains(FL, "cp ${forgeLocales}/*.sh ./etc/tillandsias/locales/"),
    "flake.nix stages a hand list of locale bundles")

local stray = {}
for _, n in ipairs(fs.list("scripts") or {}) do
    local b = n:match("([^/]+)$")
    if b:match("^help.*%.sh$") then stray[#stray + 1] = b end
end
T:arm("4: no stray help dispatcher outside images/default", #stray == 0, table.concat(stray, " "))

T:finish()
