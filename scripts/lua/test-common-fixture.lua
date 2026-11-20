-- @trace order:2080-zcur, order:2084-senw
--
-- test-common-fixture.lua — the shared Lua test kit resolves through the
-- runner's `require` and does what its users rely on.
--   1 require "common.fixture" and "common.verdict" return module tables
--     (pre-fix: no require global, the script errors before any arm)
--   2 a bad module name is refused, never resolved outside lib/lua
--   3 repo_root() is absolute and accepted as a proc.run cwd
--   4 git_repo() builds a repo with one commit on main and a local identity
--   5 scratch dirs are gone after cleanup
--
-- Usage: tillandsias-plan script run scripts/lua/test-common-fixture.lua
-- Verdict: ok:common-fixture:<n> arms | violation:common-fixture:<n>-failed

local fixture = require "common.fixture"
local V = require "common.verdict"
local T = fixture.new("common-fixture")

T:arm("1 require resolves common.fixture and common.verdict",
    type(fixture.new) == "function" and type(V.ok) == "function"
        and require "common.fixture" == fixture, type(fixture))

local okp, err = pcall(require, "../etc/passwd")
T:arm("2 a module name with a path separator is refused", not okp and tostring(err):find("not a module name", 1, true), err)

local root = fixture.repo_root()
local r = proc.run{ argv = { "git", "rev-parse", "--is-inside-work-tree" }, cwd = root }
T:arm("3 repo_root is absolute and a valid cwd",
    (root:sub(1, 1) == "/" or root:find("^%a:/")) and r.code == 0, root)

local repo = T:git_repo()
local log = T:run{ "git", "log", "--format=%an %s", "main", cwd = repo.abs }
T:arm("4 git_repo has one commit on main by the fixture identity",
    log.code == 0 and text.trim(log.stdout) == "fixture init", log.stdout .. log.stderr)

local d = T:scratch()
fs.write(d.rel .. "/x", "y")
T:cleanup()
T:arm("5 cleanup removes every scratch dir", not fs.exists(d.rel) and not fs.exists(repo.rel), d.rel)

T:finish()
