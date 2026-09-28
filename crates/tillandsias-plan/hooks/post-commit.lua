-- post-commit.lua — the embedded discipline template for git's post-commit event.
-- @trace order:1446-xqi6, spec:branch-discipline
--
-- ADVISORY ONLY: it never refuses (git ignores this event's exit status anyway),
-- and it prints nothing unless a qualifier appears. The qualifier here is the
-- one operator ruling 7 names: a project outgrowing level 0. At level 0, when
-- the last twenty commits carry two or more distinct committer identities, it
-- says so and names the skill that explains raising to level 1.
--
-- Contract as in pre-push.lua: arg[0] event, arg[1] plan binary, arg[2] host
-- kind, arg[3] OS, arg[4..] git's arguments; RETURN one verdict line. A project
-- may override this with .tillandsias/hooks/post-commit.lua.

local plan = arg[1]

local function err(line) io.stderr:write(line, "\n") end

local function skill_for(key, default)
  local ok, text = pcall(fs.read, ".tillandsias/branch-discipline.yaml")
  if ok and text then
    local pok, seed = pcall(yaml.parse, text)
    if pok and type(seed) == "table" and type(seed.skills) == "table" and seed.skills[key] then
      return tostring(seed.skills[key])
    end
  end
  return default
end

local show = proc.run{ argv = { plan, "discipline", "show", "--json" } }
local sok, d = pcall(json.parse, show.stdout or "")
local level = (sok and type(d) == "table" and tonumber(d.level)) or 0
if level ~= 0 then return "ok:hook:post-commit" end

local log = proc.run{ argv = { "git", "log", "-20", "--format=%cn <%ce>" } }
local seen, n = {}, 0
for who in (log.stdout or ""):gmatch("[^\n]+") do
  if not seen[who] then seen[who] = true; n = n + 1 end
end
if n < 2 then return "ok:hook:post-commit" end

err(n .. " committer identities in the last 20 commits: this project may have outgrown")
err("level 0 (anyone pushes to the default branch).")
err("this project at level 0 could use an integration branch and pull requests; use /"
  .. skill_for("level", "project-discipline") .. " for how to raise to level 1")
return "advised:hook:post-commit:multiple-committers"
