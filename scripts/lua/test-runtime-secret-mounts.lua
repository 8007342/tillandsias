-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
-- @trace order:1118-fqfk
--
-- Fixture for check-runtime-secret-mounts.lua. It copies the two sources the
-- check reads into target/, and runs every check through its seam:
--   GREEN: the tree as it is -> ok for forge-opencode, forge-agent and proxy;
--   RED:   a second token in the opencode builder, a bind of intermediate.key
--          in the proxy builder, and a runtime_secret_path that leaves the
--          runtime dir -> each a violation.

local runner = env.get("TILLANDSIAS_PLAN_BIN") or env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") or ""
if runner == "" then
    verdict.emit("could-not-run:runtime-secret-mounts-fixture:no-runner", 2)
end
local SRC = "crates/tillandsias-headless/src"
local root = "target/runtime-secret-mounts-fixture"
proc.run{ argv = { "rm", "-rf", root } }
fs.mkdir(root)
local main0, vb0 = fs.read(SRC .. "/main.rs"), fs.read(SRC .. "/vault_bootstrap.rs")

local function plant(main, vb)
    fs.write(root .. "/main.rs", main)
    fs.write(root .. "/vault_bootstrap.rs", vb)
end

local function check(which)
    local r = proc.run{
        argv = { runner, "script", "run", "scripts/lua/check-runtime-secret-mounts.lua", "--", which },
        env = { TILLANDSIAS_RUNTIME_SECRET_SRC = root },
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

local function replace_once(text, old, new)
    local s, e = text:find(old, 1, true)
    assert(s, "fixture anchor missing: " .. old)
    return text:sub(1, s - 1) .. new .. text:sub(e + 1)
end

plant(main0, vb0)
for _, which in ipairs({ "forge-opencode", "forge-agent", "proxy" }) do
    local code, out = check(which)
    expect(code == 0 and out:find("ok:runtime-secret-mounts:" .. which, 1, true), "GREEN: " .. which .. " passes on the tree", out)
end

local token = "crate::vault_bootstrap::runtime_secret_volume(secret_name, GIT_VAULT_TOKEN_SECRET_OPTS),"
plant(replace_once(main0, token, token .. "\n            " .. token), vb0)
local code, out = check("forge-opencode")
expect(code == 1 and out:find("2 runtime-secret token mounts", 1, true), "RED: a second opencode token is a violation", out)

local crt = '"{}:/etc/squid/certs/intermediate.crt:ro",'
plant(replace_once(main0, crt, crt .. '\n            "{}/intermediate.key:/run/secrets/tillandsias-ca-key:ro",'), vb0)
code, out = check("proxy")
expect(code == 1 and out:find("binds intermediate.key", 1, true), "RED: a durable intermediate.key bind is a violation", out)

local p = vb0:find("pub(crate) fn runtime_secret_path(", 1, true)
local e = vb0:find("\n}\n", p, true)
local durable = vb0:sub(1, p - 1) .. vb0:sub(p, e):gsub("unseal_key_file_path%(%)", "durable_state_dir()") .. vb0:sub(e + 1)
plant(main0, durable)
code, out = check("forge-agent")
expect(code == 1 and out:find("durable-path bind", 1, true), "RED: a helper that leaves the runtime dir is a violation", out)

proc.run{ argv = { "rm", "-rf", root } }
if fails > 0 then
    verdict.emit("violation:runtime-secret-mounts-fixture:" .. fails, 1)
end
verdict.emit("ok:runtime-secret-mounts-fixture:6", 0)
