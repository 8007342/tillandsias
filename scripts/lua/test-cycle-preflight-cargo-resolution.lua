-- @env PATH HOME
-- @trace order:876-irn7, order:1005-m6rz, order:2377-znx4
--
-- test-cycle-preflight-cargo-resolution.lua — cycle-preflight.sh finds cargo past an empty PATH,
-- falls back to a built plan binary when there is none, and the cycle's guards name what a host
-- lacks. Ported from the .sh of the same name (2377-znx4), which pasted a copy of the loop; here
-- it is cut from the script (arm 8 is still a copy of the second block). No toolchain is run.
--
--   1 the two blocks are there    2 ~/.cargo/bin and CARGO_HOME/bin resolve    3 absent is absent
--   4 an unset CARGO_HOME never probes /bin     5 no git identity is refused with the remedy
--   6 cheatsheet-tiers names an absent cargo    7 the cargo-site registry
--   8 no cargo: a runnable binary serves, none blocks; cargo present builds
--   9 the shipped refusal carries why and remedy   10 the shared resolver (lib/lua/common/cargosites.lua)
--
-- Usage: tillandsias-plan script run scripts/lua/test-cycle-preflight-cargo-resolution.lua
-- Verdict: ok:cycle-preflight-cargo-resolution:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("cycle-preflight-cargo-resolution")
local SH, PLAN, ROOT = fixture.posix_shell(), fixture.plan_binary(), fixture.repo_root()
if PLAN == "" then T:refuse("no-plan-binary") end
local src = "\n" .. fs.read("scripts/cycle-preflight.sh"):gsub("\r", "")
local w = T:scratch()
-- A PATH with everything the shell needs and no cargo.
T:must{ SH, "-s", "--", w.abs, stdin = [==[
mkdir "$1/nocargo"
for t in bash git dirname; do
    p="$(command -v "$t" 2>/dev/null)" || continue
    d="$(cd "$(dirname "$p")" && pwd)" || continue
    for x in "$d"/*; do n="${x##*/}"; case "$n" in cargo|cargo.exe) continue ;; esac
        [ -e "$1/nocargo/$n" ] || ln -s "$x" "$1/nocargo/$n" 2>/dev/null || true; done
done
]==] }
fs.mkdir(w.rel .. "/empty-home")
local function exe(dir, name) fs.mkdir(w.rel .. dir); fs.write(w.rel .. dir .. "/" .. name, "#!/usr/bin/env bash\nexit 0\n"); T:must{ "chmod", "+x", w.abs .. dir .. "/" .. name } end
local NOCARGO = w.abs .. "/nocargo"
-- `env -i` in the shell: what the child sees is exactly this list.
local function sh(vars, body, cwd)
    local a = { SH, "-s", "--", "env", "-i", "ROOT=" .. ROOT }
    local path = NOCARGO
    for k, v in pairs(vars) do
        if k == "PATH" then path = v else a[#a + 1] = k .. "=" .. v end
    end
    a[#a + 1] = "PATH=" .. path
    fs.write(w.rel .. "/body.sh", body)
    a[#a + 1] = "bash"; a[#a + 1] = w.abs .. "/body.sh"
    local r = proc.run{ argv = a, cwd = cwd or w.abs, stdin = 'exec "$@" </dev/null\n', env_unset = { "TILLANDSIAS_*", "GIT_*" }, timeout_ms = 60000 }
    return { rc = r.code, out = text.trim((r.stdout or ""):gsub("\r", "")), err = "\n" .. (r.stderr or ""), why = "rc=" .. tostring(r.code) .. " [" .. (r.stdout or ""):sub(1, 200) .. "] " .. (r.stderr or ""):sub(1, 300) }
end
local LOOP = src:match("\n(    if ! command %-v cargo >/dev/null 2>&1; then\n        for _cargo_dir in .-\n    fi)\n")
local LIST = 'for _cargo_dir in "${CARGO_HOME:-}/bin" "$HOME/.cargo/bin"; do'
T:arm("1a the resolution loop is in the preflight", LOOP ~= nil and text.contains(LOOP, LIST), tostring(LOOP))
T:arm("1b and so is the probe for a binary before the cargo-absent exit", text.contains(src, 'if plan_bin="$(resolve_plan_binary)"; then') and text.contains(src, 'plan_verdict="existing"'), "gone")
if not LOOP then T:finish() end
local ASK = "\ncommand -v cargo >/dev/null 2>&1 && echo found || echo absent\n"
exe("/home/.cargo/bin", "cargo"); exe("/altcargo/bin", "cargo")
local HOME, EMPTY = { HOME = w.abs .. "/home" }, { HOME = w.abs .. "/empty-home" }
local x = sh(HOME, LOOP .. ASK)
T:arm("2a ~/.cargo/bin resolves past an empty PATH", x.out == "found", x.why)
x = sh(HOME, ASK)
T:arm("2b CONTROL without the loop it does not", x.out == "absent", x.why)
x = sh({ HOME = w.abs .. "/empty-home", CARGO_HOME = w.abs .. "/altcargo" }, LOOP .. ASK)
T:arm("2c CARGO_HOME/bin resolves", x.out == "found", x.why)
x = sh(EMPTY, LOOP .. ASK)
T:arm("3 a genuinely absent cargo is absent", x.out == "absent", x.why)
-- Every directory the loop tests, whether or not cargo is in it.
x = sh(EMPTY, (LOOP:gsub("if %[ %-x \"%$_cargo_dir/cargo\" %]", function() return 'echo "probed=$_cargo_dir"; if [ -x "$_cargo_dir/cargo" ]' end)))
T:arm("4 an unset CARGO_HOME never probes /bin", text.contains(x.out, "probed=" .. w.abs .. "/empty-home/.cargo/bin") and not text.contains("\n" .. x.out .. "\n", "probed=/bin\n"), x.why)

T:must{ "git", "init", "-q", "-b", "linux-next", w.abs .. "/noident" }
T:must{ "git", "-C", w.abs .. "/noident", "config", "user.useConfigOnly", "true" }
local GUARD = 'exec "' .. PLAN .. '" script run "$ROOT/scripts/lua/check-committable-branch.lua"\n'
x = sh(EMPTY, GUARD, w.abs .. "/noident")
T:arm("5a a host with no git identity is refused", x.out == "blocked:no-git-identity", x.why)
T:arm("5b naming the git config remedy", text.contains(x.err, "git config user.email"), x.why)
T:must{ "git", "-C", w.abs .. "/noident", "config", "user.name", "t" }
T:must{ "git", "-C", w.abs .. "/noident", "config", "user.email", "t@example.invalid" }
x = sh(EMPTY, GUARD, w.abs .. "/noident")
T:arm("5c CONTROL with one it passes", x.out:match("^ok:branch%-") ~= nil, x.why)
T:arm("6a cheatsheet-tiers looks past PATH too, through the shared resolver", text.contains(fs.read("scripts/lua/check-cheatsheet-tiers.lua"), "require(\"common.cargosites\").resolve") and text.contains(fs.read("lib/lua/common/cargosites.lua"), "/.cargo/bin"), "gone")
x = sh(EMPTY, 'exec "' .. PLAN .. '" script run scripts/lua/check-cheatsheet-tiers.lua 2>&1\n', ROOT)
T:arm("6b and an absent cargo is a named skip, never command-not-found", x.out:match("^skip:cheatsheet%-tiers:cargo%-absent") ~= nil or (x.out ~= "" and not text.contains(x.out, "command not found")), x.why)

local SITES = require("common.cargosites").SITES
local n, missing = 0, {}
for _, site in ipairs(SITES) do
    n = n + 1
    if not fs.exists(site) then missing[#missing + 1] = site end
end
T:arm("7a every cargo site in the registry exists", n > 0 and #missing == 0, n .. " " .. table.concat(missing, " "))
for _, s in ipairs{ "scripts/cycle-preflight.sh", "scripts/lua/check-cheatsheet-tiers.lua", "scripts/host-capability-probe.sh" } do
    T:arm("7b it lists " .. s, text.contains("\n" .. table.concat(SITES, "\n") .. "\n", "\n" .. s .. "\n"), table.concat(SITES, " "))
end
local PROBE = [==[
plan_verdict=skipped
if ! command -v cargo >/dev/null 2>&1; then
    . "$ROOT/scripts/plan-binary-probe.sh"
    if plan_bin="$(resolve_plan_binary)"; then plan_verdict=existing; else echo blocked:preflight:plan:cargo-absent; exit 1; fi
fi
echo "$plan_verdict"
]==]
exe("/stub", "plan"); exe("/present", "cargo")
x = sh({ HOME = EMPTY.HOME, TILLANDSIAS_PLAN_BIN = w.abs .. "/stub/plan" }, PROBE)
T:arm("8a no cargo and a runnable binary: existing", x.out == "existing", x.why)
x = sh({ HOME = EMPTY.HOME, TILLANDSIAS_PLAN_BIN = w.abs .. "/no-such-plan" }, PROBE)
T:arm("8b no cargo and none: still blocked", x.out == "blocked:preflight:plan:cargo-absent", x.why)
x = sh({ HOME = EMPTY.HOME, TILLANDSIAS_PLAN_BIN = w.abs .. "/stub/plan", PATH = w.abs .. "/present:" .. NOCARGO }, PROBE)
T:arm("8c cargo present takes the build path", x.out == "skipped", x.why)
x = sh({ HOME = EMPTY.HOME, TILLANDSIAS_PLAN_BIN = w.abs .. "/no-such-plan" }, 'exec bash "$ROOT/scripts/cycle-preflight.sh"\n')
T:arm("9a the shipped preflight refuses cargo-absent", text.contains(x.out, "blocked:preflight:plan:cargo-absent"), x.why)
T:arm("9b with a why and a remedy naming TILLANDSIAS_PLAN_BIN", text.contains(x.err, "\n  why: ") and x.err:find("\n  remedy: [^\n]*TILLANDSIAS_PLAN_BIN") ~= nil, x.why)

-- The shared resolver itself (lib/lua/common/cargosites.lua): which directories it tries, and that it
-- returns what runs. A probe script under each environment, since the module reads the runner's.
local probe = T:scratch()
fs.write(probe.rel .. "/probe.lua", '-- @env HOME CARGO_HOME WANT\nlocal tried = {}\nlocal got = require("common.cargosites").resolve(function(b) tried[#tried + 1] = b; return b == (env.get("WANT") or "") end)\nprint("got=" .. tostring(got))\nfor _, b in ipairs(tried) do print("tried=" .. b) end\nverdict.ok("probe")\n')
local function resolver(vars)
    local a = { SH, "-s", "--", "env", "-i", "PATH=" .. NOCARGO }
    for k, v in pairs(vars) do a[#a + 1] = k .. "=" .. v end
    a[#a + 1] = PLAN; a[#a + 1] = "script"; a[#a + 1] = "run"; a[#a + 1] = probe.abs .. "/probe.lua"
    local r = proc.run{ argv = a, cwd = ROOT, stdin = 'exec "$@" </dev/null\n', env_unset = { "TILLANDSIAS_*" }, timeout_ms = 30000 }
    return "\n" .. (r.stdout or ""):gsub("\r", ""), "rc=" .. tostring(r.code) .. " " .. (r.stdout or "") .. (r.stderr or ""):sub(1, 300)
end
local o, why = resolver{ HOME = w.abs .. "/home", WANT = w.abs .. "/home/.cargo/bin/cargo" }
T:arm("10a the resolver returns ~/.cargo/bin's cargo", text.contains(o, "\ngot=" .. w.abs .. "/home/.cargo/bin/cargo\n"), why)
o, why = resolver{ HOME = "", WANT = "none" }
T:arm("10b with HOME and CARGO_HOME unset it tries PATH alone, never /bin or /.cargo/bin", text.contains(o, "\ngot=nil\n") and text.contains(o, "\ntried=cargo\n") and not text.contains(o, "\ntried=/"), why)
o, why = resolver{ HOME = w.abs .. "/empty-home", CARGO_HOME = w.abs .. "/altcargo", WANT = w.abs .. "/altcargo/bin/cargo" }
T:arm("10c CARGO_HOME comes first", text.contains(o, "\ngot=" .. w.abs .. "/altcargo/bin/cargo\n") and not text.contains(o, "\ntried=" .. w.abs .. "/empty-home"), why)
T:finish()
