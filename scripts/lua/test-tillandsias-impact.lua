-- @trace order:2005-ccli
-- @env PATH
--
-- test-tillandsias-impact.lua — the forge's dry-run impact planner (2005-ccli
-- slice 2), on a project that is neither tillandsias nor kumbia nor a game:
-- a documentation site whose outputs are rendered pages and a PDF, with
-- modes none < restyle (CSS only) < rerender < full.
--   1 RESTYLE  a theme colour edit restyles every page, rerenders nothing,
--              and the estimate is cheap (0 units, no gpu)
--   2 NARROW   a title edit on one page rerenders only that page and the
--              PDF (which depends on every title); other pages stay none
--   3 MAX      an output that sees two edits takes the costliest mode
--   4 DEFAULT  an unmatched change takes the rules' default (full)
--   5 UNREACH  a change no output depends on is warned about, not dropped
--   6 WARN     a rules warn pattern adds its message
--   7 DRY      only --report is written; the inputs are byte-identical and
--              the report dir holds exactly the report
--   8 GIT      --from REV:PATH reads the old definition from git
--   9 INVALID  a graph output with no depends_on refuses impact_graph_invalid
--              and writes no report
--  10 RULES    a modes list not starting with "none" refuses impact_rules_invalid
--  11 HELP     --help answers the usage
-- Red before 2005-ccli: the tool did not exist.
--
-- Usage: tillandsias-plan script run scripts/lua/test-tillandsias-impact.lua

local TOOL = "images/default/cli/tillandsias-impact"
if not fs.exists(TOOL) then
    verdict.emit("violation:tillandsias-impact:no-subject", 1, TOOL .. " does not exist")
end
local py = proc.run({ argv = { "python3", "-c", "print(1)" }, timeout_ms = 30000 })
if py.status ~= "exited" or py.code ~= 0 then
    verdict.could_not_run("tillandsias-impact", "python3 is not available on this host")
end
local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.status ~= "exited" or top.code ~= 0 or ROOT == "" then
    verdict.could_not_run("tillandsias-impact", "git rev-parse --show-toplevel did not answer")
end
local REL = "target/plan-scratch/ti" .. tostring(math.random(100000, 999999))
fs.mkdir(REL .. "/site")
fs.mkdir(REL .. "/reports")
local DIR = ROOT .. "/" .. REL

local failed, passed = {}, 0
local function arm(name, cond, got)
    if cond then
        passed = passed + 1
        out.line("ok:   " .. name)
    else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got):gsub("\n", " | "))
        failed[#failed + 1] = name
    end
end
local function has(s, needle) return (s or ""):find(needle, 1, true) ~= nil end

local function run(args, cwd)
    local argv = { "python3", ROOT .. "/" .. TOOL }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local r = proc.run({ argv = argv, cwd = cwd, env = { PATH = env.get("PATH") or "/usr/bin:/bin", HOME = DIR },
        timeout_ms = 60000 })
    return r.code, r.stdout or "", r.stderr or ""
end
-- One field of one output in the report, via python's json (no regex on JSON).
local function q(report, expr)
    local r = proc.run({ argv = { "python3", "-c",
        "import json,sys;r=json.load(open(sys.argv[1]));print(json.dumps(" .. expr .. ",sort_keys=True))", report },
        timeout_ms = 30000 })
    return text.trim(r.stdout or "")
end

local OLD = '{"theme":{"colour":"#224488","font":"serif"},"pages":{"intro":{"title":"Intro","body":"Hello"},'
    .. '"install":{"title":"Install","body":"Run it"}},"build":{"engine":"v1"},"meta":{"owner":"docs-team"}}'
fs.write(REL .. "/site/old.json", OLD)
fs.write(REL .. "/graph.json", [[{"outputs":[
 {"id":"html.intro","depends_on":["theme.**","pages.intro.**","build.**"],"key":"k-intro"},
 {"id":"html.install","depends_on":["theme.**","pages.install.**","build.**"]},
 {"id":"pdf.manual","depends_on":["theme.font","pages.*.title","pages.*.body","build.**"]}]}]])
fs.write(REL .. "/rules.json", [[{"modes":["none","restyle","rerender","full"],
 "classes":[{"match":"theme.colour","mode":"restyle"},{"match":"pages.*.title","mode":"rerender"},
            {"match":"pages.*.body","mode":"rerender"},{"match":"theme.font","mode":"rerender"}],
 "default":"full",
 "cost":{"restyle":{"units":0,"gpu":false},"rerender":{"units":1,"gpu":false},"full":{"units":5,"gpu":true}},
 "warn":[{"match":"theme.colour","message":"check contrast against the body text"}]}]])

local function variant(name, new)
    fs.write(REL .. "/site/" .. name .. ".json", new)
    local rep = DIR .. "/reports/" .. name .. ".json"
    local c, o, e = run({ "plan", "--graph", DIR .. "/graph.json", "--from", DIR .. "/site/old.json",
        "--to", DIR .. "/site/" .. name .. ".json", "--rules", DIR .. "/rules.json", "--report", rep })
    return c, o, e, rep
end

local c, o, e, rep = variant("colour", OLD:gsub("#224488", "#AA2200", 1))
arm("1 RESTYLE colour restyles pages only, cheap", c == 0
    and q(rep, "r['outputs']['html.intro']['mode']") == '"restyle"'
    and q(rep, "r['outputs']['pdf.manual']['mode']") == '"none"'
    and q(rep, "r['estimate']") == '{"gpu": false, "units": 0}'
    and has(o, '"report_path"'), c .. " " .. o .. e)
arm("6 WARN the colour warning is reported", has(q(rep, "r['warnings']"), "check contrast"), q(rep, "r['warnings']"))

c, o, e, rep = variant("title", OLD:gsub('"Install"', '"Installing"', 1))
arm("2 NARROW a title rerenders its page and the pdf only", c == 0
    and q(rep, "r['outputs']['html.install']['mode']") == '"rerender"'
    and q(rep, "r['outputs']['pdf.manual']['mode']") == '"rerender"'
    and q(rep, "r['outputs']['html.intro']['mode']") == '"none"'
    and q(rep, "r['totals']") == '{"full": 0, "none": 1, "rerender": 2, "restyle": 0}', c .. " " .. q(rep, "r['totals']") .. e)

c, o, e, rep = variant("both", OLD:gsub("#224488", "#AA2200", 1):gsub('"Intro"', '"Welcome"', 1))
arm("3 MAX two edits take the costliest mode", c == 0
    and q(rep, "r['outputs']['html.intro']['mode']") == '"rerender"'
    and q(rep, "r['outputs']['html.intro']['fields']") == '["pages.intro.title", "theme.colour"]'
    and q(rep, "r['outputs']['html.intro']['key']") == '"k-intro"', q(rep, "r['outputs']['html.intro']"))

c, o, e, rep = variant("engine", OLD:gsub('"v1"', '"v2"', 1))
arm("4 DEFAULT an unmatched change is full", c == 0
    and q(rep, "r['totals']['full']") == "3" and q(rep, "r['estimate']") == '{"gpu": true, "units": 15}', q(rep, "r['estimate']"))

c, o, e, rep = variant("owner", OLD:gsub("docs%-team", "web-team", 1))
arm("5 UNREACH a change nothing depends on is warned", c == 0 and q(rep, "r['totals']['none']") == "3"
    and has(q(rep, "r['warnings']"), "meta.owner: changed, but no output depends on it"), q(rep, "r['warnings']"))

local listing = proc.run({ argv = { "ls", "-A", DIR .. "/reports" }, timeout_ms = 10000 })
arm("7 DRY only reports were written, inputs unchanged", fs.read(REL .. "/site/old.json") == OLD
    and text.trim(listing.stdout or "") == "both.json\ncolour.json\nengine.json\nowner.json\ntitle.json", listing.stdout)

-- 8 GIT: a scratch repo whose HEAD holds the old definition.
fs.mkdir(REL .. "/repo")
local R = DIR .. "/repo"
local function g(...) return proc.run({ argv = { "git", "-C", R, ... }, timeout_ms = 30000 }) end
g("init", "-q")
fs.write(REL .. "/repo/site.json", OLD)
g("add", "site.json")
g("-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid", "commit", "-q", "-m", "old")
fs.write(REL .. "/repo/site.json", OLD:gsub('"Install"', '"Installing"', 1))
c, o, e = run({ "plan", "--graph", DIR .. "/graph.json", "--from", "HEAD:site.json", "--to", R .. "/site.json",
    "--rules", DIR .. "/rules.json", "--report", DIR .. "/git-report.json" }, R)
arm("8 GIT --from REV:PATH reads git", c == 0 and q(DIR .. "/git-report.json", "r['totals']['rerender']") == "2", c .. " " .. o .. e)

fs.write(REL .. "/graph-bad.json", '{"outputs":[{"id":"html.intro","depends_on":[]}]}')
c, o, e = run({ "plan", "--graph", DIR .. "/graph-bad.json", "--from", DIR .. "/site/old.json", "--to", DIR .. "/site/old.json",
    "--rules", DIR .. "/rules.json", "--report", DIR .. "/bad-report.json" })
arm("9 INVALID empty depends_on refuses, no report", c == 2 and has(e, "refused:tillandsias-impact:impact_graph_invalid")
    and not fs.exists(REL .. "/bad-report.json"), c .. " " .. e)

fs.write(REL .. "/rules-bad.json", '{"modes":["cheap","full"]}')
c, o, e = run({ "plan", "--graph", DIR .. "/graph.json", "--from", DIR .. "/site/old.json", "--to", DIR .. "/site/old.json",
    "--rules", DIR .. "/rules-bad.json", "--report", DIR .. "/bad2.json" })
arm("10 RULES modes must start with none", c == 2 and has(e, "impact_rules_invalid") and not fs.exists(REL .. "/bad2.json"), c .. " " .. e)

c, o = run({ "--help" })
arm("11 HELP answers the usage", c == 0 and has(o, "Usage: tillandsias-impact plan"), c .. " " .. o)

proc.run({ argv = { "rm", "-rf", DIR }, timeout_ms = 30000 })
if #failed > 0 then
    verdict.emit("violation:tillandsias-impact:" .. table.concat(failed, ","), 1, passed .. " passed")
end
verdict.ok("tillandsias-impact", passed .. " arms")
