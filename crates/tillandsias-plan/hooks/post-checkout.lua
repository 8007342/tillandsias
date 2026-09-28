-- post-checkout.lua — the embedded discipline template for git's post-checkout event.
-- @trace order:1446-xqi6, spec:branch-discipline
--
-- ADVISORY ONLY, installed from level 1 up. When the working branch is the
-- project's protected default branch, it says so and names the integration
-- branch and the skill, so the refusal at pre-push is never the first news.
-- It never refuses: working on the default branch locally is not a violation,
-- pushing it is (pre-push and the mirror's pre-receive own that).
--
-- Contract as in pre-push.lua: arg[0] event, arg[1] plan binary, arg[2] host
-- kind, arg[3] OS, arg[4..] git's arguments; RETURN one verdict line. A project
-- may override this with .tillandsias/hooks/post-checkout.lua.

local plan, host_kind, os_env = arg[1], arg[2] or "", arg[3] or ""

local function err(line) io.stderr:write(line, "\n") end
local function first_line(s) return (s:match("^[^\n]*")) or "" end

-- post-checkout passes <prev> <new> <flag>; flag 0 is a file checkout.
if arg[0] == "post-checkout" and arg[6] == "0" then return "ok:hook:post-checkout" end

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

local function platform()
  if host_kind == "forge" then return "forge" end
  if os_env == "Windows_NT" then return "windows" end
  local k = first_line(proc.run{ argv = { "uname", "-s" } }.stdout or "")
  if k == "Darwin" then return "macos" end
  if k:match("^MINGW") or k:match("^MSYS") or k:match("^CYGWIN") then return "windows" end
  return "linux"
end

local show = proc.run{ argv = { plan, "discipline", "show", "--json" } }
local sok, d = pcall(json.parse, show.stdout or "")
if not sok or type(d) ~= "table" then return "ok:hook:post-checkout" end
local level = tonumber(d.level) or 0
if level < 1 then return "ok:hook:post-checkout" end

local branch = first_line(proc.run{ argv = { "git", "branch", "--show-current" } }.stdout or "")
if branch == "" or branch ~= d.default_branch then return "ok:hook:post-checkout" end

local integration = first_line(proc.run{ argv = { plan, "discipline", "target", "--platform", platform() } }.stdout or ""):match("^(%S+)") or "?"
err("you are on " .. branch .. ", this project's protected default branch; a push of it will be refused.")
err("this project at level " .. level .. " (default_branch " .. tostring(d.enforcement and d.enforcement.default_branch or "?")
  .. ") needs pushes on " .. integration .. "; use /" .. skill_for("level", "project-discipline") .. " for instructions")
return "advised:hook:post-checkout:on-protected-default-branch"
