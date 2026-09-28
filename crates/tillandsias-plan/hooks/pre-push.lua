-- pre-push.lua — the embedded discipline template for git's pre-push event.
-- @trace order:1446-xqi6, spec:branch-discipline
--
-- Installed per project by `tillandsias-plan discipline install-hooks` and run
-- by `tillandsias-plan discipline hook pre-push` (sandboxed Lua). A project may
-- override it with .tillandsias/hooks/pre-push.lua, which wins over this copy.
--
-- CONTRACT (every template, and every override):
--   arg[0] event, arg[1] the plan binary, arg[2] TILLANDSIAS_HOST_KIND,
--   arg[3] OS, arg[4..] git's own hook arguments; stdin is git's hook stdin.
--   RETURN one verdict line. ok:/advised:/warn: let git proceed; anything else
--   refuses. Explanations and the affordance go to stderr.
--
-- WHAT IT DOES: asks the project's discipline (the seed, or the level-0 floor
-- when there is none) about every ref being pushed. The client pre-push is the
-- EARLY copy of the mirror's pre-receive, so a refusal costs seconds, not a
-- relay. At level 0 nothing is refused and nothing is printed (operator ruling
-- 7, 2026-09-27: fresh projects push to main by default).

local plan, host_kind, os_env = arg[1], arg[2] or "", arg[3] or ""

local function err(line) io.stderr:write(line, "\n") end

local function run(argv)
  local r = proc.run{ argv = argv }
  return r.code, r.stdout or "", r.stderr or ""
end

local function first_line(s) return (s:match("^[^\n]*")) or "" end

local function platform()
  if host_kind == "forge" then return "forge" end
  if os_env == "Windows_NT" then return "windows" end
  local _, out = run{ "uname", "-s" }
  local k = first_line(out)
  if k == "Darwin" then return "macos" end
  if k:match("^MINGW") or k:match("^MSYS") or k:match("^CYGWIN") then return "windows" end
  return "linux"
end

-- The skill an affordance names: the seed's `skills:` map, else the default.
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

local _, show_out = run{ plan, "discipline", "show", "--json" }
local sok, d = pcall(json.parse, show_out)
if not sok or type(d) ~= "table" then
  err("  `" .. tostring(plan) .. " discipline show --json` gave no answer; a question the")
  err("  seed could not answer is not permission to push.")
  return "blocked:hook:pre-push:discipline-unanswered"
end
local level = tonumber(d.level) or 0

local refused = nil
for line in io.lines() do
  local remote_ref = line:match("^%S+%s+%S+%s+(%S+)")
  if remote_ref then
    local code, out = run{ plan, "discipline", "check-ref", remote_ref }
    local verdict = first_line(out)
    if not verdict:match("^[a-z]+:discipline") then
      err("  `discipline check-ref " .. remote_ref .. "` gave no verdict (rc=" .. tostring(code) .. ").")
      return "blocked:hook:pre-push:discipline-unanswered"
    end
    local token = verdict:match("^refused:discipline:([%w%-]+):enforced")
    if token and not refused then
      refused = { ref = remote_ref, token = token }
    end
    local soft = verdict:match("^warn:discipline:([%w%-]+)")
    if soft then
      err("warn: " .. remote_ref .. " — " .. soft .. " (this project's seed warns but does not refuse)")
    end
  end
end

if not refused then return "ok:hook:pre-push" end

local branch = refused.ref:gsub("^refs/heads/", "")
local _, target_out = run{ plan, "discipline", "target", "--platform", platform() }
local integration = first_line(target_out):match("^(%S+)") or "?"
if refused.token == "default-branch-protected" then
  err(branch .. " is this project's protected default branch.")
  err("this project at level " .. level .. " (default_branch enforced) needs pushes on "
    .. integration .. "; use /" .. skill_for("level", "project-discipline") .. " for instructions")
else
  local work_ref = type(d.work_ref) == "string" and d.work_ref or "-"
  err(branch .. " is outside this project's branch grammar.")
  err("this project at level " .. level .. " (ref_grammar enforced) needs work refs named "
    .. work_ref .. " or pushes on " .. integration .. "; use /"
    .. skill_for("work_refs", "advance-work-from-plan") .. " for instructions")
end
return "refused:hook:pre-push:" .. refused.token .. ":enforced"
