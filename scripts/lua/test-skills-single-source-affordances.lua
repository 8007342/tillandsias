-- @env PATH
-- @trace order:1247-amcu, order:631-wpkd, spec:methodology-accountability
--
-- test-skills-single-source-affordances.lua — every refusal of
-- scripts/check-skills-single-source.sh says WHY it refused and WHAT would
-- make it not a refusal (1247-amcu): labelled "  why:" / "  remedy:" lines on
-- stderr, beside its unchanged one-line stdout verdict.
--
-- A scratch git repo with one canonical skill and one runtime is bent three
-- ways and each refusal is RUN; the rest are pinned STATICALLY:
--   1 second-source  a real directory where a link belongs
--   2 absolute-link  a runtime link with an absolute target
--   3 dangling-link  a runtime link to an untracked path
--   4 STATIC every verdict site carries an _afford call on its line or the
--     line above, or an `affordance-ok:` marker on the line above.
--
-- Usage: tillandsias-plan script run scripts/lua/test-skills-single-source-affordances.lua
-- Verdict: ok:skills-single-source-affordances:<n> arms | violation:skills-single-source-affordances:<arm>

local SUBJECT = "scripts/check-skills-single-source.sh"
local arms, failed = 0, {}

local function arm(name, cond, detail)
    if cond then
        arms = arms + 1
        out.line("ok:   " .. name)
    else
        failed[#failed + 1] = name
        out.line("FAIL: " .. name .. " — " .. tostring(detail))
    end
end

local function afforded(err)
    return err:find("  why: %S") ~= nil and err:find("  remedy: %S") ~= nil
end

local root = text.trim(proc.run{ argv = { "pwd", "-P" } }.stdout or "")
local REL = "target/plan-scratch/sss-afford-" .. tostring(time.now_ms())

-- repo(name, setup): a fresh git repo with skills/alpha and a .rt runtime,
-- bent by `setup(dir)`, committed to the index.
local function repo(name, setup)
    local rel = REL .. "/" .. name
    local dir = root .. "/" .. rel
    fs.mkdir(rel .. "/skills/alpha")
    fs.write(rel .. "/skills/alpha/SKILL.md", "# alpha\n")
    fs.mkdir(rel .. "/.rt/skills")
    proc.run{ argv = { "git", "-C", dir, "init", "-q" } }
    setup(dir, rel)
    proc.run{ argv = { "git", "-C", dir, "add", "-A" } }
    return dir
end

local function check(dir)
    local r = proc.run{ argv = { "bash", SUBJECT }, timeout_ms = 30000,
        env = { SKILLS_CHECK_ROOT = dir, SKILLS_CHECK_RUNTIMES = ".rt" } }
    return r.code, text.trim(r.stdout or ""), r.stderr or ""
end

local rc, so, se = check(repo("second", function(_, rel)
    fs.mkdir(rel .. "/.rt/skills/alpha")
    fs.write(rel .. "/.rt/skills/alpha/SKILL.md", "# a copy\n")
end))
arm("1 second-source refuses with why and remedy",
    rc == 1 and so == "violation:second-source:.rt/skills/alpha" and afforded(se), "rc=" .. tostring(rc) .. " " .. so .. " | " .. se)

rc, so, se = check(repo("absolute", function(dir)
    proc.run{ argv = { "ln", "-s", dir .. "/skills/alpha", dir .. "/.rt/skills/alpha" } }
end))
arm("2 absolute-link refuses with why and remedy",
    rc == 1 and so:find("violation:absolute-link-target:.rt/skills/alpha", 1, true) == 1 and afforded(se), "rc=" .. tostring(rc) .. " " .. so .. " | " .. se)

rc, so, se = check(repo("dangling", function(dir)
    proc.run{ argv = { "ln", "-s", "../../skills/no-such-skill", dir .. "/.rt/skills/alpha" } }
end))
arm("3 dangling-link refuses with why and remedy",
    rc == 1 and so:find("violation:dangling-link:.rt/skills/alpha", 1, true) == 1 and afforded(se), "rc=" .. tostring(rc) .. " " .. so .. " | " .. se)

-- 4 static
local src = fs.read(SUBJECT) or ""
local prev, bare, n = "", {}, 0
for line in (src .. "\n"):gmatch("([^\n]*)\n") do
    n = n + 1
    local emits = (line:find('echo "violation:', 1, true) or line:find('echo "refused:', 1, true))
        and not line:match("^%s*#")
    if emits and not line:find("_afford ", 1, true) and not prev:find("_afford ", 1, true)
        and not prev:find("affordance-ok:", 1, true) then
        bare[#bare + 1] = tostring(n)
    end
    prev = line
end
arm("4 every verdict site carries _afford or an affordance-ok reason",
    #src > 0 and #bare == 0, "bare verdict lines: " .. table.concat(bare, ","))

proc.run{ argv = { "rm", "-rf", root .. "/" .. REL } }
if #failed > 0 then
    verdict.emit("violation:skills-single-source-affordances:" .. failed[1]:gsub("%s+", "-"), 1)
end
verdict.emit("ok:skills-single-source-affordances:" .. arms .. " arms", 0)
