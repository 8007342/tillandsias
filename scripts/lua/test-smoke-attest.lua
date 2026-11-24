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
--   8 a token planted in a lane log reaches no object reachable from the ref (2299-atdg)
--   9 the tree is exactly SHA256SUMS, regime.txt, verdict.txt, with right digests
--  10 a round archived inside the evidence dir is neither stale nor digested
--  11 a raw-tree attest in the ref's history is refused (it would ride along on --push)
--  12 an evidence file whose NAME is unsafe is refused without echoing it
--  13 --regime is what regime.txt says; a regime that is not a slug is refused
--
-- GRAMMAR ok:smoke-attest:13 | violation:smoke-attest:<n>-failed

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

-- ── 2299-atdg: the tree is digests only ─────────────────────────────────────
-- Every arm below uses a FRESH platform name, so each ref starts empty.
local TOKEN = "ghp_" .. "FAKEtoken0123456789abcdefABCDEF0123"
local function objects_hold(ref, needle)
    -- EVERY object reachable from the ref, not only the tip tree: commits,
    -- trees and blobs of the whole chain.
    local _, list = sh({ "git", "-C", R, "rev-list", "--objects", ref })
    for _, l in ipairs(text.lines(list)) do
        local id = l:match("^(%x+)")
        if id then
            local _, body = sh({ "git", "-C", R, "cat-file", "-p", id })
            if text.contains(body, needle) then return true end
        end
    end
    return false
end
local function attest_as(plat, v, ...) return script("attest-smoke.lua", "--sha", RC, "--tag", "v0.0.1-rc",
    "--asset-sha256", ASSET, "--verdict", v, "--dir", E, "--platform", plat, ...) end

-- 8 TOKEN: a lane log holding a token, attested; no reachable object holds it.
evidence("unmeasured: operator has not signed in " .. TOKEN)
fs.write(REL .. "/04-lane.log", "device code url https://example.invalid/?code=" .. TOKEN .. "\n")
c, o = attest_as("tokenarm", "partial:credential-unmeasured")
local REF8 = "refs/attest/smoke/tokenarm/" .. RC
local leaked = c == 0 and objects_hold(REF8, TOKEN)
-- Control: the needle search can see the token where it really is.
local _, rawblob = sh({ "git", "-C", R, "hash-object", E .. "/04-lane.log" })
arm("8 a token in a lane log reaches no object reachable from the ref", c == 0 and not leaked
    and select(2, sh({ "git", "-C", R, "cat-file", "-t", rawblob })) ~= "blob",
    "rc=" .. c .. " leaked=" .. tostring(leaked) .. " " .. o)

-- 9 SHAPE: exactly three names; SHA256SUMS digests every evidence file, right.
local _, names = sh({ "git", "-C", R, "ls-tree", "--name-only", REF8 })
local _, sums = sh({ "git", "-C", R, "show", REF8 .. ":SHA256SUMS" })
local _, reg = sh({ "git", "-C", R, "show", REF8 .. ":regime.txt" })
local _, ver = sh({ "git", "-C", R, "show", REF8 .. ":verdict.txt" })
local _, want = sh({ BIN, "hash", "sha256", E .. "/04-lane.log" })
arm("9 the tree is SHA256SUMS, regime.txt, verdict.txt and the digests are right",
    names == "SHA256SUMS\nregime.txt\nverdict.txt" and reg == "tokenarm" and ver == "partial:credential-unmeasured"
    and text.contains(sums, (want:match("^(%x+)") or "?") .. "  04-lane.log") and text.contains(sums, "  credential-step.txt")
    and not text.contains(ver, "operator"),
    names .. " / " .. sums .. " / " .. reg .. " / " .. ver)

-- 10 ARCHIVED: a previous round archived INSIDE the dir is neither stale nor digested.
evidence("unmeasured: operator has not signed in")
sh({ "mkdir", "-p", E .. "/_archived-20200101t000000z" }, ROOT)
fs.write(REL .. "/_archived-20200101t000000z/03-old.log", "old round\n")
sh({ "touch", "-t", "201901010000", E .. "/_archived-20200101t000000z/03-old.log" }, ROOT)
c, o = attest_as("archarm", "partial:credential-unmeasured")
local _, sums10 = sh({ "git", "-C", R, "show", "refs/attest/smoke/archarm/" .. RC .. ":SHA256SUMS" })
arm("10 an archived round inside the evidence dir is neither stale nor digested",
    c == 0 and not text.contains(sums10, "_archived") and text.contains(sums10, "03-diagnose-exit.txt"), "rc=" .. c .. " " .. o .. " / " .. sums10)

-- 11 HISTORY: an old raw-tree attest in the chain is refused, nothing written.
evidence("unmeasured: operator has not signed in")
local REF11 = "refs/attest/smoke/histarm/" .. RC
local rawtree = git("write-tree")   -- the scratch repo's own tree: not the digest shape
local rawc = git("commit-tree", rawtree, "-m", "old raw-tree attest")
git("update-ref", REF11, rawc)
c, o = attest_as("histarm", "partial:credential-unmeasured")
arm("11 a raw-tree commit in the ref's history is refused and the ref is unmoved",
    c == 2 and text.contains(o, "refused:attest-smoke:raw-tree-in-history:") and git("rev-parse", REF11) == rawc,
    "rc=" .. c .. " " .. o)

-- 12 NAME: an evidence file whose NAME is unsafe is refused, and not echoed.
evidence("unmeasured: operator has not signed in")
fs.write(REL .. "/code " .. "SECRETNAME.txt", "x\n")
c, o = attest_as("namearm", "partial:credential-unmeasured")
arm("12 an unsafe evidence file name is refused without echoing it",
    c == 2 and text.contains(o, "refused:attest-smoke:unsafe-evidence-name") and not text.contains(o, "SECRETNAME"),
    "rc=" .. c .. " " .. o)

-- 13 REGIME: --regime is what regime.txt says, and a regime that is not a slug is refused.
evidence("unmeasured: operator has not signed in")
c, o = attest_as("regarm", "partial:credential-unmeasured", "--regime", "darwin-arm64")
local _, reg13 = sh({ "git", "-C", R, "show", "refs/attest/smoke/regarm/" .. RC .. ":regime.txt" })
local cb, ob = attest_as("regarm2", "partial:credential-unmeasured", "--regime", "bad regime")
arm("13 --regime is written to regime.txt and a non-slug regime is refused",
    c == 0 and reg13 == "darwin-arm64" and cb == 2 and text.contains(ob, "refused:attest-smoke:"), "rc=" .. c .. " " .. reg13 .. " / " .. cb .. " " .. ob)

proc.run({ argv = { "rm", "-rf", S }, timeout_ms = 60000 })
if #failed > 0 then verdict.emit("violation:smoke-attest:" .. #failed .. "-failed", 1) end
verdict.ok("smoke-attest", "13")
