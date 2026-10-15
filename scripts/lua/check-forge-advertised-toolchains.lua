-- @trace spec:forge-welcome, order:1637-5765
-- @env TILLANDSIAS_FORGE_IMAGE_DIR
--
-- check-forge-advertised-toolchains.lua — the forge may only ADVERTISE a
-- toolchain the image actually provides.
--
-- THE DEFECT THIS EXISTS FOR (1637-5765, 2026-10-14). The welcome banner said
-- "dart 3 (flutter)" and `tillandsias-inventory` listed `flutter` under
-- Languages, while images/default installed no Flutter SDK: the Containerfile
-- set FLUTTER_ROOT=/opt/flutter and lib-common.sh unset it again because the
-- directory never exists. An agent told "flutter is here" ran `flutter create`
-- and got command-not-found. The onboarding skill (1705-bgen) asks
-- `command -v flutter`, so the advertisement and the provider must agree.
--
-- A PROVIDER is a fact in the image sources, one per toolchain whose presence
-- is not a plain package install:
--   dart     lib-common.sh defines ensure_dart_sdk (first-run install)
--   flutter  images/default/cli/flutter exists (the sibling-image shim) AND the
--            Containerfile installs it as /usr/local/bin/flutter
-- Only these are judged: the rest of the Languages line is distro packages.
--
-- Verdict grammar, one line on stdout (detail on stderr):
--   ok:forge-advertised-toolchains:<n> judged             exit 0
--   violation:forge-advertised-toolchains:<tool>[,<tool>] exit 1
--   blocked:forge-advertised-toolchains:<file>-unreadable  exit 2

local DIR = env.get("TILLANDSIAS_FORGE_IMAGE_DIR") or "images/default"

local function read(rel)
    local ok, body = pcall(fs.read, DIR .. "/" .. rel)
    if not ok or not body then
        verdict.emit("blocked:forge-advertised-toolchains:" .. rel .. "-unreadable", 2)
    end
    return body
end

local banner = read("forge-welcome.sh")
local inventory = read("cli/tillandsias-inventory")
local containerfile = read("Containerfile")
local libcommon = read("lib-common.sh")

-- The advertising surfaces: the banner's Languages line and the inventory's
-- Languages row. Anything else in those files (comments, tips) is not a claim.
local claims = {}
for line in banner:gmatch("[^\n]+") do
    if line:find("Languages", 1, true) and line:find("printf", 1, true) then claims[#claims + 1] = line end
end
for line in inventory:gmatch("[^\n]+") do
    if line:match('^%s*"Languages|') then claims[#claims + 1] = line end
end
local claimed = table.concat(claims, "\n"):lower()

local function advertises(tool)
    return claimed:find("%f[%w]" .. tool .. "%f[^%w]") ~= nil
end

local PROVIDERS = {
    dart = function()
        return libcommon:find("\nensure_dart_sdk%(%)") ~= nil
    end,
    flutter = function()
        local shim = fs.exists(DIR .. "/cli/flutter")
        local installed = containerfile:find("/usr/local/bin/flutter", 1, true) ~= nil
        return shim and installed
    end,
}
local ORDER = { "dart", "flutter" }

local judged, bad = 0, {}
for _, tool in ipairs(ORDER) do
    if advertises(tool) then
        judged = judged + 1
        if not PROVIDERS[tool]() then bad[#bad + 1] = tool end
    end
end

if #bad > 0 then
    for _, tool in ipairs(bad) do
        log.raw("  " .. DIR .. " advertises `" .. tool .. "` (welcome banner Languages line or")
        log.raw("  tillandsias-inventory Languages row) but provides no " .. tool .. ":")
        log.raw("  an agent told it is here gets command-not-found. Remove the claim, or")
        log.raw("  ship the provider this check names for it. 1637-5765.")
    end
    verdict.emit("violation:forge-advertised-toolchains:" .. table.concat(bad, ","), 1)
end
verdict.emit("ok:forge-advertised-toolchains:" .. judged .. " judged", 0)
