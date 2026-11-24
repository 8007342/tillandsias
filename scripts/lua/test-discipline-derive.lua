-- @trace order:1446-664f, order:2312-d2gf, spec:branch-discipline
--
-- test-discipline-derive.lua — `tillandsias-plan discipline derive` and the
-- reality check it gives `check-ref` (operator 2026-09-27: "We should try to
-- derive the discipline but check against reality"). Scratch projects with
-- scratch bare origins. Ported from the .sh (2312-d2gf).
--
--   1 one committer, no integration branch, no seed -> derived=0 seed=none
--     effective=0, check-ref main is ok at level 0; a never-fetched project
--     says so instead of looking like level 0
--   2 a level-2 seed over that project -> check-ref main WARNS
--     :seed-ahead-of-reality, naming the missing qualifier, and does not refuse
--   3 no seed, origin has linux-next and work/1446-664f, two authors ->
--     derived=2 seed=none and the `discipline raise --to 2` affordance; no refusal
--   4 that two-host project with THIS seed: derived=2 seed=2 effective=2 and
--     main is refused (enforced). THIS repository's main stays refused from the
--     seed, whatever its rolling last-50 window derives
--   5 derive --json names every observation with the command that made it
--
-- Verdict: ok:discipline-derive:5/5 | fail:discipline-derive:<passed>/5 | skip:discipline-derive:no-plan-binary

local fixture = require "common.fixture"
local T = fixture.new("discipline-derive")
local ROOT = fixture.repo_root()
local PLAN = fixture.plan_binary()
if PLAN == "" then T:skip("no-plan-binary") end
local W = T:scratch()
-- A forge exports an anonymised identity that overrides the per-commit ones, so
-- every author collapses into one (1446-xqi6: 4/5 with it set).
local DROP = { "GIT_*", "TILLANDSIAS_*" }

local function g(email, ...)
    local a = { "git", "-c", "init.defaultBranch=main", "-c", "user.name=fixture", "-c", "user.email=" .. email,
        "-c", "commit.gpgsign=false", ... }
    a.env_unset = DROP
    return T:must(a)
end
local ONE, TWO = "one@host-a.test", "two@host-b.test"
local function project(name)
    local d, bare = W.abs .. "/" .. name, W.abs .. "/" .. name .. ".git"
    g(ONE, "init", "-q", "--bare", bare)
    g(ONE, "clone", "-q", bare, d)
    g(ONE, "-C", d, "commit", "-q", "--allow-empty", "-m", "initial")
    g(ONE, "-C", d, "push", "-q", "origin", "main")
    g(ONE, "-C", d, "remote", "set-head", "origin", "main")
    g(ONE, "-C", d, "fetch", "-q", "origin")
    return d
end
local function seed(name)
    fs.mkdir(W.rel .. "/" .. name .. "/.tillandsias")
    fs.write(W.rel .. "/" .. name .. "/.tillandsias/branch-discipline.yaml", fs.read(".tillandsias/branch-discipline.yaml"))
end
local function dis(root, ...)
    local a = { PLAN, "discipline", ... }
    a[#a + 1] = "--root"; a[#a + 1] = root
    a.env_unset = DROP
    local r = T:run(a)
    local o = (r.stdout or "") .. (r.stderr or "")
    return { o = o, rc = r.code, first = text.lines(o)[1] or "", out = r.stdout or "" }
end
local function derive(root) return dis(root, "derive") end
local function main_of(root) return dis(root, "check-ref", "refs/heads/main") end
local function says(d, l) return ("\n" .. d.o .. "\n"):find("\n" .. l .. "\n", 1, true) ~= nil end
local function starts(d, l) return ("\n" .. d.o):find("\n" .. l, 1, true) ~= nil end
local function show(...)
    local t = {}
    for _, d in ipairs({ ... }) do t[#t + 1] = "rc=" .. tostring(d.rc) .. " [" .. d.o .. "]" end
    return table.concat(t, " | ")
end

local p1 = project("p1")
local d1, c1 = derive(p1), main_of(p1)
g(ONE, "init", "-q", W.abs .. "/nofetch")
g(ONE, "-C", W.abs .. "/nofetch", "commit", "-q", "--allow-empty", "-m", "x")
local dn = derive(W.abs .. "/nofetch")
T:arm("1 derived=0 seed=none effective=0; main is ok at level 0; a never-fetched project gets the fetch note",
    d1.first == "derived=0 seed=none effective=0" and c1.rc == 0 and c1.first == "ok:discipline:default-branch:level=0"
    and not starts(d1, "note: no refs/remotes/origin") and starts(dn, "note: no refs/remotes/origin/* here"), show(d1, c1, dn))

local p2 = project("p2"); seed("p2")
local c2 = main_of(p2)
local remedy = false
for _, l in ipairs(text.lines(c2.o)) do
    if l:find("^remedy: ") and l:find("an integration branch on origin other than the default branch", 1, true) then remedy = true end
end
T:arm("2 seed 2 over a bare project warns :seed-ahead-of-reality naming the missing qualifier, rc 0",
    c2.rc == 0 and c2.first == "warn:discipline:default-branch-protected:seed-ahead-of-reality" and remedy, show(c2))

local p3 = project("p3")
g(ONE, "-C", p3, "push", "-q", "origin", "main:linux-next")
g(TWO, "-C", p3, "commit", "-q", "--allow-empty", "-m", "second")
g(ONE, "-C", p3, "push", "-q", "origin", "HEAD:refs/heads/work/1446-664f")
g(ONE, "-C", p3, "push", "-q", "origin", "HEAD:main")
g(ONE, "-C", p3, "fetch", "-q", "origin")
local d3, c3 = derive(p3), main_of(p3)
T:arm("3 derived=2 seed=none gives the raise --to 2 affordance; main not refused",
    d3.first == "derived=2 seed=none effective=0"
    and says(d3, "drift:seed-behind-reality: discipline raise --to 2; use /project-discipline for instructions")
    and c3.rc == 0, show(d3, c3))

seed("p3")
local d4, c4, live = derive(p3), main_of(p3), main_of(ROOT)
local function enforced(c)
    return c.rc == 1 and c.first == "refused:discipline:default-branch-protected:enforced" and says(c, "source=seed level=2 enforcement=enforced")
end
T:arm("4 two-host scratch derives 2 = seed 2; scratch and live main stay refused (source=seed level=2 enforced)",
    d4.first == "derived=2 seed=2 effective=2" and enforced(c4) and enforced(live), show(d4, c4, live))

local j = dis(p3, "derive", "--json")
local pr = T:run{ PLAN, "json", "get", "-c", ".observations[] | [.name, .command]", stdin = j.out, env_unset = DROP }
local pairs_out, all, named, hosts = pr.stdout or "", 0, 0, false
for _, l in ipairs(text.lines(pairs_out)) do
    if l ~= "" then
        all = all + 1
        if l:find('^%["[a-z_]*","git ') or l:find('^%["[a-z_]*","ls ') then named = named + 1 end
        if l:find('"distinct_committer_hosts","git log -n 50 --format=%ae', 1, true) then hosts = true end
    end
end
T:arm("5 derive --json names every observation with the command that made it", all >= 5 and named == all and hosts, named .. "/" .. all .. " [" .. pairs_out .. "]")

T:finish({ ok = function(n) return "ok:discipline-derive:" .. n .. "/5" end,
    fail = function(n) return "fail:discipline-derive:" .. (5 - n) .. "/5" end })
