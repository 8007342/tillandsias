-- @trace order:1310-rec6, order:2234-gmmc
--
-- test-mirror-relay-state.lua — images/git/publish-relay-state.sh decides
-- "broken" after the tick's fetch, by failing layer, with hysteresis; a
-- rejected ref is per-ref and becomes "stuck" only after 3 consecutive ticks.
-- Ported from test-mirror-relay-state.sh (2234-gmmc).
--
-- Each arm builds an upstream U (bare, with a hooks dir), a work clone w and a
-- bare mirror M cloned from U, under a private HOME, then runs publisher ticks
-- against M.
--
--   ARM1 negative control: a head ahead of a STALE tracking ref, already upstream, is ok
--   ARM2 transport: degraded on tick 1, broken on tick 2 (hysteresis), ok after one good tick
--   ARM3 an authentication refusal is classed credential (not rejection), broken on tick 2
--   ARM4 a rejected ref never makes the mirror broken; tick 3 publishes one stuck-ref
--
-- Verdict: ok:mirror-relay-state:4 arms | violation:mirror-relay-state:<n> failed

local root = text.trim(proc.run{ argv = { "pwd", "-P" } }.stdout or "")
local PUB = root .. "/images/git/publish-relay-state.sh"
local failn, pass = 0, 0
local function ok(m) out.line("ok:   " .. m); pass = pass + 1 end
local function bad(m) out.line("FAIL: " .. m); failn = failn + 1 end

local rel = "target/plan-scratch/relay-state-" .. tostring(time.now_ms())
local W = root .. "/" .. rel
proc.run{ argv = { "mkdir", "-p", W .. "/home" } }
local function cleanup() proc.run{ argv = { "find", W, "-delete" }, timeout_ms = 60000 } end

fs.write(rel .. "/relay", "read -r _o _n ref\nexec git push origin \"$ref:$ref\"\n")
proc.run{ argv = { "chmod", "+x", W .. "/relay" } }
local ENV = { HOME = W .. "/home", GIT_CONFIG_NOSYSTEM = "1", RELAY_STATE_BACKOFF = "0 0 0", RELAY_REF = W .. "/relay" }
local function run(argv)
    local r = proc.run{ argv = argv, env = ENV, timeout_ms = 120000 }
    return text.trim(r.stdout or ""), r.code
end
local function git(...) return run({ "git", ... }) end
git("config", "--global", "user.email", "f@f")
git("config", "--global", "user.name", "f")
git("config", "--global", "init.defaultBranch", "main")

local function setup(name)   -- upstream U with one commit, mirror M cloned from it
    local d = W .. "/" .. name
    proc.run{ argv = { "mkdir", "-p", d .. "/U/hooks" } }
    git("init", "-q", "--bare", d .. "/U")
    proc.run{ argv = { "mkdir", "-p", d .. "/U/hooks" } }
    git("-C", d .. "/U", "config", "core.hooksPath", d .. "/U/hooks")
    git("init", "-q", d .. "/w")
    git("-C", d .. "/w", "commit", "-q", "--allow-empty", "-m", "base")
    git("-C", d .. "/w", "push", "-q", d .. "/U", "main")
    git("clone", "-q", "--bare", d .. "/U", d .. "/M")
    git("-C", d .. "/M", "config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*")
    git("-C", d .. "/M", "fetch", "-q", "origin")
    return d
end
local seq = 0
local function advance_mirror(d)   -- a new commit on the mirror's main (not on upstream)
    seq = seq + 1
    git("-C", d .. "/w", "commit", "-q", "--allow-empty", "-m", "next-" .. seq)
    git("-C", d .. "/w", "push", "-q", d .. "/M", "main")
end
local function state(d)
    local o = git("-C", d .. "/M", "for-each-ref", "--format=%(refname)", "refs/tillandsias/relay-state")
    local lines = {}
    for _, l in ipairs(text.lines(o)) do
        if l ~= "" then lines[#lines + 1] = (l:gsub("^refs/tillandsias/relay%-state/", ""):gsub("/%d*$", "")) end
    end
    return table.concat(lines, "\n")
end
local function stuck(d)
    local o = git("-C", d .. "/M", "for-each-ref", "--format=%(refname)", "refs/tillandsias/relay-state-stuck")
    local n = 0
    for _, l in ipairs(text.lines(o)) do if l ~= "" then n = n + 1 end end
    return n
end
local function tick(d) run({ "sh", PUB, d .. "/M" }) end
local function hook(d, body)
    fs.write(d:sub(#root + 2) .. "/U/hooks/pre-receive", body)
    proc.run{ argv = { "chmod", "+x", d .. "/U/hooks/pre-receive" } }
end

-- ARM1
local d = setup("a1")
git("-C", d .. "/w", "commit", "-q", "--allow-empty", "-m", "landed")
git("-C", d .. "/w", "push", "-q", d .. "/U", "main")
git("-C", d .. "/w", "push", "-q", d .. "/M", "main")
local ahead = tonumber((git("-C", d .. "/M", "rev-list", "--count", "refs/remotes/origin/main..refs/heads/main"))) or 0
if ahead <= 0 then bad("ARM1 setup: tracking was not stale") end
tick(d)
local s1 = state(d)
if s1 == "ok/none/0" then ok("ARM1 negative control: a head ahead of a STALE tracking ref, already upstream, is ok (" .. s1 .. "), not broken")
else bad("ARM1 stale tracking read as '" .. s1 .. "'") end

-- ARM2
d = setup("a2"); advance_mirror(d)
git("-C", d .. "/M", "remote", "set-url", "origin", W .. "/nowhere.git")
tick(d); s1 = state(d); tick(d); local s2 = state(d)
git("-C", d .. "/M", "remote", "set-url", "origin", d .. "/U"); tick(d); local s3 = state(d)
if s1 == "degraded/transport/1" and s2 == "broken/transport/1" and s3 == "ok/none/0" then
    ok("ARM2 transport: degraded on tick 1, broken on tick 2 (hysteresis), ok after one good tick")
else bad("ARM2 ticks: '" .. s1 .. "' then '" .. s2 .. "' then '" .. s3 .. "'") end

-- ARM3
d = setup("a3"); advance_mirror(d)
hook(d, "#!/bin/sh\necho \"remote: Invalid username or password.\"\necho \"fatal: Authentication failed for upstream\"\nexit 1\n")
tick(d); tick(d); s2 = state(d)
if s2 == "broken/credential/1" then ok("ARM3 an authentication refusal is classed credential (not rejection) and is broken on tick 2")
else bad("ARM3 credential refusal read as '" .. s2 .. "'") end

-- ARM4
d = setup("a4"); advance_mirror(d)
hook(d, "#!/bin/sh\necho \"refusing this ref by policy\"\nexit 1\n")
tick(d); local a = state(d) .. ":" .. stuck(d)
tick(d); local b = state(d) .. ":" .. stuck(d)
tick(d); local c = state(d) .. ":" .. stuck(d)
if a == "ok/none/0:0" and b == "ok/none/0:0" and c == "ok/none/0:1" then
    ok("ARM4 a rejected ref never makes the mirror broken; on the 3rd consecutive tick it publishes one stuck-ref")
else bad("ARM4 ticks: '" .. a .. "' '" .. b .. "' '" .. c .. "'") end

cleanup()
if failn == 0 then
    out.line("PASS: mirror-relay-state (1310-rec6)")
    verdict.ok("mirror-relay-state:" .. pass .. " arms")
end
out.line("FAILED: mirror-relay-state (1310-rec6)")
verdict.emit("violation:mirror-relay-state:" .. failn .. " failed", 1)
