-- @env TILLANDSIAS_HOST_KIND FORGE_SERVICE_HEALTH_CHECK_DIR HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy VAULT_ADDR VAULT_CACERT VAULT_TOKEN_FILE CURL_CA_BUNDLE SSL_CERT_FILE
-- @trace spec:default-image, order:1561-47a8
--
-- check-forge-service-health.lua — PORTED from check-forge-service-health.sh
-- (carried obligation shell->lua, paid by 1561-47a8): inside a forge, the
-- enclave services are up, Vault answers, and outbound HTTPS works.
--
-- Prints exactly one line:
--   ^(ok:forge-services|skip:not-forge-host|down:(enclave-services|vault-health|outbound-https))$
-- Exit 0 on ok/skip, 1 on down. The .sh printed `failed:` for down; the runner
-- admits no `failed:` kind, so scripts/forge-validate.sh reads both spellings.
--
-- FORGE_SERVICE_HEALTH_CHECK_DIR is the fixture seam (scripts/test-forge-validate.sh):
-- it holds `services`, `vault` and `outbound` stubs in place of the real
-- commands. proc.run children start from a scrubbed environment, so the proxy,
-- Vault and CA variables those commands read are forwarded explicitly.

if env.get("TILLANDSIAS_HOST_KIND") ~= "forge" then
    verdict.emit("skip:not-forge-host", 0)
end

local FORWARD = {
    "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "no_proxy",
    "VAULT_ADDR", "VAULT_CACERT", "VAULT_TOKEN_FILE", "CURL_CA_BUNDLE", "SSL_CERT_FILE",
}
local ENV = {}
for _, k in ipairs(FORWARD) do
    local v = env.get(k)
    if v ~= nil and v ~= "" then ENV[k] = v end
end

local dir = env.get("FORGE_SERVICE_HEALTH_CHECK_DIR")
local services, vault, outbound
if dir ~= nil and dir ~= "" then
    services, vault, outbound = { dir .. "/services" }, { dir .. "/vault" }, { dir .. "/outbound" }
else
    services = { "tillandsias-services", "--json" }
    vault = { "vault-cli", "health" }
    outbound = { "curl", "-fsS", "--max-time", "10", "https://api.github.com/rate_limit" }
end

local function run(argv, timeout_s)
    local ok, r = pcall(proc.run, { argv = argv, env = ENV, timeout_ms = timeout_s * 1000 })
    if not ok then return nil end
    if r.status ~= "exited" or r.code ~= 0 then return nil end
    return r.stdout or ""
end

-- Exactly one service of each name is up, as the .sh's jq filter required.
local function enclave_up(body)
    local ok, doc = pcall(json.parse, body)
    if not ok or type(doc) ~= "table" or type(doc.services) ~= "table" then return false end
    for _, name in ipairs({ "proxy", "git-service", "inference" }) do
        local up = 0
        for _, s in ipairs(doc.services) do
            if type(s) == "table" and s.name == name and s.status == "up" then up = up + 1 end
        end
        if up ~= 1 then return false end
    end
    return true
end

local body = run(services, 10)
if body == nil or not enclave_up(body) then
    verdict.emit("down:enclave-services", 1)
end
if run(vault, 10) == nil then
    verdict.emit("down:vault-health", 1)
end
if run(outbound, 15) == nil then
    verdict.emit("down:outbound-https", 1)
end
verdict.emit("ok:forge-services", 0)
