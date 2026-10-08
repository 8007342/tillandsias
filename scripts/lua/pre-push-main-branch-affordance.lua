-- pre-push-main-branch-affordance.lua — refuse a push to the protected
-- default branch, and SAY WHAT TO DO INSTEAD (order 1443-sb9b).
-- @trace order:1443-sb9b, spec:branch-discipline
--
-- Run by the sandboxed `tillandsias-plan lua` CLI from the stub
-- scripts/hooks/pre-push-main-branch-affordance.sh:
--
--   tillandsias-plan lua <this.lua> <plan-binary> <TILLANDSIAS_HOST_KIND> <OS>
--
-- stdin is git's pre-push feed: "<local ref> <local sha> <remote ref> <remote sha>".
--
-- WHY IT EXISTS (carried from the shell original): main already carried
-- server-side protection (order 476), so a push to it crossed the network and
-- came back as a GitHub rejection with no remedy. An in-forge agent lost a
-- cycle to it; a host parked on main pins every forge seeded afterwards. The
-- operator's rule (2026-08-23): every error carries a recommendation, at the
-- point of refusal.
--
-- WHAT THE PORT CHANGES: the branch recommended and the branch protected both
-- come from the discipline seed (1443-w79y) via `discipline check-ref` and
-- `discipline target`, instead of a hardcoded "main"/"linux-next" and a guess
-- from uname. A project with no seed is level 0: nothing is refused.
--
-- Verdict grammar (stdout, one line), unchanged from the shell original:
--   ok:main-branch-affordance            nothing targets the protected branch
--   blocked:main-branch-affordance       a ref does; remedy on stderr
-- plus, fail-closed (a question the seed could not answer is not a yes):
--   blocked:main-branch-affordance:discipline-unanswered
--
-- THE VERDICT LINE IS THE INTERFACE, NOT AN EXIT CODE. The sandboxed CLI has
-- no os.exit and prints a chunk's return values, so this script prints exactly
-- one verdict line and returns nothing; the stub maps it to the hook's exit
-- status and treats anything but `ok:main-branch-affordance` as a refusal.

local plan, host_kind, os_env = arg[1], arg[2] or "", arg[3] or ""

local function err(line) io.stderr:write(line, "\n") end

local function run(argv)
  local r = proc.run{ argv = argv }
  return r.code, r.stdout or "", r.stderr or ""
end

local function first_line(s) return (s:match("^[^\n]*")) or "" end

-- The platform whose integration branch to recommend. Explicit env first
-- (a forge is linux underneath but has its own row), then the kernel.
local function platform()
  if host_kind == "forge" then return "forge" end
  if os_env == "Windows_NT" then return "windows" end
  local _, out = run{ "uname", "-s" }
  local k = first_line(out)
  if k == "Darwin" then return "macos" end
  if k:match("^MINGW") or k:match("^MSYS") or k:match("^CYGWIN") then return "windows" end
  return "linux"
end

local function main()
-- Every remote ref git is about to update.
local protected, blocked_ref, provenance = false, nil, nil
for line in io.lines() do
  local remote_ref = line:match("^%S+%s+%S+%s+(%S+)")
  if remote_ref then
    local code, out = run{ plan, "discipline", "check-ref", remote_ref }
    local verdict = first_line(out)
    if not verdict:match("^[a-z]+:discipline") then
      print("blocked:main-branch-affordance:discipline-unanswered")
      err("  `" .. plan .. " discipline check-ref " .. remote_ref .. "` gave no verdict (rc=" .. tostring(code) .. ").")
      err("  A question the seed could not answer is not permission to push.")
      err("  remedy: rebuild the plan binary: cargo build --release -p tillandsias-plan")
      return
    end
    if verdict:match("^refused:discipline:default%-branch%-protected") then
      protected, blocked_ref = true, remote_ref
      provenance = out:match("\n(source=[^\n]*)") or ""
    end
  end
end

if not protected then
  print("ok:main-branch-affordance")
  return
end

local p = platform()
local _, target_out = run{ plan, "discipline", "target", "--platform", p }
local suggest = target_out:match("^(%S+)") or "?"
local branch = blocked_ref:gsub("^refs/heads/", "")

print("blocked:main-branch-affordance")
err(branch .. " is this project's protected default branch (" .. provenance .. ", from")
err(".tillandsias/branch-discipline.yaml), so this push would only be rejected by the")
err("server after crossing the network.")
err("")
err("  WHAT TO DO: work on '" .. suggest .. "', the " .. p .. " integration branch in the seed.")
err("    git branch --show-current      # confirm where you are")
err("    git checkout " .. suggest)
err("")
err("  IF YOU ARE IN A FORGE and did not choose " .. branch .. ": the forge seeds its")
err("  branch from the HOST checkout's current branch, so a host left parked")
err("  on " .. branch .. " pins every forge launched after it (order 531). Fix the host")
err("  checkout, not just this one.")
err("")
err("  " .. branch .. " only ever advances through a PR, which the")
err("  merge-to-main-and-release skill opens. It is a release decision, not")
err("  a push.")
end

main()
