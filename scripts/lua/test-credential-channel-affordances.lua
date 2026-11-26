-- @env PATH HOME
-- @trace order:1497-ahmd, order:1247-amcu, order:1025-a896, order:2378-hcxg
--
-- test-credential-channel-affordances.lua — every blocked: verdict of check-credential-channel.sh
-- says why and what clears it, no remedy tells an agent to re-authenticate, and one printed remedy
-- is EXECUTED and shown to clear its refusal. Ported from the .sh of the same name (2378-hcxg). gh and
-- busctl are stubs; the remedy runs in a scratch repository with a scratch home.
--
--   1 the audit counts no bare verdict site     2 no remedy instructs gh auth login or refresh
--   3 the interactive-credential-helper remedy, run verbatim, clears it; without it the refusal stands
--
-- Usage: tillandsias-plan script run scripts/lua/test-credential-channel-affordances.lua
-- Verdict: ok:credential-channel-affordances:<n> arms | violation:...

local fixture = require "common.fixture"
local bus = require "common.privatebus"
local T = fixture.new("credential-channel-affordances")
local SH, ROOT = fixture.posix_shell(), fixture.repo_root()
local GUARD = "scripts/check-credential-channel.sh"
local function count(s, p) return select(2, s:gsub(p, "")) end
local r = proc.run{ argv = { SH, ROOT .. "/scripts/check-refusal-affordance-added.sh", "--audit" }, cwd = ROOT, env = bus.env(), env_unset = { "TILLANDSIAS_*" }, timeout_ms = 120000 }
local audit = "\n" .. (r.stdout or "")
local bare, covered = count(audit, "\nbare scripts/check%-credential%-channel%.sh:"), count(audit, "\ncovered scripts/check%-credential%-channel%.sh:")
T:arm("1 no bare verdict site, at least fifteen covered", bare == 0 and covered >= 15, "bare=" .. bare .. " covered=" .. covered)
local src, instructs, reseed = fs.read(GUARD):gsub("\r", ""), {}, 0
for l in (src .. "\n"):gmatch("([^\n]*)\n") do
    local low = l:lower()
    local prints = l:match("^%s*echo") or l:match("^%s*printf") or l:match("^%s*_afford")
    if prints and low:find("remedy.*gh auth login") or prints and low:find("remedy.*gh auth refresh") then
        if not low:find("not", 1, true) and not low:find("never", 1, true) then instructs[#instructs + 1] = l end
    end
    if l:find("tillandsias --github-login", 1, true) then reseed = reseed + 1 end
end
T:arm("2 no remedy instructs a re-auth; they name the operator's login", #instructs == 0 and reseed >= 3, table.concat(instructs, " | ") .. " reseed=" .. reseed)

local d = T:scratch()
fs.mkdir(d.rel .. "/bin"); fs.mkdir(d.rel .. "/home")
fs.write(d.rel .. "/bin/gh", [==[#!/usr/bin/env bash
case "$1 $2" in
  "auth status") echo "Logged in to github.com account fixture-user (keyring)" >&2; exit 0 ;;
  "auth token")  echo "fixture-not-a-token" ;;
  "api user")    echo "fixture-user" ;;
esac
exit 0
]==])
fs.write(d.rel .. "/bin/busctl", "#!/usr/bin/env bash\necho \"org.freedesktop.secrets 1234 gnome-keyring-d fixture :1.1 user@1000.service - -\"\n")
fs.write(d.rel .. "/probe.sh", [==[#!/usr/bin/env bash
helpers="
$(git config --get-all credential.helper)
"
case "$helpers" in *"
!gh auth git-credential
"*) ;; *) exit 1 ;; esac
case "$helpers" in *"
manager
"*) exit 1 ;; esac
exit 0
]==])
T:must{ "chmod", "+x", d.abs .. "/bin/gh", d.abs .. "/bin/busctl", d.abs .. "/probe.sh" }
local PRE = 'W="$1"; export PATH="$W/bin:$PATH" HOME="$W/home" GIT_CONFIG_NOSYSTEM=1 TILLANDSIAS_CCC_NO_LANE=1 TILLANDSIAS_CRED_PROBE_CMD="$W/probe.sh"\nunset GH_TOKEN GITHUB_TOKEN GIT_DIR GIT_WORK_TREE\n'
local function sh(body)
    local x = proc.run{ argv = { SH, "-s", "--", d.abs, ROOT .. "/" .. GUARD }, cwd = d.abs, stdin = PRE .. body, env = bus.env{ HOME = d.abs .. "/home" }, env_unset = { "TILLANDSIAS_*", "GIT_*" }, timeout_ms = 120000 }
    return { rc = x.code, out = x.stdout or "", err = "\n" .. (x.stderr or ""), why = "rc=" .. tostring(x.code) .. " " .. (x.stdout or ""):sub(1, 200) .. (x.stderr or ""):sub(1, 500) }
end
local setup = sh 'git init -q -b main repo && git -C repo config core.hooksPath .git/hooks && git -C repo -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m x && git -C repo config credential.helper manager'
if setup.rc ~= 0 then T:refuse("setup-failed", setup.why) end
local RUN = 'cd repo && exec bash "$2" </dev/null\n'
local x = sh(RUN)
T:arm("3a PREMISE the interactive helper is refused", x.rc ~= 0 and text.contains("\n" .. x.out, "\nblocked:interactive-credential-helper"), x.why)
local again = sh(RUN)
T:arm("3b CONTROL without the remedy the refusal stands", again.rc ~= 0, again.why)
-- The lines after REMEDY: up to the next verdict or why:, as printed.
local remedy, on = {}, false
for l in (again.err .. "\n"):gmatch("([^\n]*)\n") do
    if on and (l:match("^blocked:") or l:match("^ *why:")) then break end
    if on and not l:match("^%s*#") and l:match("%S") then remedy[#remedy + 1] = (l:gsub("^ *", "")) end
    if l:find("REMEDY:", 1, true) then on = true end
end
fs.write(d.rel .. "/remedy.sh", table.concat(remedy, "\n") .. "\n")
local fix = sh 'cd repo && exec bash "$1/remedy.sh" </dev/null\n'
x = sh(RUN)
T:arm("3c the printed remedy, run verbatim, clears it", #remedy > 0 and fix.rc == 0 and x.rc == 0 and not text.contains(x.out, "blocked:"), #remedy .. " lines; " .. fix.why .. " then " .. x.why)
T:finish()
