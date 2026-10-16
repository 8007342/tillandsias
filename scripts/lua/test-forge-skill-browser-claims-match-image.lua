-- @trace order:1746-2szd
-- @env PATH TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-forge-skill-browser-claims-match-image.lua — the guard of 1746-2szd,
-- scripts/lua/check-forge-skill-browser-claims-match-image.lua, on this tree and
-- on constructed roots:
--   1 LIVE      this tree: no shipped doc claims a pre-installed browser
--   2 MUTATION  the forge-quick-intro SKILL.md at PRE_REV (the pre-fix wording)
--               is refused, naming the file, the line and the remedy
--   3 NEGATION  "not pre-installed" and "no browser ... pre-installed" lines
--               are not claims (NEGATIVE CONTROL for arm 2's matcher)
--   4 IMAGE     the same claim passes when a Containerfile installs chromium,
--               and is still refused when chromium only appears in a comment
--   5 ABSENT    no readable Containerfile is could-not-run, exit 3
--
-- Usage: tillandsias-plan script run scripts/lua/test-forge-skill-browser-claims-match-image.lua

local PRE_REV = "78c8f7e59"
local SKILL = "skills/forge-quick-intro/SKILL.md"
local SUBJECT_REL = "scripts/lua/check-forge-skill-browser-claims-match-image.lua"
if not fs.exists(SUBJECT_REL) then
    verdict.emit("violation:forge-browser-claims-fixture:no-subject", 1, SUBJECT_REL .. " does not exist (1746-2szd)")
end
local PLAN = env.get("TILLANDSIAS_PLAN_BIN")
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") end
if not PLAN or PLAN == "" then
    verdict.could_not_run("forge-browser-claims-fixture", "no plan binary named (TILLANDSIAS_PLAN_BIN or TILLANDSIAS_SCRIPT_RUNNER_BIN)")
end

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.status ~= "exited" or top.code ~= 0 or ROOT == "" then
    verdict.could_not_run("forge-browser-claims-fixture", "git rev-parse --show-toplevel did not answer")
end
local REL = "target/plan-scratch/forge-browser-claims-" .. time.iso_utc():gsub("[^%w]", "") .. "-" .. tostring(math.random(100000, 999999))
fs.mkdir(REL)

local failed = {}
local function arm(name, cond, got)
    -- The subject's output stays on this arm's ONE line: its own `violation:`
    -- line at the start of a line would read as this fixture's verdict.
    got = got and tostring(got):gsub("\n", " | ") or nil
    if cond then out.line("ok:   " .. name) else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got))
        failed[#failed + 1] = name
    end
end

-- run(docs, containerfiles) -> exit code, stdout. nil arguments keep the defaults.
local function run(docs, cfs)
    local e = {}
    if docs then e.TILLANDSIAS_BROWSER_CLAIM_DOCS = docs end
    if cfs then e.TILLANDSIAS_BROWSER_CLAIM_CONTAINERFILES = cfs end
    local r = proc.run({ argv = { PLAN, "script", "run", SUBJECT_REL }, cwd = ROOT, timeout_ms = 60000, env = e })
    return r.code or -1, text.trim(r.stdout or "")
end
local function docs_with(name, body)
    local d = REL .. "/" .. name
    fs.mkdir(d .. "/skills/x")
    fs.write(d .. "/skills/x/SKILL.md", body)
    return d .. "/skills"
end
local function containerfile(name, body)
    local f = REL .. "/" .. name .. ".Containerfile"
    fs.write(f, body)
    return f
end
local NO_BROWSER = containerfile("plain", "RUN microdnf install -y \\\n        git curl jq \\\n    && microdnf clean all\n")

-- ── 1 LIVE ─────────────────────────────────────────────────────────────────
local rc, o = run(nil, nil)
arm("1 LIVE this tree's skills, cheatsheets and agent instructions claim no pre-installed browser",
    rc == 0 and o:find("^ok:forge%-browser%-claims:docs=%d+:claims=0:image%-browsers=none$") ~= nil, rc .. " " .. o)

-- ── 2 MUTATION ─────────────────────────────────────────────────────────────
local pre = proc.run({ argv = { "git", "show", PRE_REV .. ":" .. SKILL }, cwd = ROOT, timeout_ms = 30000 })
local pre_line = "- **Web & Browsers:** Headless and headful Chrome debugging browsers are pre-installed and configured."
if pre.code ~= 0 or not (pre.stdout or ""):find(pre_line, 1, true) then
    arm("2 premise: " .. SKILL .. " at " .. PRE_REV .. " carries the pre-fix wording", false, pre.code)
else
    local d = docs_with("mutation", pre.stdout)
    rc, o = run(d, NO_BROWSER)
    arm("2 MUTATION the pre-fix forge-quick-intro is refused, naming the file, the line and the remedy",
        rc == 1 and o:find("violation:forge-browser-claims:claims=1:image-browsers=none", 1, true) ~= nil
        and o:find("claim: " .. d .. "/x/SKILL.md:13: " .. pre_line, 1, true) ~= nil
        and o:find("remedy: say the forge has no browser binary", 1, true) ~= nil, rc .. " " .. o)
end

-- ── 3 NEGATION ─────────────────────────────────────────────────────────────
rc, o = run(docs_with("negation", "# x\n\nChromium is not pre-installed in the forge.\n"
    .. "There is no browser pre-installed; use browser.open.\n"
    .. "pipx tools are pre-installed: ruff, black.\n"), NO_BROWSER)
arm("3 NEGATION negated claims and a pre-installed line naming no browser are not claims",
    rc == 0 and o:find(":claims=0:", 1, true) ~= nil, rc .. " " .. o)

-- ── 4 IMAGE ────────────────────────────────────────────────────────────────
local claim_docs = docs_with("claim", "# x\n\n" .. pre_line .. "\n")
rc, o = run(claim_docs, containerfile("chromium", "RUN microdnf install -y \\\n        git chromium jq\n"))
local ships_rc, ships_o = rc, o
rc, o = run(claim_docs, containerfile("comment", "# chromium was dropped in 2026\nRUN microdnf install -y git\n"))
arm("4 IMAGE the claim passes when a Containerfile installs chromium, and is refused when chromium is only a comment",
    ships_rc == 0 and ships_o:find("image-browsers=chromium", 1, true) ~= nil
    and rc == 1 and o:find("violation:forge-browser-claims:claims=1", 1, true) ~= nil,
    ships_rc .. " " .. ships_o .. " / " .. rc .. " " .. o)

-- ── 5 ABSENT ───────────────────────────────────────────────────────────────
rc, o = run(claim_docs, REL .. "/no-such.Containerfile")
arm("5 ABSENT no readable Containerfile is could-not-run, exit 3",
    rc == 3 and o:find("could-not-run:forge-browser-claims", 1, true) ~= nil, rc .. " " .. o)

proc.run({ argv = { "rm", "-rf", ROOT .. "/" .. REL }, timeout_ms = 30000 })
if #failed > 0 then
    verdict.emit("refused:forge-browser-claims-fixture:" .. #failed .. "-of-5", 1)
end
verdict.emit("ok:forge-browser-claims-fixture:5", 0)
