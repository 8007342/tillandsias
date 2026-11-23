-- @trace order:2252-ck7h
-- @env TILLANDSIAS_SCRIPT_RUNNER_BIN TILLANDSIAS_PLAN_BIN CARGO_TARGET_DIR
--
-- test-smoke-attest.lua — the REAL attest-smoke.lua and check-smoke-attested.lua
-- in a scratch repo. Promotion needs a PASS per platform; a partial blocks.
--
--   1 a partial attests, and the checker REFUSES it (darwin=partial:credential-unmeasured)
--   2 `pass` without a measured credential step is refused, nothing written
--   3 evidence older than 00-run-start is refused (a previous run's file)
--   4 a pass on the same sha upgrades the ref (the partial is its parent) and the checker passes
--   5 a platform with no ref blocks (msys=missing)
--   6 a ref copied under another sha's name does not count for that sha
--   7 --version <tag> resolves to the RC commit
--
-- GRAMMAR ok:smoke-attest:7 | violation:smoke-attest:<n>-failed

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.code ~= 0 or ROOT == "" then verdict.could_not_run("smoke-attest", "no repo") end
local BIN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") or env.get("TILLANDSIAS_PLAN_BIN") or ""
if BIN == "" then
    local ctd = env.get("CARGO_TARGET_DIR") or ""
    BIN = (ctd ~= "" and ctd or ROOT .. "/target") .. "/release/tillandsias-plan"
end
if BIN:sub(1, 2) == "./" then BIN = ROOT .. "/" .. BIN:sub(3) end
if proc.run({ argv = { "test", "-x", BIN }, timeout_ms = 10000 }).code ~= 0 then
    verdict.could_not_run("smoke-attest", "no plan binary at " .. BIN)
end

local S = ROOT .. "/target/plan-scratch/smoke-attest-" .. time.iso_utc():gsub("[^%w]", "") .. "-" .. math.random(100000, 999999)
local R, E = S .. "/repo", S .. "/repo/ev"
local GENV = { GIT_AUTHOR_NAME = "f", GIT_AUTHOR_EMAIL = "f@x", GIT_COMMITTER_NAME = "f", GIT_COMMITTER_EMAIL = "f@x",
               GIT_CONFIG_GLOBAL = "/dev/null", GIT_CONFIG_NOSYSTEM = "1", TILLANDSIAS_SMOKE_HOST = "fixturehost" }
local function sh(argv, cwd)
    local r = proc.run({ argv = argv, cwd = cwd or R, env = GENV, timeout_ms = 120000 })
    return (r.status == "exited") and r.code or -1, text.trim((r.stdout or "") .. (r.stderr or ""))
end
local function git(...) local a = { "git", "-C", R, "-c", "commit.gpgsign=false" }
    for _, x in ipairs({ ... }) do a[#a + 1] = x end
    local c, o = sh(a); if c ~= 0 then verdict.could_not_run("smoke-attest", "setup: " .. o) end; return o end
local function script(name, ...)
    local a = { BIN, "script", "run", ROOT .. "/scripts/lua/" .. name, "--" }
    for _, x in ipairs({ ... }) do a[#a + 1] = x end
    return sh(a)
end

sh({ "mkdir", "-p", E }, ROOT)
git("init", "-q", "-b", "main")
fs.write(text.trim(R:sub(#ROOT + 2)) .. "/.gitignore", "ev/\n")
git("add", "-A"); git("commit", "-qm", "rc")
local RC = git("rev-parse", "HEAD")
git("tag", "v0.0.1-rc")
git("commit", "-q", "--allow-empty", "-m", "other")
local OTHER = git("rev-parse", "HEAD")
local ASSET = string.rep("ab", 32)
local REL = R:sub(#ROOT + 2) .. "/ev"
local function evidence(cred)
    sh({ "rm", "-rf", E }, ROOT); sh({ "mkdir", "-p", E }, ROOT)
    fs.write(REL .. "/00-run-start.txt", "run_start=x\n")
    sh({ "touch", "-t", "202001010000", E .. "/00-run-start.txt" }, ROOT)
    fs.write(REL .. "/03-diagnose-exit.txt", "diagnose_exit=0\n")
    if cred then fs.write(REL .. "/credential-step.txt", cred .. "\n") end
end

local failed = {}
local function arm(name, cond, got)
    if cond then out.line("ok:   " .. name) else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got):gsub("\n", " | ")); failed[#failed + 1] = name end
end
local function attest(v, ...) return script("attest-smoke.lua", "--sha", RC, "--tag", "v0.0.1-rc",
    "--asset-sha256", ASSET, "--verdict", v, "--dir", E, "--platform", "darwin", ...) end
local REF = "refs/attest/smoke/darwin/" .. RC

evidence("unmeasured: operator has not signed in")
local c, o = attest("partial:credential-unmeasured")
local c2, o2 = script("check-smoke-attested.lua", "--sha", RC, "--platforms", "darwin")
arm("1 a partial attests and the checker refuses it", c == 0 and c2 == 1
    and text.contains(o2, "darwin=partial:credential-unmeasured"), "attest rc=" .. c .. " " .. o .. " / check rc=" .. c2 .. " " .. o2)
local partial = git("rev-parse", REF)

c, o = attest("pass")
arm("2 pass without a measured credential step is refused, nothing written",
    c == 2 and text.contains(o, "refused:attest-smoke:pass-needs-measured-credential-step") and git("rev-parse", REF) == partial,
    "rc=" .. c .. " " .. o)

evidence("measured: operator signed in from the tray")
sh({ "touch", "-t", "201901010000", E .. "/03-diagnose-exit.txt" }, ROOT)
c, o = attest("pass")
arm("3 evidence older than the run start is refused", c == 2 and text.contains(o, "refused:attest-smoke:stale-evidence"),
    "rc=" .. c .. " " .. o)

evidence("measured: operator signed in from the tray")
c, o = attest("pass")
local parent = select(2, sh({ "git", "-C", R, "rev-parse", REF .. "^" }))
c2, o2 = script("check-smoke-attested.lua", "--sha", RC, "--platforms", "darwin")
arm("4 a pass upgrades the ref (partial is its parent) and the checker passes",
    c == 0 and parent == partial and c2 == 0 and text.contains(o2, "ok:smoke-attested:" .. RC .. ":darwin"),
    "attest rc=" .. c .. " parent=" .. parent .. " check rc=" .. c2 .. " " .. o2)

c2, o2 = script("check-smoke-attested.lua", "--sha", RC, "--platforms", "darwin,msys")
arm("5 a platform with no ref blocks", c2 == 1 and text.contains(o2, "msys=missing"), "rc=" .. c2 .. " " .. o2)

git("update-ref", "refs/attest/smoke/darwin/" .. OTHER, git("rev-parse", REF))
c2, o2 = script("check-smoke-attested.lua", "--sha", OTHER, "--platforms", "darwin")
arm("6 a ref copied under another sha's name does not count", c2 == 1 and text.contains(o2, "darwin=missing"),
    "rc=" .. c2 .. " " .. o2)

c2, o2 = script("check-smoke-attested.lua", "--version", "v0.0.1-rc", "--platforms", "darwin")
arm("7 --version resolves to the RC commit", c2 == 0 and text.contains(o2, "ok:smoke-attested:" .. RC), "rc=" .. c2 .. " " .. o2)

proc.run({ argv = { "rm", "-rf", S }, timeout_ms = 60000 })
if #failed > 0 then verdict.emit("violation:smoke-attest:" .. #failed .. "-failed", 1) end
verdict.ok("smoke-attest", "7")
