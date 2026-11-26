-- @trace order:1312-i6da, order:1346-cdwt, order:2170-ji2b, order:2380-ds8v, spec:git-mirror-service
-- @env PATH
--
-- test-initialize-bare-metal-host-idempotent.lua — check-bare-metal-host-initialized.lua over
-- a stub podman: one state reads the same twice, an unseeded host reads not-seeded with no
-- prompt and no seeding verb, and a stopped mirror names its fix. A stub cannot reset a
-- machine: the real-host arms of 1312-i6da are a dated smoke record on that row, and the
-- note after the verdict says so on every run. Ported from the .sh (2380-ds8v).
--
-- SKIP on a native Windows runner: it cannot start a stub script named podman, so the
-- checker would answer for no podman at all (yolanda, 2026-11-25).
--
-- Verdict: ok:initialize-bare-metal-host:hermetic:<n>/<n> | violation:initialize-bare-metal-host:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("initialize-bare-metal-host")
local ROOT = fixture.repo_root()
local CHECKER, SKILL = "scripts/lua/check-bare-metal-host-initialized.lua", "skills/initialize-bare-metal-host/SKILL.md"
if not fs.exists(CHECKER) then T:skip("no-checker") end
if fixture.posix_shell() ~= "bash" then T:skip("native-windows-cannot-spawn-a-stub-podman") end
local PLAN = fixture.plan_binary()
if PLAN == "" then T:skip("no-plan-binary") end
local W = T:scratch()
local function state(tag, names, token)
    fs.mkdir(W.rel .. "/" .. tag)
    fs.write(W.rel .. "/" .. tag .. "/podman", "#!/usr/bin/env bash\ncase \"$1\" in\n  ps) cat <<'NAMES'\n" .. names .. "\nNAMES\n     ;;\n  exec) echo \"" .. token .. "\" ;;\n  *) exit 0 ;;\nesac\n")
    T:must{ "chmod", "+x", W.abs .. "/" .. tag .. "/podman" }
end
local function check(tag)
    local r = T:run{ PLAN, "script", "run", ROOT .. "/" .. CHECKER, cwd = ROOT, stdin = "", env_unset = { "TILLANDSIAS_*" },
        env = { PATH = W.abs .. "/" .. tag .. ":" .. (env.get("PATH") or "/usr/bin:/bin") } }
    return r.stdout or "", r.code, r.stderr or ""
end
local ALL_UP = "tillandsias-vault\ntillandsias-proxy\ntillandsias-git-tillandsias\ntillandsias-router\ntillandsias-inference"
state("up", ALL_UP, "40")
local v1, r1 = check("up")
local v2, r2 = check("up")
-- Stability, never the contents: the state is synthetic, and its lane= describes no host.
T:arm("1 STABLE one manufactured state reads the same twice, rc 0", v1 ~= "" and v1 == v2 and r1 == 0 and r2 == 0, tostring(r1) .. "/" .. tostring(r2) .. " " .. #v1 .. " and " .. #v2 .. " chars")
state("noseed", ALL_UP, "0")
local o, rc, err = check("noseed")
-- Whole comment lines only: a --suffix strip would also strip a real --with-token.
local seedy = {}
for _, l in ipairs(text.lines(fs.read(CHECKER))) do
    if not l:find("^%s*%-%-") then
        for _, v in ipairs{ "github-login", "--with-token", "vault kv put" } do if l:find(v, 1, true) then seedy[#seedy + 1] = v end end
    end
end
T:arm("2 SEEDLESS an unseeded host reads not-seeded, rc 0, and no seeding verb in the code", o:find("github=not-seeded", 1, true) and rc == 0 and #seedy == 0, tostring(rc) .. " " .. table.concat(seedy, ",") .. o .. err)
state("nomirror", "tillandsias-vault\ntillandsias-proxy", "40")
o, rc, err = check("nomirror")
T:arm("3 a stopped mirror names the fix, rc not 0", ("\n" .. o):find("\ntodo:initialize%-bare%-metal%-host:mirror:[^\n]*tillandsias") and rc ~= 0, tostring(rc) .. " " .. o .. err)
-- Not counted: the verdict is three arms. A failure still reds it.
local counted = T.passed
if fs.exists(SKILL) then
    local inr, short = false, {}
    for _, l in ipairs(text.lines(fs.read(SKILL))) do
        if l:find("^## ") then inr = l:find("^## Repairs") ~= nil
        elseif inr and l:find("^%- ") then
            for _, f in ipairs{ "date:", "host:", "symptom:", "command:", "fix:" } do if not l:find(f, 1, true) then short[#short + 1] = l:sub(1, 60); break end end
        end
    end
    T:arm("3b every Repairs entry carries date, host, symptom, command and fix", #short == 0, table.concat(short, " | "))
end
out.line("note:initialize-bare-metal-host:hermetic-only checker-shape arms against a stub podman; the real-host arms (skill run twice with CreatedAt unchanged; "
    .. "rebuild from nothing after podman system reset --force) are a dated smoke record on 1312-i6da, not this verdict")
T:finish({ ok = function() return ("ok:initialize-bare-metal-host:hermetic:%d/3"):format(counted) end })
