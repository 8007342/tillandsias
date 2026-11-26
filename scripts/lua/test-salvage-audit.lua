-- @env PATH HOME TILLANDSIAS_SALVAGE_AUDIT_LIVE SALVAGE_AUDIT_TIMEOUT_S
-- @trace order:1226-jb8y, order:1672-8i7t, order:2270-7gp6, order:2386-zxgc
--
-- test-salvage-audit.lua — salvage-audit.sh finds the salvage and work refs, labels which side a
-- differing file moved on, and refuses what it cannot judge. Ported from the .sh of the same name
-- (2386-zxgc). By default it audits a constructed repository; TILLANDSIAS_SALVAGE_AUDIT_LIVE=1 (the
-- --daily-full gate) audits this checkout's own refs instead.
--
--   0 an audit killed at the ceiling is named a timeout, never parsed
--   1 the lookup finds the refs   1b the header names both surfaces, and both are counted
--   2 a differing file carries a direction   2b a constructed stale snapshot is labelled is-AHEAD
--   3 the output says ancestry is not the test   4 a bad branch, 5 an empty pattern, 6 a bad or
--   valueless argument: each refused or skipped by name
--
-- The .sh's arms 7 and 7b (a captured transcript piped into an early-exiting grep under pipefail)
-- were about the .sh's own spelling; a Lua string search has no pipe to lose.
--
-- Usage: tillandsias-plan script run scripts/lua/test-salvage-audit.lua
-- Verdict: ok:salvage-audit:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("salvage-audit")
local SH, ROOT = fixture.posix_shell(), fixture.repo_root()
local CHECK = ROOT .. "/scripts/salvage-audit.sh"
local CEILING = tonumber(env.get("SALVAGE_AUDIT_TIMEOUT_S") or "") or 900
-- The audit, killed at a ceiling. A cut-short run is reported as such, and never parsed.
local function audit(repo, script, ceiling, ...)
    local r = proc.run{ argv = { SH, script, ... }, cwd = repo, env = { PATH = env.get("PATH"), HOME = env.get("HOME") }, env_unset = { "TILLANDSIAS_*", "GIT_*" }, timeout_ms = (ceiling or CEILING) * 1000 }
    if r.status == "timed_out" then return { timeout = true, why = "timeout after " .. (ceiling or CEILING) .. "s" } end
    local o = ((r.stdout or "") .. (r.stderr or "")):gsub("\r", "")
    local last = ""
    -- The verdict is the last line of stdout; the commentary is on stderr.
    for l in (r.stdout or ""):gsub("\r", ""):gmatch("[^\n]+") do last = l end
    return { out = "\n" .. o, last = last, why = o:sub(-500) }
end
local function refs(repo, ns)
    local n = 0
    for _ in (T:run{ "git", "-C", repo, "for-each-ref", "--format=%(refname)", "refs/remotes/origin/" .. ns }.stdout or ""):gmatch("[^\n]+") do n = n + 1 end
    return n
end
-- A repository of commits at fixed times: base, then `branch edit` on linux-next, and refs that diverge from base.
local function repo(build)
    local g = T:scratch()
    local function git(...) return T:must{ "git", "-C", g.abs, "-c", "user.name=salvfix", "-c", "user.email=salvfix@example.invalid", "-c", "commit.gpgsign=false", ... } end
    local function commit(at, msg) T:must{ SH, "-s", "--", g.abs, at, msg, stdin = 'cd "$1" && GIT_AUTHOR_DATE="$2 +0000" GIT_COMMITTER_DATE="$2 +0000" git -c user.name=salvfix -c user.email=salvfix@example.invalid -c commit.gpgsign=false commit -qm "$3"\n' } end
    T:must{ "git", "init", "-q", g.abs }
    fs.mkdir(g.rel .. "/scripts"); fs.write(g.rel .. "/scripts/salvage-audit.sh", fs.read("scripts/salvage-audit.sh"))
    fs.write(g.rel .. "/VERSION", "v1\n"); git("add", "-A"); commit("1700000000", "base")
    local base = text.trim(git("rev-parse", "HEAD").stdout)
    fs.write(g.rel .. "/VERSION", "v2\n"); git("add", "VERSION"); commit("1700001000", "branch edit")
    local tip = text.trim(git("rev-parse", "HEAD").stdout)
    git("update-ref", "refs/remotes/origin/linux-next", tip)
    build(g, git, commit, base)
    git("checkout", "-q", tip)
    return g, tip
end
T:arm("PREMISE the subject is executable", T:run{ "test", "-x", CHECK }.code == 0, CHECK)

local AUD, x
if env.get("TILLANDSIAS_SALVAGE_AUDIT_LIVE") == "1" then
    AUD = ROOT
    x = audit(ROOT, CHECK)
else
    out.line("not-run:salvage-audit:live-refs — this audits a constructed repository; the audit of this checkout's own refs runs on the --daily-full gate (TILLANDSIAS_SALVAGE_AUDIT_LIVE=1, 2270-7gp6)")
    local g = repo(function(g, git, commit, base)
        git("update-ref", "refs/remotes/origin/work/ancestor", base)
        git("checkout", "-q", base); fs.write(g.rel .. "/VERSION", "stale\n"); git("add", "VERSION"); commit("1700000940", "stale snapshot")
        git("update-ref", "refs/remotes/origin/salvage/stale", "HEAD")
        git("checkout", "-q", base); fs.write(g.rel .. "/VERSION", "newer\n"); git("add", "VERSION"); commit("1700002000", "newer work")
        git("update-ref", "refs/remotes/origin/work/newer", "HEAD")
    end)
    AUD = g.abs
    x = audit(AUD, AUD .. "/scripts/salvage-audit.sh")
end
if x.timeout then T:refuse("timeout", x.why .. " — raise SALVAGE_AUDIT_TIMEOUT_S on this host; the audit's cost grows with the ref count (1672-8i7t)") end

local w = T:scratch()
fs.write(w.rel .. "/slow.sh", '#!/usr/bin/env bash\necho "    crates/x.rs  linux-next-is-AHEAD (stale snapshot)"\nexec sleep 30\n')
local slow = audit(w.abs, w.abs .. "/slow.sh", 1)
T:arm("0 a subject killed at a 1 s ceiling is a timeout, not a parsed row", slow.timeout == true and slow.why == "timeout after 1s", tostring(slow.why))

local salv, work = refs(AUD, "salvage"), refs(AUD, "work")
local n = tonumber(x.last:match("^ok:salvage%-audit:(%d+)r:"))
if salv == 0 then out.line("skip: 1 no salvage refs here")
else T:arm("1 the lookup finds the salvage refs", n ~= nil and n > 0, x.last) end
if salv + work == 0 then out.line("skip: 1b neither salvage nor work refs here")
else
    T:arm("1b the header names both surfaces", x.out:find("patterns=[^\n]*salvage[^\n]*work") ~= nil, x.why)
    T:arm("1b and audits both", n ~= nil and n >= salv + work, tostring(n) .. " of " .. (salv + work))
end
-- A finding line, not the legend on stderr that names the same label.
local STALE = "\n    %S+  %S+%-is%-AHEAD %(stale snapshot%)"
local _, stale = x.out:gsub(STALE, "")
local _, relay = x.out:gsub("ref%-may%-be%-AHEAD", "")
local _, absent = x.out:gsub("ABSENT%-from%-", "")
if stale > 0 then T:arm("2 differing files carry a direction", true, "")
elseif x.last:find(":0w:", 1, true) then out.line("skip:salvage-audit:nothing-differs")
elseif relay + absent > 0 then out.line("skip:salvage-audit:no-stale-snapshot:" .. (relay + absent) .. "-labelled-differences")
else T:arm("2 differing files carry a direction", false, x.why) end

local probe, probe_tip = repo(function(g, git, commit, base)
    git("checkout", "-q", base); fs.write(g.rel .. "/VERSION", "arm2probe-1226\n"); git("add", "VERSION"); commit("1700000940", "arm2probe-1226 stale snapshot")
    git("update-ref", "refs/remotes/origin/arm2probe-1226/stale", "HEAD")
end)
local y = audit(probe.abs, probe.abs .. "/scripts/salvage-audit.sh", 120, "--branch", probe_tip, "--pattern", "refs/heads/arm2probe-1226/")
T:arm("2b a constructed stale snapshot is labelled is-AHEAD", not y.timeout and (y.out or ""):find(STALE) ~= nil, y.why)
T:arm("3 the output says ancestry is not the integration test", x.out:upper():find("ANCESTRY IS NOT USED", 1, true) ~= nil, x.why)
local function last(...) local z = audit(AUD, CHECK, 60, ...); return z.timeout and "timeout" or z.last end
T:arm("4 an unresolvable branch refuses", last("--branch", "refs/heads/no-such-branch-1226"):match("^fail:salvage%-audit:bad%-branch:") ~= nil, last("--branch", "refs/heads/no-such-branch-1226"))
T:arm("5 a pattern matching nothing is skipped, not clean", last("--pattern", "refs/heads/no-such-prefix-1226/"):match("^skipped:salvage%-audit:no%-refs:") ~= nil, "")
T:arm("6 an unknown argument examines nothing", last("--no-such-flag"):match("^fail:salvage%-audit:unknown%-argument:") ~= nil, "")
for _, f in ipairs{ "--branch", "--pattern", "--remote" } do
    local z = audit(AUD, CHECK, 10, f)
    T:arm("6 " .. f .. " with no value refuses and terminates", not z.timeout and z.last:match("^fail:salvage%-audit:missing%-value:") ~= nil, z.timeout and "hung" or z.last)
end
T:finish()
