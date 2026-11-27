-- @env PATH HOME
-- @trace order:1443-8pur, order:2028-j4a7, order:2367-wtse
--
-- test-command-policy-evaluator.lua — `tillandsias-plan policy eval` decides a command by the floor
-- and the seed, and the Lua door's proc.run obeys it. Ported from the .sh of the same name
-- (2367-wtse). Nothing evaluated here is run; the one denied program is a stub that records a spawn.
--
--   1 credential mutation is refused, naming the operator    2 a shell string is refused
--   3 soft and hard resets by host kind     4 a seed that loosens the floor is refused whole
--   5 proc.run returns policy_denied and spawns nothing      6 CONTROL git status is allowed and runs
--
-- Usage: tillandsias-plan script run scripts/lua/test-command-policy-evaluator.lua
-- Verdict: ok:command-policy-evaluator:<n> arms | violation:... | skip:command-policy-evaluator:...

local fixture = require "common.fixture"
local T = fixture.new("command-policy-evaluator")
local SH, PLAN, ROOT = fixture.posix_shell(), fixture.plan_binary(), fixture.repo_root()
if PLAN == "" then T:skip("no-plan-binary") end
local d = T:scratch()
local function ev(more, ...)
    local e = { PATH = env.get("PATH"), HOME = env.get("HOME") }
    for k, v in pairs(more or {}) do e[k] = v end
    local r = proc.run{ argv = { PLAN, "policy", "eval", ... }, cwd = ROOT, env = e, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 30000 }
    local o, er = text.trim(r.stdout or ""), "\n" .. (r.stderr or "")
    return { rc = r.code, out = o, err = er, why = "rc=" .. tostring(r.code) .. " [" .. o .. "] " .. er:sub(1, 300) }
end
local function is(x, out_, rc) return x.out == out_ and x.rc == rc end
local x = ev(nil, "--host-kind", "forge", "--regime", "interactive", "--", "gh", "auth", "refresh")
T:arm("1 a credential mutation is refused, with why and the operator's sign-in", is(x, "refused:policy:no-credential-mutation", 1) and text.contains(x.err, "\n  why: ") and text.contains(x.err, "\n  remedy: ")
    and text.contains(x.err, "the OPERATOR signs in from"), x.why)
x = ev(nil, "--", "bash", "-c", "a | b")
T:arm("2 a shell string is refused, naming the argv form", is(x, "refused:policy:no-shell-strings", 1) and text.contains(x.err, "argv"), x.why)
local SMOKE = { TILLANDSIAS_DESTRUCTIVE_RESET_OK = "1", TILLANDSIAS_SKILL = "smoke-curl-install-and-test-e2e" }
for _, c in ipairs{ { "soft, bare metal", nil, "bare-metal", { "podman", "system", "reset", "--force" }, "consent:policy:soft-reset", 4 },
    { "soft, forge", nil, "forge", { "podman", "system", "reset", "--force" }, "ok:policy:soft-reset:forge-preauthorised", 0 },
    { "reset-state, forge", nil, "forge", { "tillandsias", "--reset-state" }, "ok:policy:soft-reset:forge-preauthorised", 0 },
    { "hard, bare metal, with the smoke env", SMOKE, "bare-metal", { "tillandsias-tray", "--reset-guest" }, "consent:policy:hard-reset", 4 },
    { "hard, forge", nil, "forge", { "tillandsias-tray", "--reset-guest" }, "refused:policy:hard-reset:not-grantable-in-forge", 1 } } do
    x = ev(c[2], "--host-kind", c[3], "--", table.unpack(c[4]))
    T:arm("3 reset, " .. c[1] .. ": " .. c[5], is(x, c[5], c[6]), x.why)
end
local TIGHT = "version: 1\ndefault: allow\nrules:\n  - id: tighten-make\n    program: make\n    decision: deny\n"
fs.write(d.rel .. "/tight.yaml", TIGHT)
fs.write(d.rel .. "/loose.yaml", TIGHT .. "  - id: let-me-refresh\n    program: gh\n    args: [auth, refresh]\n    decision: allow\n")
x = ev(nil, "--seed", d.abs .. "/tight.yaml", "--", "make")
T:arm("4a PREMISE a seed that only tightens is honoured", x.out == "refused:policy:tighten-make", x.why)
local LOOSE = "refused:policy-seed:cannot-loosen:no-credential-mutation"
x = ev(nil, "--seed", d.abs .. "/loose.yaml", "--", "gh", "auth", "refresh")
T:arm("4b one that loosens is refused at load, with its remedy", is(x, LOOSE, 1) and text.contains(x.err, LOOSE) and text.contains(x.err, "\n  remedy: repair the command policy seed"), x.why)
x = ev(nil, "--seed", d.abs .. "/loose.yaml", "--", "make")
T:arm("4c and every other request against it is refused too", is(x, LOOSE, 1), x.why)

fs.mkdir(d.rel .. "/bin"); fs.write(d.rel .. "/bin/gh", "#!/bin/sh\n: >\"" .. d.abs .. "/gh-ran\"\n")
T:must{ "chmod", "+x", d.abs .. "/bin/gh" }
-- The child's PATH is set by a shell: proc.run here would itself resolve the stub.
local function lua(code, with_stub)
    local r = T:run{ SH, "-s", "--", PLAN, code, d.abs .. "/bin", cwd = ROOT, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 30000, stdin = (with_stub and 'PATH="$3:$PATH"\n' or "") .. 'exec "$1" lua -e "$2" </dev/null 2>&1\n' }
    return text.trim(r.stdout or "")
end
local function ran() return fs.exists(d.rel .. "/gh-ran") end
local got = lua('local r = proc.run{argv = {"gh", "auth", "login"}}\nlocal function set(s) return type(s) == "string" and #s > 0 end\nprint(r.status, r.rule_id, set(r.why) and "why" or "", set(r.remedy) and "remedy" or "")', true)
T:arm("5a proc.run returns policy_denied with the rule, why and remedy, and spawns nothing", got == "policy_denied\tno-credential-mutation\twhy\tremedy" and not ran(), got .. " ran=" .. tostring(ran()))
got = lua('print(proc.run{argv = {"gh", "api", "user"}}.status)', true)
T:arm("5b CONTROL an allowed call to the same program does spawn", got == "exited" and ran(), got .. " ran=" .. tostring(ran()))
x = ev(nil, "--", "git", "status", "--porcelain")
got = lua('local r = proc.run{argv = {"git", "status", "--porcelain"}}; print(r.status, r.ok)')
T:arm("6 CONTROL git status is allowed by default and runs", is(x, "ok:policy:allow:default", 0) and got == "exited\ttrue", x.why .. " " .. got)
T:finish()
