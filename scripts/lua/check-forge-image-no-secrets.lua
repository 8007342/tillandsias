-- @trace order:2004-in3v, order:1918-wfrg
-- @env TILLANDSIAS_FORGE_IMAGE_DIR
-- @env TILLANDSIAS_LAUNCHER_SRC_DIR
--
-- check-forge-image-no-secrets.lua — no forge image the launcher builds can
-- carry a credential.
--
-- Carried from 1918-wfrg (whose warm layer would have committed a running
-- forge as an image). Today a forge image comes only from a Containerfile
-- build, and credentials arrive at run time as podman secrets under
-- /run/secrets and through Vault, so nothing can capture one. This decider
-- pins both halves of that:
--   1. the forge Containerfiles (Containerfile.base, Containerfile) neither
--      name /run/secrets nor COPY/ADD a file that looks like a credential;
--   2. the launcher sources never turn a container into an image
--      (`podman commit`, or a "commit" argv word next to podman), the only
--      way a running forge's /run/secrets or agent logins could reach one.
--
-- Verdict grammar, one line on stdout (detail on stderr):
--   ok:forge-image-no-secrets:<n> instructions,<m> sources   exit 0
--   violation:forge-image-no-secrets:<what>[,<what>]         exit 1
--   blocked:forge-image-no-secrets:<file>-unreadable         exit 2

local DIR = env.get("TILLANDSIAS_FORGE_IMAGE_DIR") or "images/default"
local SRC = env.get("TILLANDSIAS_LAUNCHER_SRC_DIR") or "crates"

-- File names an agent login or a token lives in.
local CREDENTIAL = {
    "%.credentials%.json", "auth%.json", "%.git%-credentials", "hosts%.yml",
    "oauth[^/]*%.json", "%.netrc", "token[^/]*%.txt", "id_rsa", "id_ed25519",
}

local function looks_like_credential(word)
    local w = word:lower()
    for _, pat in ipairs(CREDENTIAL) do
        if w:find(pat) then return true end
    end
    return false
end

local bad = {}
local instructions = 0
for _, name in ipairs({ "Containerfile.base", "Containerfile" }) do
    local ok, body = pcall(fs.read, DIR .. "/" .. name)
    if not ok or not body then
        verdict.emit("blocked:forge-image-no-secrets:" .. name .. "-unreadable", 2)
    end
    local joined = body:gsub("\\\n", " ")
    for line in joined:gmatch("[^\n]+") do
        local trimmed = line:match("^%s*(.-)%s*$")
        local keyword = (trimmed:match("^(%a+)") or ""):upper()
        if not trimmed:find("^#") and (keyword == "COPY" or keyword == "ADD" or keyword == "RUN") then
            instructions = instructions + 1
            if trimmed:find("/run/secrets", 1, true) then
                bad[#bad + 1] = name .. ":run-secrets"
                log.raw("  " .. DIR .. "/" .. name .. " names /run/secrets: " .. trimmed)
            end
            if keyword ~= "RUN" then
                for word in trimmed:gmatch("%S+") do
                    if not word:find("^%-%-") and looks_like_credential(word) then
                        bad[#bad + 1] = name .. ":credential-file"
                        log.raw("  " .. DIR .. "/" .. name .. " copies a credential-shaped path: " .. word)
                    end
                end
            end
        end
    end
end

local sources = 0
local ok_w, walked = pcall(fs.walk, SRC)
if not ok_w or type(walked) ~= "table" then
    verdict.emit("blocked:forge-image-no-secrets:" .. SRC .. "-unreadable", 2)
end
for _, path in ipairs(walked) do
    if path:find("%.rs$") then
        local ok, body = pcall(fs.read, path)
        if ok and body then
            sources = sources + 1
            if body:find("podman commit", 1, true)
                or body:find('"podman"%s*,%s*"commit"')
                or body:find('"container"%s*,%s*"commit"') then
                bad[#bad + 1] = "image-commit"
                log.raw("  " .. path .. " commits a container to an image; a running forge holds")
                log.raw("  /run/secrets and agent logins, which would then live in the image")
            end
        end
    end
end

if #bad > 0 then
    verdict.emit("violation:forge-image-no-secrets:" .. table.concat(bad, ","), 1)
end
verdict.emit(string.format("ok:forge-image-no-secrets:%d instructions,%d sources", instructions, sources), 0)
