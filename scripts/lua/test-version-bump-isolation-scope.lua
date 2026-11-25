-- @trace spec:methodology-accountability, order:723-b9cn, order:2165-vcgh, order:2361-y7pf
--
-- test-version-bump-isolation-scope.lua — the DEFAULT SCOPE of check-version-bump-isolation.lua. A branch
-- answers for what it AUTHORS, not for what it accepts by the mandated merge: the old @{upstream}..HEAD
-- range refused commits already published on origin and left osx-next unpushable. Case 2 is the
-- load-bearing one: "check nothing" passes case 1. Ported from the .sh of the same name.
--
-- Usage: tillandsias-plan script run scripts/lua/test-version-bump-isolation-scope.lua
-- Verdict: ok:version-bump-isolation-scope:<n> arms | violation:version-bump-isolation-scope:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("version-bump-isolation-scope")
local PLAN, ROOT = fixture.plan_binary(), fixture.repo_root()
local CHECK = "scripts/lua/check-version-bump-isolation.lua"
if not fs.exists(CHECK) then T:refuse("checker-missing", CHECK) end
if PLAN == "" then T:refuse("no-plan-binary") end

local R = T:git_repo()
local function git(...)
    local argv = { "git", "-C", R.abs }
    for _, a in ipairs{ ... } do argv[#argv + 1] = a end
    return text.trim(T:must(argv).stdout or "")
end
local function commit(msg, files)
    for f, body in pairs(files) do
        local dir = f:match("^(.*)/")
        if dir then fs.mkdir(R.rel .. "/" .. dir) end
        fs.write(R.rel .. "/" .. f, body)
    end
    git("add", "-A")
    git("commit", "-qm", msg)
    return git("rev-parse", "HEAD")
end
-- The checker asks git about $PWD, so it is named.
local function guard(args, subject)
    local argv = { PLAN, "script", "run", subject or (ROOT .. "/" .. CHECK), "--" }
    for _, a in ipairs(args or {}) do argv[#argv + 1] = a end
    local r = proc.run{ argv = argv, cwd = R.abs, timeout_ms = 60000, env_unset = { "TILLANDSIAS_*" }, env = { PWD = R.abs } }
    return r.code, (r.stdout or "") .. (r.stderr or "")
end
local function arm(name, want_rc, want, args, subject)
    local rc, o = guard(args, subject)
    T:arm(name, rc == want_rc and text.contains(o, want), "rc=" .. tostring(rc) .. " " .. o)
end
git("config", "core.autocrlf", "false")
local base = commit("base", { VERSION = "v1\n", ["Cargo.toml"] = "x\n" })

-- This branch's own remote head, lagging, with an upstream tracking it: the production shape.
git("remote", "add", "origin", "https://example.invalid/repo.git")
git("update-ref", "refs/remotes/origin/platform", "HEAD")
git("branch", "-q", "--set-upstream-to=origin/platform")

-- A sweep authored by another host, then published.
local foreign = commit("sweep authored elsewhere", { VERSION = "v2\n", ["src/main.rs"] = "code\n" })
git("update-ref", "refs/remotes/origin/linux-next", foreign)
git("update-ref", "refs/remotes/origin/main", foreign)
arm("0 precondition: the published commit IS a sweep when asked", 1, "verdict=version-swept-with-unrelated-files", { "--commit", foreign })
arm("1 a published sweep is not policed by default", 0, "verdict=ok:nothing-to-examine")

-- MUTATION, on arm 1's tree: the old upstream range refuses what origin already has.
local src = fs.read(CHECK):gsub("\r\n", "\n")
local W = T:scratch("mutant")
local function mutant(name, from, to)
    local a, b = src:find(from, 1, true)
    if not a then T:refuse("mutation-anchor-missing", name) end
    fs.write(W.rel .. "/" .. name .. ".lua", src:sub(1, a - 1) .. to .. src:sub(b + 1))
    return W.abs .. "/" .. name .. ".lua"
end
arm("5 MUTATION the old upstream range refuses the published sweep", 1, foreign:sub(1, 12), nil, mutant("upstream", 'if ok(refs) and text.trim(refs.stdout or "") ~= "" then', "if false then"))

local own = commit("sweep authored HERE, unpublished", { VERSION = "v3\n", ["src/main.rs"] = "more\n" })
arm("2 a local, unpublished sweep is refused by name", 1, own:sub(1, 12))
arm("5 MUTATION a scope narrowed to nothing lets it through", 0, "verdict=ok:nothing-to-examine", nil,
    mutant("nothing", '"HEAD", "--not", "--remotes=origin"', '"HEAD", "--not", "HEAD"'))

git("checkout", "-q", "-b", "release/version-bump-test", foreign)
commit("clean release bump", { VERSION = "v9\n", ["Cargo.toml"] = "y\n" })
arm("3 a clean local release bump passes", 0, "version-touching=1")

git("checkout", "-q", "-b", "platform", base)
commit("platform work", { ["platform.txt"] = "work\n" })
git("merge", "-q", "--no-ff", "--no-edit", foreign, "-m", "merge: integration catch-up")
arm("4 a merge inheriting a foreign VERSION is exempt", 0, "violations=0")

T:finish()
