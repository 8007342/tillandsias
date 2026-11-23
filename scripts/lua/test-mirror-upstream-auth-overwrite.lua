-- @trace order:2235-zkmx
--
-- test-mirror-upstream-auth-overwrite.lua — a successful relay push must
-- OVERWRITE a stale `denied` upstream-auth verdict with `authorized`, so a
-- mirror that recovered stops advertising a credential failure it no longer
-- has. Ported from test-mirror-upstream-auth-overwrite.sh (2235-zkmx).
--
--   1 premise: a recorded denied verdict is published
--   2 a successful relay push overwrites denied with authorized (one ref)
--   3 control: trunk's pre-fix relay pushed but left denied standing
--     (a named skip once trunk's relay carries the fix)
--   4 --record refuses an unknown state (rc 2) and publishes nothing
--
-- Every git call runs with a private HOME and global config and a fixture
-- identity, so nothing reaches the real git config.
--
-- Verdict: ok:mirror-upstream-auth-overwrite:<pass>/<total>
--        | violation:mirror-upstream-auth-overwrite:<pass>/<total>

local root = text.trim(proc.run{ argv = { "pwd", "-P" } }.stdout or "")
local pass, failn = 0, 0
local function ok(m) out.line("ok:   " .. m); pass = pass + 1 end
local function bad(m) out.line("FAIL: " .. m); failn = failn + 1 end

local rel = "target/plan-scratch/upstream-auth-overwrite-" .. tostring(time.now_ms())
local WORK = root .. "/" .. rel
proc.run{ argv = { "mkdir", "-p", WORK .. "/home" } }
fs.write(rel .. "/gitconfig", "")
local function cleanup() proc.run{ argv = { "find", WORK, "-delete" }, timeout_ms = 60000 } end
local ENV = {
    GIT_AUTHOR_NAME = "fixture", GIT_AUTHOR_EMAIL = "fixture@example.invalid",
    GIT_COMMITTER_NAME = "fixture", GIT_COMMITTER_EMAIL = "fixture@example.invalid",
    HOME = WORK .. "/home", GIT_CONFIG_NOSYSTEM = "1", GIT_CONFIG_GLOBAL = WORK .. "/gitconfig",
}
local function run(argv, extra)
    local e = {}
    for k, v in pairs(ENV) do e[k] = v end
    for k, v in pairs(extra or {}) do e[k] = v end
    local r = proc.run{ argv = argv, env = e, cwd = extra and extra._cwd or nil, stdin = extra and extra._stdin or nil, timeout_ms = 120000 }
    return text.trim(r.stdout or ""), r.code
end
local function git(...) return run({ "git", ... }) end

local PROBE = WORK .. "/probe-upstream-auth"
fs.write(rel .. "/probe-upstream-auth", fs.read("images/git/probe-upstream-auth.sh"))
proc.run{ argv = { "chmod", "+x", PROBE } }

local function verdicts(d) return (git("-C", d, "for-each-ref", "--format=%(refname)", "refs/tillandsias/upstream-auth")) end
local function setup(d)
    git("init", "-q", "--bare", d .. "/upstream")
    git("init", "-q", "--bare", d .. "/mirror")
    git("-C", d .. "/mirror", "remote", "add", "origin", d .. "/upstream")
    git("init", "-q", d .. "/client")
    git("-C", d .. "/client", "commit", "-q", "--allow-empty", "-m", "one")
    git("-C", d .. "/client", "push", "-q", d .. "/mirror", "HEAD:refs/heads/main")
end
local function relay(mirror, script)
    local new = git("-C", mirror, "rev-parse", "refs/heads/main")
    local cleaned = {}
    for k, v in pairs({ AUTH_PROBE = PROBE, SYNC_STATE = "/nonexistent" }) do cleaned[k] = v end
    cleaned._cwd = mirror
    cleaned._stdin = new .. " " .. new .. " refs/heads/main\n"
    run({ "sh", script }, cleaned)
end
local function pushed(d)
    local v, rc = git("-C", d .. "/upstream", "rev-parse", "-q", "--verify", "refs/heads/main")
    if rc ~= 0 or v == "" then return "none" end
    return v
end
local function count_lines(s)
    local n = 0
    for _, l in ipairs(text.lines(s)) do if l ~= "" then n = n + 1 end end
    return n
end

-- 1 + 2
local A = WORK .. "/a"; proc.run{ argv = { "mkdir", "-p", A } }; setup(A)
run({ PROBE, "--record", A .. "/mirror", "denied", "permission" })
local v = verdicts(A .. "/mirror")
if v:find("^refs/tillandsias/upstream%-auth/denied/permission/") then ok("1 premise: a recorded denied verdict is published")
else bad("1 premise: no denied verdict: [" .. v .. "]") end
relay(A .. "/mirror", root .. "/images/git/relay-refs.sh")
local p = pushed(A); v = verdicts(A .. "/mirror")
if p ~= "none" and count_lines(v) == 1 and v:find("^refs/tillandsias/upstream%-auth/authorized/") then
    ok("2 a successful relay push overwrites denied with authorized (one ref)")
else bad("2 after a successful push: upstream=" .. p .. " verdicts=[" .. v .. "]") end

-- 3 control against trunk's relay, while trunk's relay predates the fix
local has_trunk = proc.run{ argv = { "git", "-C", root, "cat-file", "-e", "origin/linux-next:images/git/relay-refs.sh" } }.code == 0
local trunk_relay = has_trunk and (proc.run{ argv = { "git", "-C", root, "show", "origin/linux-next:images/git/relay-refs.sh" } }.stdout or "") or ""
if has_trunk and not trunk_relay:find("record_upstream_auth", 1, true) then
    local B = WORK .. "/b"; proc.run{ argv = { "mkdir", "-p", B } }; setup(B)
    fs.write(rel .. "/relay-prefix.sh", trunk_relay)
    run({ PROBE, "--record", B .. "/mirror", "denied", "permission" })
    relay(B .. "/mirror", WORK .. "/relay-prefix.sh")
    p = pushed(B); v = verdicts(B .. "/mirror")
    if p ~= "none" and v:find("^refs/tillandsias/upstream%-auth/denied/") then ok("3 control: the pre-fix relay pushed but left denied standing")
    else bad("3 control: pre-fix upstream=" .. p .. " verdicts=[" .. v .. "]") end
else
    out.line("skip: 3 control: trunk's relay already carries the fix (or no origin/linux-next)")
end

-- 4
local C = WORK .. "/c"; proc.run{ argv = { "mkdir", "-p", C } }
git("init", "-q", "--bare", C .. "/mirror")
local _, rc = run({ PROBE, "--record", C .. "/mirror", "bogus" })
v = verdicts(C .. "/mirror")
if rc == 2 and v == "" then ok("4 --record refuses an unknown state (rc=2) and publishes nothing")
else bad("4 --record bogus: rc=" .. tostring(rc) .. " verdicts=[" .. v .. "]") end

cleanup()
local total = pass + failn
if failn == 0 then verdict.ok("mirror-upstream-auth-overwrite:" .. pass .. "/" .. total) end
verdict.emit("violation:mirror-upstream-auth-overwrite:" .. pass .. "/" .. total, 1)
