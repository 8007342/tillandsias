-- @trace order:1998-mvrs
-- @env PATH
--
-- test-mirror-ca-trust-watch.lua — the git mirror's Vault Agent follows an
-- enclave CA rotation (images/git/entrypoint.sh, the 1998-mvrs (b) block),
-- sourced exactly as shipped with start_vault_agent stubbed to count restarts:
--   1 SAME     an unchanged certificate restarts nothing
--   2 ROTATE   a valid new CA restarts the Agent once and logs ok:ca-rotated
--   3 INVALID  a non-CA, an expired CA and garbage are each refused by name,
--              the Agent is NOT restarted, and a repeat of the same bad
--              certificate is not reported again (no loop)
--   4 RECOVER  a valid CA after a bad one restarts the Agent once
--   5 FLOOR    CA_TRUST_POLL_SECS below 60 is raised to 60
-- Red before 1998-mvrs (b): the block did not exist.
--
-- Usage: tillandsias-plan script run scripts/lua/test-mirror-ca-trust-watch.lua

local EP = "images/git/entrypoint.sh"
local src = fs.read(EP) or ""
local s = src:find("# 1998-mvrs (b): follow an enclave CA rotation", 1, true)
local e = src:find("# CA certificate from podman secret.", 1, true)
if not s or not e then
    verdict.emit("violation:mirror-ca-trust-watch:no-subject", 1, "the 1998-mvrs (b) block is not in " .. EP)
end
local BLOCK = src:sub(s, e - 1)
local PATHV = env.get("PATH") or "/usr/bin:/bin"
local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
local REL = "target/plan-scratch/mw" .. tostring(math.random(100000, 999999))
local DIR = ROOT .. "/" .. REL
for _, d in ipairs({ "trust", "certs" }) do fs.mkdir(REL .. "/" .. d) end
fs.write(REL .. "/block.sh", BLOCK)

local function mint(name, extra)
    local argv = { "openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1",
        "-nodes", "-keyout", DIR .. "/certs/" .. name .. ".key", "-out", DIR .. "/certs/" .. name .. ".crt",
        "-subj", "/O=Tillandsias/CN=Tillandsias CA" }
    for _, a in ipairs(extra) do argv[#argv + 1] = a end
    local r = proc.run({ argv = argv, env = { PATH = PATHV }, timeout_ms = 60000 })
    if r.code ~= 0 then verdict.could_not_run("mirror-ca-trust-watch", "openssl req failed") end
end
mint("a", { "-days", "30", "-addext", "basicConstraints=critical,CA:TRUE" })
mint("b", { "-days", "30", "-addext", "basicConstraints=critical,CA:TRUE" })
mint("c", { "-days", "30", "-addext", "basicConstraints=critical,CA:TRUE" })
mint("leaf", { "-days", "30", "-addext", "basicConstraints=critical,CA:FALSE" })
mint("old", { "-not_before", "20200101000000Z", "-not_after", "20200102000000Z",
    "-addext", "basicConstraints=critical,CA:TRUE" })
fs.write(REL .. "/certs/junk.crt", "-----BEGIN CERTIFICATE-----\nnot a cert\n-----END CERTIFICATE-----\n")

-- One shell session: source the block, stub the Agent start, then apply each
-- step (copy a cert into the trust dir, run one check) and print a marker.
local steps = { "a", "a", "b", "leaf", "leaf", "old", "junk", "c" }
local script = { "set -u", "CA_TRUST_DIR='" .. DIR .. "/trust'", "VAULT_AGENT_PID_FILE='" .. DIR .. "/none.pid'",
    "CA_TRUST_POLL_SECS=5", ". '" .. DIR .. "/block.sh'", "echo floor=$CA_TRUST_POLL_SECS",
    "RESTARTS=0", "start_vault_agent() { RESTARTS=$((RESTARTS + 1)); return 0; }",
    "cp '" .. DIR .. "/certs/a.crt' '" .. DIR .. "/trust/intermediate.crt'",
    "CA_TRUST_SEEN=\"$(ca_trust_digest)\"; CA_TRUST_REFUSED=''" }
for i, n in ipairs(steps) do
    script[#script + 1] = "cp '" .. DIR .. "/certs/" .. n .. ".crt' '" .. DIR .. "/trust/intermediate.crt'"
    script[#script + 1] = "ca_trust_check 2>&1; echo step" .. i .. "=" .. n .. " restarts=$RESTARTS"
end
fs.write(REL .. "/run.sh", table.concat(script, "\n") .. "\n")
local r = proc.run({ argv = { "bash", DIR .. "/run.sh" }, env = { PATH = PATHV }, timeout_ms = 120000 })
local o = (r.stdout or "") .. (r.stderr or "")
local function restarts_at(i) return tonumber(o:match("step" .. i .. "=%S+ restarts=(%d+)")) end
local function count(n) local c = 0; for _ in o:gmatch(n:gsub("%p", "%%%0")) do c = c + 1 end; return c end

local failed, passed = {}, 0
local function arm(name, cond)
    if cond then
        passed = passed + 1
        out.line("ok:   " .. name)
    else
        out.line("FAIL: " .. name .. " — got: " .. o:gsub("\n", " | "))
        failed[#failed + 1] = name
    end
end
arm("1 SAME an unchanged certificate restarts nothing", restarts_at(1) == 0 and restarts_at(2) == 0)
arm("2 ROTATE a valid new CA restarts the Agent once", restarts_at(3) == 1 and count("ok:ca-rotated:") >= 1
    and o:find("ok:vault-agent-restarted", 1, true) ~= nil)
arm("3 INVALID bad certificates are refused by name, no restart, no repeat report",
    restarts_at(4) == 1 and restarts_at(5) == 1 and restarts_at(6) == 1 and restarts_at(7) == 1
    and count("is not a CA certificate") == 1 and count("has expired") == 1
    and count("does not parse as an X.509 certificate") == 1
    and count("Vault Agent keeps the previous CA") == 3)
arm("4 RECOVER a valid CA after a bad one restarts once", restarts_at(8) == 2)
arm("5 FLOOR the poll interval is never under a minute", o:find("floor=60", 1, true) ~= nil)

proc.run({ argv = { "rm", "-rf", DIR }, timeout_ms = 30000 })
if #failed > 0 then
    verdict.emit("violation:mirror-ca-trust-watch:" .. table.concat(failed, ","), 1, passed .. " passed")
end
verdict.ok("mirror-ca-trust-watch", passed .. " arms")
