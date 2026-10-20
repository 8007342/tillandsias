-- @env HOME TILLANDSIAS_CRED_SCAN_HOME TILLANDSIAS_CRED_SCAN_PODMAN
-- @read-env TILLANDSIAS_CRED_SCAN_HOME TILLANDSIAS_CRED_SCAN_PODMAN
-- @trace order:1118-fqfk, spec:tillandsias-vault
--
-- check-credentials-at-rest.lua — 1118-fqfk. Operator ruling 2026-10-19: no
-- Vault unseal share, root token or installation anchor is ever in plaintext on
-- durable disk. Allowed stores are the OS-encrypted keyring and memory/tmpfs.
--
-- It judges NAMES and PATHS only and never reads a credential's contents.
-- Sites it scans:
--   1. fallback files (fallback_vault-shamir-share-v1, fallback_vault-root-token-v1,
--      installation_anchor) under the host's tillandsias cache, state and data dirs;
--   2. any podman secret named tillandsias-* on the file driver, which keeps it
--      in plaintext under the containers storage dir (slice 1: the unseal key;
--      slice 2a: approle, token, CA and TLS keys);
--   3. per-container copies of those secrets under
--      containers/storage/overlay-containers/<id>/userdata/secrets/.
--
-- Seams for the fixture: TILLANDSIAS_CRED_SCAN_HOME replaces HOME, and
-- TILLANDSIAS_CRED_SCAN_PODMAN=none skips the podman query.

local home = env.get("TILLANDSIAS_CRED_SCAN_HOME") or env.get("HOME") or ""
if home == "" then
    verdict.emit("could-not-run:credentials-at-rest:no-home", 2)
end
local podman = env.get("TILLANDSIAS_CRED_SCAN_PODMAN") or "podman"

local FALLBACK_NAMES = {
    "fallback_vault-shamir-share-v1",
    "fallback_vault-root-token-v1",
    "installation_anchor",
}
local SECRET_GLOB = "tillandsias-*"

local found = {}

local function find_names(dir, depth, names)
    local argv = { "find", dir, "-maxdepth", tostring(depth), "-type", "f", "(" }
    for i, n in ipairs(names) do
        if i > 1 then argv[#argv + 1] = "-o" end
        argv[#argv + 1] = "-name"
        argv[#argv + 1] = n
    end
    argv[#argv + 1] = ")"
    local r = proc.run{ argv = argv }
    for _, l in ipairs(text.lines(r.stdout or "")) do
        if text.trim(l) ~= "" then found[#found + 1] = text.trim(l) end
    end
end

for _, d in ipairs({ "/.cache/tillandsias", "/.local/state/tillandsias", "/.local/share/tillandsias" }) do
    find_names(home .. d, 3, FALLBACK_NAMES)
end
find_names(home .. "/.local/share/containers/storage/overlay-containers", 4, { SECRET_GLOB })

if podman ~= "none" then
    local r = proc.run{ argv = { podman, "secret", "ls", "--format", "{{.Name}} {{.Driver}}" } }
    if r.status == "exited" and r.code == 0 then
        for _, l in ipairs(text.lines(r.stdout or "")) do
            local name, driver = l:match("^(%S+)%s+(%S+)")
            if name and name:sub(1, 12) == "tillandsias-" and driver == "file" then
                found[#found + 1] = "podman secret " .. name .. " (driver=file, plaintext under the containers storage dir)"
            end
        end
    else
        log.raw("[check-credentials-at-rest] podman secret ls did not answer; the podman store was not judged")
        verdict.emit("could-not-run:credentials-at-rest:podman", 2)
    end
end

if #found > 0 then
    log.raw("[check-credentials-at-rest] plaintext credentials at rest (names only, contents not read):")
    for _, f in ipairs(found) do log.raw("  " .. f) end
    log.raw("  why: the operator ruled (2026-10-19, 1118-fqfk) that losing credentials beats keeping them unencrypted")
    log.raw("  remedy: keep the share and root token only in the OS keyring or tmpfs; delete these after confirming the ruling applies")
    verdict.emit("violation:credentials-at-rest:" .. #found, 1)
end
verdict.emit("ok:credentials-at-rest:none", 0)
