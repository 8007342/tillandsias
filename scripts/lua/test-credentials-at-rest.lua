-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
-- @trace order:1118-fqfk
--
-- Fixture for check-credentials-at-rest.lua. It plants a fake home under
-- target/, with no podman store, and runs the check through its seams:
--   RED:   a fallback share, a root-token fallback, an anchor and a container
--          copy of the unseal secret -> violation naming each one;
--   GREEN: the same home with only non-credential files -> ok.

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
local code, out = scan()
expect(code == 0 and out:find("ok:credentials-at-rest:none", 1, true), "a home without credential files is ok", out)

-- RED: every plaintext site the inventory found.
plant(".cache/tillandsias/fallback_vault-shamir-share-v1", "planted")
plant(".cache/tillandsias/fallback_vault-root-token-v1", "planted")
plant(".cache/tillandsias/installation_anchor", "planted")
plant(".local/share/containers/storage/overlay-containers/abc/userdata/secrets/tillandsias-vault-unseal", "planted")
code, out = scan()
expect(code == 1 and out:find("violation:credentials-at-rest:4", 1, true), "four planted credential files are a violation of 4", out)
for _, name in ipairs({ "fallback_vault-shamir-share-v1", "fallback_vault-root-token-v1", "installation_anchor", "userdata/secrets/tillandsias-vault-unseal" }) do
    expect(out:find(name, 1, true), "the violation names " .. name, out)
end
expect(not out:find("planted", 1, true), "the check never prints a credential's contents", out)

proc.run{ argv = { "rm", "-rf", root } }
if fails > 0 then
    verdict.emit("violation:credentials-at-rest-fixture:" .. fails, 1)
end
verdict.emit("ok:credentials-at-rest-fixture:7", 0)
