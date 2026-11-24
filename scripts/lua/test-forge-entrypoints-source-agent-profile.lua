-- @trace order:1517-p83m, order:2302-yqv5, spec:forge-environment-discoverability
--
-- test-forge-entrypoints-source-agent-profile.lua — every agent entrypoint loads
-- agent-profile.sh from where the image installs it, and says so when it can't.
-- Ported from the .sh (2302-yqv5).
--
-- From 2026-05-14 (b837eae09) the entrypoints sourced
-- /opt/config-overlay/mcp/agent-profile.sh behind a silent [ -f ] guard; the
-- image installs it at /home/forge/.config-overlay/mcp/. So no forge exported
-- AGENT_PROFILE and 1446-qkx4's generic-skill link never ran. 1446's fixture
-- sourced the file directly, so it could not see it.
--
--   1 STATIC     each entrypoint calls load_agent_profile after lib-common, none
--                names /opt/config-overlay, and the loader's default path is the
--                Containerfile's COPY target
--   2 BEHAVIOUR  the loader, against an image-shaped scratch HOME, exports
--                AGENT_PROFILE and links project-discipline
--   3 LOUD MISS  no profile: a named warning with why and remedy on stderr, rc 0
--   4 OPTIONS    the profile's `set -euo pipefail` does not leak into the caller
--   5 NEGATIVE   the pre-fix block, same HOME: nothing exported, nothing linked,
--                NOTHING printed (the silence this row fixes)
--   6 HOSTILE    from a `set -e` caller, a profile that fails mid-body, trips -u
--                or ends on a failure never kills it; the last two are named
--
-- Verdict: ok:forge-entrypoints-source-agent-profile:6 arms |
--          violation:forge-entrypoints-source-agent-profile:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("forge-entrypoints-source-agent-profile")
local ROOT = fixture.repo_root()
local W = T:scratch()
local lib = fs.read("images/default/lib-common.sh")
local function has(s, w) return s:find(w, 1, true) ~= nil end

-- ── 1 ─────────────────────────────────────────────────────────────────────
local target
for _, l in ipairs(text.lines(fs.read("images/default/Containerfile"))) do
    target = target or l:match("^COPY config%-overlay/mcp/ (%S+)")
end
target = (target or ""):gsub("/$", "")
local tail = lib:match('HOME:%-/home/forge}/([^}"\n]*agent%-profile%.sh)')
local why = {}
if not tail or target == "" or "/home/forge/" .. tail ~= target .. "/agent-profile.sh" then
    why[#why + 1] = "loader default '" .. tostring(tail) .. "' is not under the COPY target '" .. target .. "'"
end
for _, a in ipairs({ "claude", "codex", "opencode", "opencode-web", "antigravity" }) do
    local e = fs.read("images/default/entrypoint-forge-" .. a .. ".sh")
    local lc, lp
    for i, l in ipairs(text.lines(e)) do
        if not lc and has(l, "source /usr/local/lib/tillandsias/lib-common.sh") then lc = i end
        if not lp and l:match("^load_agent_profile") then lp = i end
    end
    if has(e, "/opt/config-overlay") then why[#why + 1] = a .. " names /opt/config-overlay" end
    if not lc or not lp or lp <= lc then why[#why + 1] = a .. ": load_agent_profile missing or before lib-common" end
end
T:arm("1 STATIC all five entrypoints call load_agent_profile after lib-common; its default is the COPY target", #why == 0, table.concat(why, "; "))

-- The loader, cut from lib-common (a function, so no container setup runs).
local loader, on = {}, false
for _, l in ipairs(text.lines(lib)) do
    if l:match("^load_agent_profile%(%) {") then on = true end
    if on then
        loader[#loader + 1] = l
        if l:sub(1, 1) == "}" then break end
    end
end
if #loader == 0 then T:refuse("no-subject", "load_agent_profile is not in lib-common.sh") end
loader = table.concat(loader, "\n") .. "\n"

local function mkhome(name)
    fs.mkdir(W.rel .. "/" .. name .. "/home/.config-overlay/mcp")
    fs.mkdir(W.rel .. "/" .. name .. "/opt-skills")
    local d = W.abs .. "/" .. name
    T:must{ "cp", ROOT .. "/images/default/config-overlay/mcp/agent-profile.sh", d .. "/home/.config-overlay/mcp/" }
    T:must{ "cp", "-R", ROOT .. "/skills/project-discipline", d .. "/opt-skills/" }
    return d
end
-- bash runs the script from stdin; proc.run gives it a cleared environment.
local function sh(script, home, extra)
    local e = { HOME = home }
    for k, v in pairs(extra or {}) do e[k] = v end
    local r = T:run{ fixture.posix_shell(), "-s", stdin = script, env = e, timeout_ms = 30000 }
    return r.code, text.trim(r.stdout or ""), text.trim(r.stderr or "")
end
local function linked(d)
    return T:run{ "test", "-L", d .. "/home/.claude/skills/project-discipline" }.code == 0
end
local SHOW = 'printf "AGENT_PROFILE=%s\\n" "${AGENT_PROFILE:-}"\n'
local function got(rc, o, e) return "rc=" .. tostring(rc) .. " out=[" .. o .. "] err=[" .. e:sub(1, 300) .. "]" end

-- ── 2 ─────────────────────────────────────────────────────────────────────
local H = mkhome("fixed")
local AGENT = { TILLANDSIAS_AGENT = "codex", TILLANDSIAS_SHARED_SKILLS_ROOT = H .. "/opt-skills" }
local rc, o, e = sh(loader .. "load_agent_profile\n" .. SHOW, H .. "/home", AGENT)
T:arm("2 BEHAVIOUR the loader exports AGENT_PROFILE=codex and links project-discipline, silently",
    rc == 0 and has("\n" .. o .. "\n", "\nAGENT_PROFILE=codex\n") and linked(H) and e == "", got(rc, o, e) .. " linked=" .. tostring(linked(H)))

-- ── 3 ─────────────────────────────────────────────────────────────────────
fs.mkdir(W.rel .. "/empty")
rc, o, e = sh(loader .. 'load_agent_profile\necho "rc=$?"\n', W.abs .. "/empty")
T:arm("3 LOUD MISS a missing profile is named with why and remedy, and the forge still starts",
    o == "rc=0" and has(e, "WARNING: agent profile not found") and has(e, "why:") and has(e, "remedy:") and has(e, "1517-p83m"), got(rc, o, e))

-- ── 4 ─────────────────────────────────────────────────────────────────────
rc, o, e = sh(loader .. [[
set +eu; set +o pipefail
load_agent_profile
case $- in *e*|*u*) echo leaked ;; *) echo clean ;; esac
shopt -qo pipefail && echo leaked-pipefail
]], H .. "/home", AGENT)
T:arm("4 OPTIONS the profile's set -euo pipefail does not leak", o == "clean", got(rc, o, e))

-- ── 5 ─────────────────────────────────────────────────────────────────────
local P = mkhome("prefix")
rc, o, e = sh("if [ -f /opt/config-overlay/mcp/agent-profile.sh ]; then source /opt/config-overlay/mcp/agent-profile.sh; fi\n" .. SHOW,
    P .. "/home", { TILLANDSIAS_AGENT = "codex", TILLANDSIAS_SHARED_SKILLS_ROOT = P .. "/opt-skills" })
T:arm("5 NEGATIVE the pre-fix block exports nothing, links nothing and prints nothing",
    o == "AGENT_PROFILE=" and not linked(P) and e == "", got(rc, o, e) .. " (a real /opt/config-overlay here would explain it)")

-- ── 6 ─────────────────────────────────────────────────────────────────────
local bad = {}
for _, c in ipairs({ { "mid", "false; export AGENT_PROFILE=x" },
    { "nounset", 'echo "$TILLANDSIAS_SURELY_UNSET_1517"' }, { "last", "export AGENT_PROFILE=y; false" } }) do
    local d = "h6-" .. c[1]
    fs.mkdir(W.rel .. "/" .. d .. "/.config-overlay/mcp")
    fs.write(W.rel .. "/" .. d .. "/.config-overlay/mcp/agent-profile.sh", "#!/usr/bin/env bash\nset -euo pipefail\n" .. c[2] .. "\n")
    rc, o, e = sh("set -e\n" .. loader .. "load_agent_profile\necho survived\n", W.abs .. "/" .. d)
    if not has(o, "survived") then bad[#bad + 1] = c[1] .. ": the caller died " .. got(rc, o, e)
    elseif c[1] ~= "mid" and not has(e, "agent profile at " .. W.abs .. "/" .. d .. "/.config-overlay/mcp/agent-profile.sh failed") then
        bad[#bad + 1] = c[1] .. ": no warning naming the path " .. got(rc, o, e)
    end
end
T:arm("6 HOSTILE a failing profile never kills a set -e entrypoint, and is named", #bad == 0, table.concat(bad, "; "))
T:finish()
