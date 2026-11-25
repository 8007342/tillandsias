-- @env PATH HOME
-- @trace order:1375-tsfu, order:2359-a3c5
--
-- test-check-jq-callsite-ratchet.lua — check-jq-callsite-ratchet.sh counts jq call sites, blocks a
-- new one `json get` already answers, and its floor only falls. Ported from the .sh of the same
-- name (2359-a3c5). Scratch trees are not repositories to git (a ceiling), so the guard
-- walks them as it would a tarball.
--
--   1 the real tree is at or below its floor, and git grep counts the same
--   2 a new in-subset site is blocked by name     3 one outside the subset only warns
--   4 an empty population is blocked              5 --ratchet lowers a floor and never raises one
--   6 unknown argument, 7 empty population, 8 no plan binary: why and remedy, and the remedy clears it
--
-- Usage: tillandsias-plan script run scripts/lua/test-check-jq-callsite-ratchet.lua
-- Verdict: ok:check-jq-callsite-ratchet:<n> arms | violation:... | could-not-run:... (exit 3)

local fixture = require "common.fixture"
local T = fixture.new("check-jq-callsite-ratchet")
local SH, PLAN, ROOT = fixture.posix_shell(), fixture.plan_binary(), fixture.repo_root()
local GUARD = ROOT .. "/scripts/check-jq-callsite-ratchet.sh"
-- Exit 3: the gate step nominates it as its skip.
if PLAN == "" then verdict.emit("could-not-run:check-jq-callsite-ratchet:no-plan-binary", 3) end
local caps = T:run{ PLAN, "capabilities" }
if not text.contains("\n" .. (caps.stdout or ""), "\njson\n") then verdict.emit("could-not-run:check-jq-callsite-ratchet:plan-binary-lacks-json-verb", 3) end
local Q = "j" .. "q" -- COMPOSED, so this file holds no call site
local ceiling
local function guard(plan, ...)
    local argv = { SH, GUARD }
    for _, a in ipairs{ ... } do argv[#argv + 1] = a end
    local r = proc.run{ argv = argv, cwd = ROOT, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 120000,
        env = { PATH = env.get("PATH"), HOME = env.get("HOME"), TILLANDSIAS_PLAN_BIN = plan or PLAN, GIT_CEILING_DIRECTORIES = ceiling } }
    local o, e = (r.stdout or ""):gsub("\r", ""), (r.stderr or ""):gsub("\r", "")
    return { rc = r.code, out = o, all = "\n" .. o .. e, err = "\n" .. e, why = "rc=" .. tostring(r.code) .. " " .. o:sub(1, 300) .. e:sub(1, 300) }
end
local function has(x, s) return text.contains(x.all, s) end
local function line(x, s) return text.contains("\n" .. x.all .. "\n", "\n" .. s .. "\n") end
local function afford(x) return text.contains(x.err, "\n  why: ") and text.contains(x.err, "\n  remedy: ") end

local x = guard()
local n, f = x.all:match("\nok:jq%-callsites:(%d+):floor:(%d+)")
local g = T:run{ SH, "-s", "--", GUARD, cwd = ROOT, env_unset = { "TILLANDSIAS_*" }, stdin = [==[
eval "$(grep -E "^P[123]=" "$1")"
git grep -cE -e "$P1" -e "$P2" -e "$P3" -- 'scripts/*.sh' build.sh launch.sh 'openspec/litmus-tests/*.yaml' ':!scripts/check-jq-callsite-ratchet.sh' | awk -F: '{ s += $NF } END { print s + 0 }'
]==] }
T:arm("1 the tree is at or below its floor, and git grep counts the same", x.rc == 0 and n ~= nil and tonumber(n) <= tonumber(f) and text.trim(g.stdout or "") == n, x.why .. " git grep=" .. text.trim(g.stdout or ""))

local function tree(files)
    local d = T:scratch()
    ceiling = d.abs:match("^(.*)/[^/]*$")
    fs.mkdir(d.rel .. "/scripts/portability")
    fs.write(d.rel .. "/scripts/plan-binary-probe.sh", fs.read("scripts/plan-binary-probe.sh"))
    fs.write(d.rel .. "/scripts/old.sh", "#!/bin/bash\nv=$(" .. Q .. " -r .x in.json)\n")
    fs.write(d.rel .. "/scripts/portability/jq-callsite-floor.txt", "1 scripts/old.sh\n" .. (files.floor or ""))
    for name, body in pairs(files) do
        if name ~= "floor" then fs.write(d.rel .. "/scripts/" .. name .. ".sh", "#!/bin/bash\n" .. body) end
    end
    return d
end
local ADDED = "blocked:jq-callsite-added:scripts/new.sh:.a"
local d = tree{ new = "x=$(" .. Q .. " -r .a f.json)\n" }
x = guard(nil, "--root", d.abs)
T:arm("2 a new site inside the subset is blocked by name", x.rc == 1 and line(x, ADDED), x.why)
d = tree{ new = Q .. " -c 'group_by(.k)' f.json\n" }
x = guard(nil, "--root", d.abs)
T:arm("3 a new site outside it only warns", x.rc == 0 and has(x, "\nwarn:jq-callsite-added-unsupported:scripts/new.sh:"), x.why)
local empty = T:scratch()
fs.mkdir(empty.rel .. "/scripts/portability")
x = guard(nil, "--root", empty.abs)
T:arm("4 an empty population is blocked, with its counts", x.rc == 1 and x.out == "blocked:jq-ratchet-empty-population\n" and line(x, "population=0 bootstrap=0"), x.why)
T:arm("7a and says why and what clears it", afford(x) and text.contains(x.err, "--root <checkout>"), x.why)

local TWO = "a=$(" .. Q .. " -r .a f)\nb=$(" .. Q .. " -r .b f)\n"
d = tree{ two = TWO, floor = "2 scripts/two.sh\n" }
local FLOOR = d.rel .. "/scripts/portability/jq-callsite-floor.txt"
guard(nil, "--root", d.abs, "--ratchet")
local before = fs.read(FLOOR)
fs.write(d.rel .. "/scripts/two.sh", "#!/bin/bash\na=$(tillandsias-plan json get -r .a f)\nb=$(" .. Q .. " -r .b f)\n")
guard(nil, "--root", d.abs, "--ratchet")
local after = fs.read(FLOOR)
T:arm("5a --ratchet lowers the one floor that fell", text.contains("\n" .. before, "\n2 scripts/two.sh\n") and after == (before:gsub("2 scripts/two%.sh", "1 scripts/two.sh")), before .. " -> " .. after)
fs.write(d.rel .. "/scripts/two.sh", "#!/bin/bash\n" .. TWO)
guard(nil, "--root", d.abs, "--ratchet")
T:arm("5b --ratchet never raises one", text.contains("\n" .. fs.read(FLOOR), "\n1 scripts/two.sh\n"), fs.read(FLOOR))

x = guard(nil, "--bogus")
T:arm("6a an unknown argument says why and names the usage", x.rc == 3 and x.out == "could-not-run:jq-ratchet:unknown-argument:--bogus\n" and afford(x) and text.contains(x.err, "[--ratchet] [--root DIR]"), x.why)
d = tree{}
x = guard(nil, "--root", d.abs)
T:arm("6b, 7b the named usage, at a checkout, clears both", x.rc == 0 and line(x, "ok:jq-callsites:1:floor:1"), x.why)
d = tree{ new = "x=$(" .. Q .. " -r .a f.json)\n" }
x = guard(d.abs .. "/no-such-plan", "--root", d.abs)
T:arm("8a no plan binary says why and names the variable", x.rc == 3 and x.out:sub(1, 40) == "could-not-run:jq-ratchet:no-plan-binary " and afford(x) and text.contains(x.err, "TILLANDSIAS_PLAN_BIN"), x.why)
x = guard(nil, "--root", d.abs)
T:arm("8b with one the classification says why and what to write", x.rc == 1 and line(x, ADDED) and has(x, "\n  why: tillandsias-plan json get already answers '.a'") and has(x, "\n  remedy: tillandsias-plan json get '.a'"), x.why)
T:finish()
