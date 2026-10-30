-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
-- @trace order:1118-fqfk, order:1909-aryk
--
-- Fixture for check-credentials-at-rest.lua. It plants a fake home under
-- target/, with no podman store, and runs the check through its seams:
--   RED:   a fallback share, a root-token fallback, an anchor, the same two
--          on a guest's identity disk (1909-aryk), container
--          copies of secrets and plaintext CA/TLS key files -> violation
--          naming each one;
--   GREEN: the same home with only non-credential files, and CA keys that
--          are symlinks into tmpfs (slice 2b) -> ok.

local runner = env.get("TILLANDSIAS_PLAN_BIN") or env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") or ""
if runner == "" then
    verdict.emit("could-not-run:credentials-at-rest-fixture:no-runner", 2)
end
local root = "target/cred-scan-fixture"
proc.run{ argv = { "rm", "-rf", root } }

local function plant(rel, body)
    local path = root .. "/" .. rel
    fs.mkdir(path:match("^(.*)/[^/]+$"))
    fs.write(path, body)
end

local function scan()
    local r = proc.run{
        argv = { runner, "script", "run", "scripts/lua/check-credentials-at-rest.lua" },
        env = {
            TILLANDSIAS_CRED_SCAN_HOME = proc.run{ argv = { "realpath", root } }.stdout:gsub("%s+$", ""),
            TILLANDSIAS_CRED_SCAN_PODMAN = "none",
            TILLANDSIAS_CRED_SCAN_IDENTITY = proc.run{ argv = { "realpath", root } }.stdout:gsub("%s+$", "") .. "/identity",
        },
    }
    return r.code, (r.stdout or "") .. (r.stderr or "")
end

local fails = 0
local function expect(cond, label, detail)
    if cond then
        log.raw("ok:   " .. label)
    else
        log.raw("FAIL: " .. label .. "\n" .. detail)
        fails = fails + 1
    end
end

-- GREEN first: the home holds only things that are not credentials.
plant(".cache/tillandsias/vault-data/core/marker", "x")
plant(".local/state/tillandsias/ca/README", "x")
plant("identity/vault-data/core/marker", "x")
plant("tmpfs-keys/intermediate.key", "planted")
plant("tmpfs-keys/preview-ca.key", "planted")
proc.run{ argv = { "ln", "-s", "../../../../tmpfs-keys/intermediate.key", root .. "/.local/state/tillandsias/ca/intermediate.key" } }
fs.mkdir(root .. "/.local/state/tillandsias/preview-ca")
proc.run{ argv = { "ln", "-s", "../../../../tmpfs-keys/preview-ca.key", root .. "/.local/state/tillandsias/preview-ca/preview-ca.key" } }
local code, out = scan()
expect(code == 0 and out:find("ok:credentials-at-rest:none", 1, true), "a home without credential files, its CA keys linked into tmpfs, is ok", out)

-- RED: every plaintext site the inventory found.
plant(".cache/tillandsias/fallback_vault-shamir-share-v1", "planted")
plant(".cache/tillandsias/fallback_vault-root-token-v1", "planted")
plant(".cache/tillandsias/installation_anchor", "planted")
plant("identity/fallback_vault-root-token-v1", "planted")
plant("identity/fallback_vault-shamir-share-v1", "planted")
plant(".local/share/containers/storage/overlay-containers/abc/userdata/secrets/tillandsias-vault-unseal", "planted")
plant(".local/share/containers/storage/overlay-containers/def/userdata/secrets/tillandsias-ca-key", "planted")
proc.run{ argv = { "rm", root .. "/.local/state/tillandsias/ca/intermediate.key" } }
plant(".local/state/tillandsias/ca/intermediate.key", "planted")
plant(".local/state/tillandsias/ca/vault.key", "planted")
code, out = scan()
expect(code == 1 and out:find("violation:credentials-at-rest:9", 1, true), "nine planted credential files are a violation of 9", out)
expect(out:find("identity/fallback_vault-root-token-v1", 1, true) and out:find("identity/fallback_vault-shamir-share-v1", 1, true), "the violation names both identity-disk files", out)
for _, name in ipairs({ "fallback_vault-shamir-share-v1", "fallback_vault-root-token-v1", "installation_anchor", "userdata/secrets/tillandsias-vault-unseal", "userdata/secrets/tillandsias-ca-key", "ca/intermediate.key", "ca/vault.key" }) do
    expect(out:find(name, 1, true), "the violation names " .. name, out)
end
expect(not out:find("planted", 1, true), "the check never prints a credential's contents", out)

proc.run{ argv = { "rm", "-rf", root } }
if fails > 0 then
    verdict.emit("violation:credentials-at-rest-fixture:" .. fails, 1)
end
verdict.emit("ok:credentials-at-rest-fixture:11", 0)
