-- @trace order:2246-fkea
--
-- test-lua-fixture-native-argv-added.lua — pins
-- scripts/lua/check-lua-fixture-native-argv-added.lua, the decider that
-- refuses the two native-Windows traps in ADDED Lua fixture lines: a root from
-- `pwd -P` and a bare "bash"/"sed" argv. Each arm builds a scratch repo with a
-- base commit, adds one Lua file on top, and runs the decider there.
--
--   1 PWD       an added { "pwd", "-P" } is refused, naming repo_root()
--   2 BASH      an added { "bash", ... } argv is refused, naming posix_shell()
--   3 SED       an added { "sed", ... } argv is refused
--   4 HELPER    the helper form (repo_root(), posix_shell()) is admitted
--   5 MARKER    a shape with a `native-argv: <why>` marker above it is admitted
--   6 COMMENT   a shape inside a comment line is admitted
--   7 STANDING  a shape already in the base is not re-litigated: the change
--               edits THAT file, and only its own added line is judged
--   9 PWD-JOIN  an added probe that joins "$PWD/${p#./}" in the shell is refused,
--               naming plan_binary()
--   8 NO-BASE   a base that does not exist (40 hex) is named base-unavailable,
--               never judged ok as checked
--
-- Before 2246-fkea there was no such decider: every arm below that expects a
-- refusal was green on every host, and the shape reached a Windows gate first.
--
-- Verdict: ok:lua-fixture-native-argv-added-fixture:<n> arms | violation:...:<n>-failed
-- msys record: yolanda 2026-11-22 msys ok:lua-fixture-native-argv-added-fixture:9 arms (at 1eb143c62; at 404aaf29e all 8 arms were rc=-1, the $PWD probe join)

local fixture = require "common.fixture"
local T = fixture.new("lua-fixture-native-argv-added-fixture")
local ROOT = fixture.repo_root()
local GUARD = ROOT .. "/scripts/lua/check-lua-fixture-native-argv-added.lua"

local PB = fixture.plan_binary()
if PB == "" then T:refuse("no-plan-binary", "plan-binary-probe resolved nothing") end

-- A scratch repo whose base commit holds `standing` (if any) under
-- scripts/lua/, then `added` written on top, uncommitted or committed.
local function judge(tag, added, standing, base_override, into_old)
    local repo = T:git_repo(tag)
    proc.run{ argv = { "mkdir", "-p", repo.abs .. "/scripts/lua" } }
    if standing then
        fs.write(repo.rel .. "/scripts/lua/old.lua", standing)
        T:must{ "git", "-C", repo.abs, "add", "-A" }
        T:must{ "git", "-C", repo.abs, "commit", "-q", "-m", "base" }
    end
    T:must{ "git", "-C", repo.abs, "branch", "-f", "base" }
    if added then
        if into_old then  -- append to the file that holds the standing shape
            fs.write(repo.rel .. "/scripts/lua/old.lua", standing .. added)
        else
            fs.write(repo.rel .. "/scripts/lua/new.lua", added)
        end
        T:must{ "git", "-C", repo.abs, "add", "-A" }
        T:must{ "git", "-C", repo.abs, "commit", "-q", "-m", "change" }
    end
    local r = T:run{ PB, "script", "run", GUARD, cwd = repo.abs, timeout_ms = 120000,
        env = { TILLANDSIAS_NATIVE_ARGV_BASE = base_override or "base", TILLANDSIAS_GATE_DIFF_BASE = "" } }
    local o = text.trim(r.stdout or "")
    return (r.status == "exited" and r.code or -1), o, (r.stderr or "")
end

local rc, o, e
-- native-argv: the arms below WRITE the refused shapes as fixture data.
rc, o, e = judge("pwd", 'local root = text.trim(proc.run{ argv = { "pwd", "-P" } }.stdout or "")\n')
T:arm("1 PWD an added pwd -P root is refused, naming repo_root()",
    rc == 1 and o == "violation:lua-fixture-native-argv-added:1" and text.contains(e, "repo_root()"),
    "rc=" .. rc .. " out=" .. o .. " err=" .. e)

rc, o, e = judge("bash", 'local r = proc.run{ argv = { "bash", "-s" }, stdin = "true" }\n')  -- native-argv: fixture data
T:arm("2 BASH an added bare bash argv is refused, naming posix_shell()",
    rc == 1 and o == "violation:lua-fixture-native-argv-added:1" and text.contains(e, "posix_shell()"),
    "rc=" .. rc .. " out=" .. o .. " err=" .. e)

rc, o, e = judge("sed", 'local r = proc.run{ argv = { "sed", "-n", "1p", "f" } }\n')  -- native-argv: fixture data
T:arm("3 SED an added bare sed argv is refused",
    rc == 1 and o == "violation:lua-fixture-native-argv-added:1",
    "rc=" .. rc .. " out=" .. o)

rc, o = judge("helper", table.concat({
    'local fixture = require "common.fixture"',
    'local root = fixture.repo_root()',
    'local r = proc.run{ argv = { fixture.posix_shell(), "-s" }, cwd = root, stdin = "true" }', "" }, "\n"))
T:arm("4 HELPER the repo_root()/posix_shell() form is admitted",
    rc == 0 and o == "ok:lua-fixture-native-argv-added:1 checked", "rc=" .. rc .. " out=" .. o)

rc, o = judge("marker", '-- native-argv: pins the MSYS answer itself\nlocal r = proc.run{ argv = { "pwd", "-P" } }\n')
T:arm("5 MARKER a shape with a native-argv: reason just above it is admitted",
    rc == 0 and o == "ok:lua-fixture-native-argv-added:1 checked", "rc=" .. rc .. " out=" .. o)

rc, o = judge("comment", '-- never write { "bash", "-s" } here; use posix_shell()\nlocal x = 1\n')  -- native-argv: fixture data
T:arm("6 COMMENT a shape inside a comment line is admitted",
    rc == 0 and o == "ok:lua-fixture-native-argv-added:1 checked", "rc=" .. rc .. " out=" .. o)

rc, o, e = judge("standing", 'local root = fixture.repo_root()\n',
    'local old = proc.run{ argv = { "bash", "-s" } }\n', nil, true)  -- native-argv: fixture data
T:arm("7 STANDING a shape already in the base is not judged; the change's clean line passes",
    rc == 0 and o == "ok:lua-fixture-native-argv-added:1 checked" and not text.contains(e, "REFUSED"),
    "rc=" .. rc .. " out=" .. o .. " err=" .. e)

rc, o = judge("nobase", 'local r = proc.run{ argv = { "bash" } }\n', nil, string.rep("de", 20))  -- native-argv: fixture data
T:arm("8 NO-BASE a missing 40-hex base is named base-unavailable, not judged",
    rc == 0 and o == "ok:lua-fixture-native-argv-added:base-unavailable", "rc=" .. rc .. " out=" .. o)

rc, o, e = judge("pwdjoin", "local s = 'case \"$p\" in ./*) p=\"$PWD/${p#./}\" ;; esac'\n")  -- native-argv: fixture data
T:arm("9 PWD-JOIN an added in-shell $PWD probe join is refused, naming plan_binary()",
    rc == 1 and o == "violation:lua-fixture-native-argv-added:1" and text.contains(e, "plan_binary()"),
    "rc=" .. rc .. " out=" .. o .. " err=" .. e)

T:finish()
