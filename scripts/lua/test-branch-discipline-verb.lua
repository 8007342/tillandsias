-- @env PATH HOME
-- @trace order:1443-w79y, order:2366-7zvv
--
-- test-branch-discipline-verb.lua — `tillandsias-plan discipline` answers from the project's seed
-- at the level the history has reached. Ported from the .sh of the same name (2366-7zvv). Every
-- repository is scratch; this checkout's seed is only read.
--
--   1 the platform targets                 2 main refused, a work ref ok, another ref warned here;
--     under a strict seed it warns with one committer host and is refused with two
--   3 no seed: level 0, nothing refused    4 the digest is the seed's sha256
--   5 a seed that contradicts itself is refused at load and level 0 answers
--   6 the MCP server lists discipline_show and returns the verb's JSON
--
-- Usage: tillandsias-plan script run scripts/lua/test-branch-discipline-verb.lua
-- Verdict: ok:branch-discipline-verb:<n> arms | violation:... | skip:branch-discipline-verb:...

local fixture = require "common.fixture"
local T = fixture.new("branch-discipline-verb")
local SH, PLAN, ROOT = fixture.posix_shell(), fixture.plan_binary(), fixture.repo_root()
if PLAN == "" then T:skip("no-plan-binary") end
local SEED = fs.read(".tillandsias/branch-discipline.yaml"):gsub("\r", "")
local d = T:scratch()
local function dis(...)
    local r = proc.run{ argv = { PLAN, "discipline", ... }, cwd = ROOT, env = { PATH = env.get("PATH"), HOME = env.get("HOME") }, env_unset = { "TILLANDSIAS_*", "GIT_*" }, timeout_ms = 60000 }
    local o, e = (r.stdout or ""):gsub("\r", ""), (r.stderr or ""):gsub("\r", "")
    return { rc = r.code, out = o, err = e, all = o .. e, first = (o .. e):match("^[^\n]*"), why = "rc=" .. tostring(r.code) .. " " .. (o .. e):sub(1, 500) }
end
local function has(x, l) return text.contains("\n" .. x.all, "\n" .. l) end
local function seed(name, from, to)
    local s, n = SEED:gsub(from:gsub("%p", "%%%0"), (to:gsub("%%", "%%%%")), 1)
    if n ~= 1 then T:refuse("seed-changed", "the seed has no " .. from) end
    fs.write(d.rel .. "/" .. name, s)
    return d.abs .. "/" .. name
end
for _, t in ipairs{ { "macos", "osx-next" }, { "forge", "linux-next" } } do
    local x = dis("target", "--platform", t[1], "--root", ROOT)
    T:arm("1 the " .. t[1] .. " target is " .. t[2], x.rc == 0 and text.trim(x.all) == t[2] .. " source=seed level=2 enforcement=-", x.why)
end
local x = dis("check-ref", "refs/heads/main", "--root", ROOT)
T:arm("2a main is refused, with the seeded remedy", x.rc == 1 and x.first == "refused:discipline:default-branch-protected:enforced" and has(x, "why: ")
    and has(x, "remedy: push to main denied: this project uses branch linux-next|osx-next|windows-next for integration and work/"), x.why)
x = dis("check-ref", "refs/heads/work/1443-w79y", "--root", ROOT)
T:arm("2b a work ref is ok", x.rc == 0 and x.first == "ok:discipline:work-ref", x.why)
x = dis("check-ref", "refs/heads/feature-x", "--root", ROOT)
T:arm("2c a ref outside the grammar only warns", x.rc == 0 and x.first == "warn:discipline:ref-outside-grammar", x.why)

local STRICT = seed("strict.yaml", "ref_grammar: warn", "ref_grammar: enforced")
local p, origin = T:git_repo(), T:scratch("origin")
T:must{ "git", "init", "-q", "--bare", origin.abs }
local function git(...) return T:must{ "git", "-C", p.abs, ... } end
git("remote", "add", "origin", origin.abs)
git("-c", "user.email=another@example.invalid", "commit", "-q", "--allow-empty", "-m", "same-host")
git("push", "-q", "origin", "HEAD:refs/heads/main", "HEAD:refs/heads/linux-next", "HEAD:refs/heads/work/1443-w79y")
git("remote", "set-head", "origin", "main"); git("fetch", "-q", "origin")
x = dis("derive", "--root", p.abs)
T:arm("2d one committer host derives level 1", x.first == "derived=1 seed=none effective=0", x.why)
x = dis("check-ref", "refs/heads/feature-x", "--root", p.abs, "--seed", STRICT)
T:arm("2e a strict seed ahead of the history only warns, saying what would reach it", x.rc == 0 and x.first == "warn:discipline:ref-outside-grammar:seed-ahead-of-reality"
    and x.all:find("\nremedy: [^\n]*two or more distinct committer hosts %(by author email domain%)") ~= nil, x.why)
git("-c", "user.email=fixture@host-b.test", "commit", "-q", "--allow-empty", "-m", "second-host")
git("push", "-q", "origin", "HEAD:refs/heads/main", "HEAD:refs/heads/work/1443-w79y"); git("fetch", "-q", "origin")
x = dis("derive", "--root", p.abs)
T:arm("2f two hosts and a work ref derive level 2", x.first == "derived=2 seed=none effective=0", x.why)
x = dis("check-ref", "refs/heads/feature-x", "--root", p.abs, "--seed", STRICT)
T:arm("2g then it is refused, with why and the grammar", x.rc == 1 and x.first == "refused:discipline:ref-outside-grammar:enforced" and has(x, "why: ") and has(x, "remedy: name the branch by the grammar (work: work/"), x.why)

local bare = T:git_repo("bare")
x = dis("check-ref", "refs/heads/main", "--root", bare.abs)
local y = dis("check-ref", "refs/heads/anything-at-all", "--root", bare.abs)
T:arm("3 no seed is level 0: nothing is refused", x.rc == 0 and x.first == "ok:discipline:default-branch:level=0" and has(x, "source=default level=0 enforcement=advised\n") and y.rc == 0, x.why .. y.why)

local shown = dis("show", "--json", "--root", ROOT)
local h = T:run{ PLAN, "hash", "sha256", ROOT .. "/.tillandsias/branch-discipline.yaml" }
local want = text.trim(h.stdout or "")
T:arm("4 show --json carries the seed's sha256", #want == 64 and shown.rc == 0 and json.parse(shown.out).digest == want, shown.why)

local reg = T:git_repo("regressed")
T:must{ "git", "-C", reg.abs, "update-ref", "refs/tillandsias/discipline/2/enforced/0000/1", "HEAD" }
for _, c in ipairs{ { "an integration branch equal to the default", seed("eq.yaml", "macos: osx-next", "macos: main"), ROOT, "integration-equals-default:macos" },
    { "a bad work-ref regex", seed("re.yaml", "work/[0-9]{3,4}-[a-z0-9]{4}", "work/[0-9"), ROOT, "work-ref-regex" },
    { "a level below the recorded one", seed("low.yaml", "\nlevel: 2\n", "\nlevel: 1\n"), reg.abs, "level-regressed:1<2" } } do
    x = dis("show", "--json", "--root", c[3], "--seed", c[2])
    local ok, j = pcall(json.parse, x.out)
    T:arm("5 " .. c[1] .. " is refused at load and level 0 answers", text.contains(x.err, "refused:discipline-seed:" .. c[4]) and ok and j.source == "default" and j.level == 0, x.why)
end

local m = proc.run{ argv = { SH, ROOT .. "/images/default/config-overlay/mcp/forge-plan.sh" }, cwd = ROOT, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 60000,
    env = { PATH = env.get("PATH"), HOME = env.get("HOME"), TILLANDSIAS_PLAN_BIN = PLAN, TILLANDSIAS_PLAN_INDEX = ROOT .. "/plan/index.yaml" },
    stdin = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}\n{"jsonrpc":"2.0","id":2,"method":"tools/list"}\n{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"discipline_show","arguments":{}}}\n' }
local listed, said = false, nil
for l in (m.stdout or ""):gmatch("[^\r\n]+") do
    local ok, j = pcall(json.parse, l)
    if ok and j.id == 2 then
        for _, t in ipairs(j.result.tools) do listed = listed or t.name == "discipline_show" end
    elseif ok and j.id == 3 then said = j.result.content[1].text end
end
T:arm("6 the MCP server lists discipline_show and returns the verb's JSON", listed and said ~= nil and text.trim(said) == text.trim(shown.out), "listed=" .. tostring(listed) .. " " .. tostring(said):sub(1, 200) .. (m.stderr or ""):sub(1, 200))
T:finish()
