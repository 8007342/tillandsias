-- @trace order:732-z8ef, order:756-2jnj, order:1561-47a8, order:2360-ud6i, spec:default-image
--
-- test-forge-validate.lua — scripts/forge-validate.sh classifies PASS, SKIP and FAIL
-- deterministically, over stub checks. Ported from the .sh (2360-ud6i).
--
--   1 a skipped and an eligible e2e row
--   2 every check failing: each row names its own verdict or exit code
--   3 BLOCKED is a named fault, surfaced verbatim, not invalid output (756-2jnj)
--   4 ABSENT is not failed: with no push route no push ran, so it is a SKIP (it once
--     printed FAIL exit:1 for a push nothing attempted)
--   5 check-forge-service-health.lua passes a healthy forge and names a down service
--
-- Verdict: ok:forge-validate:<n> arms | violation:forge-validate:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("forge-validate")
local ROOT = fixture.repo_root()
local SH = fixture.posix_shell()
local PLAN = fixture.plan_binary()
if PLAN == "" then T:refuse("no-plan-binary") end
local W = T:scratch()

local n = 0
local function stubs(t)
    n = n + 1
    local rel = W.rel .. "/c" .. n
    fs.mkdir(rel)
    for name, s in pairs(t) do
        fs.write(rel .. "/" .. name, "#!/bin/sh\nprintf '%s\\n' '" .. s[1] .. "'\nexit " .. (s[2] or 0) .. "\n")
        T:must{ "chmod", "+x", W.abs .. "/c" .. n .. "/" .. name }
    end
    return W.abs .. "/c" .. n
end
local function validate(t)
    local r = T:run{ SH, "scripts/forge-validate.sh", cwd = ROOT, env = { FORGE_VALIDATE_CHECK_DIR = stubs(t) }, env_unset = { "TILLANDSIAS_*" } }
    return r.code, text.trim(r.stdout or "")
end
local function base(over)
    local t = { credential = { "ok:fixture" }, push = { "dry-run fixture passed" }, workspace = { "workspace fixture passed" },
        headless = { "headless fixture passed" }, services = { "skip:not-forge-host" }, eligibility = { "eligible" } }
    for k, v in pairs(over or {}) do t[k] = v or nil end
    return t
end
local function rows(...) return table.concat({ ... }, "\n") end
local function ck(name, t, want_ok, want)
    local rc, o = validate(t)
    T:arm(name, (rc == 0) == want_ok and o == want, "rc=" .. tostring(rc) .. " " .. o:gsub("\n", " | "))
end
local PUSH, WORK, HEAD, SVC = "PASS push-route-dry-run", "PASS workspace-check", "PASS headless-tests", "SKIP service-health skip:not-forge-host"

ck("1 a skipped e2e row", base{ eligibility = { "skip:no-podman-binary" } }, true,
    rows("PASS credential-channel ok:fixture", PUSH, WORK, HEAD, SVC, "SKIP e2e-eligibility skip:no-podman-binary", "SUMMARY pass=4 skip=2 fail=0"))
ck("1 an eligible e2e row", base(), true,
    rows("PASS credential-channel ok:fixture", PUSH, WORK, HEAD, SVC, "PASS e2e-eligibility eligible", "SUMMARY pass=5 skip=1 fail=0"))
ck("2 every failing check names its own verdict or exit code", {
    credential = { "missing:no-credential-channel", 1 }, push = { "push fixture failed", 6 }, workspace = { "workspace fixture failed", 8 },
    headless = { "headless fixture failed", 7 }, services = { "failed:vault-health", 1 }, eligibility = { "unexpected" },
}, false, rows("FAIL credential-channel missing:no-credential-channel", "FAIL push-route-dry-run exit:6", "FAIL workspace-check exit:8",
    "FAIL headless-tests exit:7", "FAIL service-health failed:vault-health", "FAIL e2e-eligibility invalid-output", "SUMMARY pass=0 skip=0 fail=6"))
ck("3 a blocked credential is surfaced verbatim", base{ credential = { "blocked:upstream-push-unauthorized", 1 } }, false,
    rows("FAIL credential-channel blocked:upstream-push-unauthorized", PUSH, WORK, HEAD, SVC, "PASS e2e-eligibility eligible", "SUMMARY pass=4 skip=1 fail=1"))
local t = base(); t.push = nil
ck("4 an absent push route is a SKIP and does not fail the profile", t, true,
    rows("PASS credential-channel ok:fixture", "SKIP push-route-dry-run skip:no-branch-to-push", WORK, HEAD, SVC, "PASS e2e-eligibility eligible", "SUMMARY pass=4 skip=2 fail=0"))

local function health(services)
    local r = T:run{ PLAN, "script", "run", "scripts/lua/check-forge-service-health.lua", cwd = ROOT, env_unset = { "TILLANDSIAS_*" },
        env = { TILLANDSIAS_HOST_KIND = "forge", FORGE_SERVICE_HEALTH_CHECK_DIR = stubs{ services = { services }, vault = { "vault healthy" }, outbound = { "outbound healthy" } } } }
    return r.code, text.trim(r.stdout or "")
end
local UP = '{"name":"proxy","status":"up"},{"name":"git-service","status":"up"}'
local rc, o = health('{"services":[' .. UP .. ',{"name":"inference","status":"up"}]}')
T:arm("5 a healthy forge passes", rc == 0 and o == "ok:forge-services", "rc=" .. tostring(rc) .. " " .. o)
rc, o = health('{"services":[' .. UP .. "]}")
T:arm("5 a down service is named and fails", rc ~= 0 and o == "down:enclave-services", "rc=" .. tostring(rc) .. " " .. o)
T:finish()
