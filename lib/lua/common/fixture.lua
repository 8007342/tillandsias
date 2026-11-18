-- @trace order:2080-zcur, order:2084-senw
-- common.fixture — the shared test kit for scripts/lua/test-*.lua.
--
--   local fixture = require "common.fixture"
--   local T = fixture.new("my-test")
--   local dir = T:scratch()              -- {rel=, abs=}, removed by T:finish()
--   local repo = T:git_repo()            -- scratch dir with `git init` + one commit
--   local r = T:run{ "git", "status", cwd = repo.abs }
--   T:arm("1 name", cond, got)           -- prints "ok:   1 name" / "FAIL: 1 name — got: ..."
--   T:finish()                           -- cleans, then ok:<name>:<n> arms | violation:<name>:<n>-failed
--
-- Exit codes: 0 every arm passed (or skip); 1 an arm failed or the fixture
-- refused to set up (T:refuse). Scratch lives under target/plan-scratch
-- (inside the repo, so fs.* doors reach it), created and removed through the
-- scratch.* door (order 2106-scrt), whose root the kit declares as
-- target/plan-scratch the first time a test asks for a dir. A test that needs
-- its own root outside the repo calls scratch.declare itself and does not use
-- T:scratch. Lines and codes come from common.verdict; never print a verdict
-- line by hand.
local V = require "common.verdict"
local M = {}

-- ORDER 2084-senw. The repo root as an absolute path the native runner
-- accepts as a cwd on every host: git prints C:/... on Windows and /... on
-- Linux, where `pwd -P` under MSYS prints /c/... (a "relative" cwd natively).
local ROOT
function M.repo_root()
    if not ROOT then
        local r = proc.run{ argv = { "git", "rev-parse", "--show-toplevel" } }
        ROOT = text.trim(r.stdout or "")
        if r.code ~= 0 or ROOT == "" then
            error("common.fixture.repo_root: git rev-parse --show-toplevel failed: " .. tostring(r.stderr))
        end
    end
    return ROOT
end

local SCRATCH = "target/plan-scratch"

-- Declare the kit's scratch root once (a no-op when already declared).
local function scratch_root()
    if not scratch.root() then scratch.declare(SCRATCH) end
end

local T = {}
T.__index = T

function M.new(name)
    return setmetatable({ name = name, passed = 0, failed = {}, dirs = {}, seq = 0 }, T)
end

function T:arm(name, cond, got)
    if cond then
        self.passed = self.passed + 1
        out.line("ok:   " .. name)
    else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got))
        self.failed[#self.failed + 1] = name
    end
    return cond
end

-- A fresh scratch dir. rel is repo-relative (for fs.*), abs for argv/cwd.
function T:scratch(tag)
    self.seq = self.seq + 1
    local leaf = self.name .. "-" .. tostring(time.now_ms())
        .. "-" .. self.seq .. (tag and ("-" .. tag) or "")
    scratch_root()
    local d = { rel = SCRATCH .. "/" .. leaf, abs = scratch.mkdir(leaf), leaf = leaf }
    self.dirs[#self.dirs + 1] = d
    return d
end

-- A scratch dir with the shortest name the kit can give, for a fixture whose
-- subject is path length (unix-socket SUN_LEN). Same {rel=, abs=} and cleanup.
function T:short_scratch()
    self.seq = self.seq + 1
    local leaf = "s" .. tostring(time.now_ms() % 10000000) .. self.seq
    scratch_root()
    local d = { rel = SCRATCH .. "/" .. leaf, abs = scratch.mkdir(leaf), leaf = leaf }
    self.dirs[#self.dirs + 1] = d
    return d
end

-- proc.run with argv given positionally; named fields pass through.
function T:run(spec)
    local argv = {}
    for i, a in ipairs(spec) do argv[i] = a end
    return proc.run{ argv = argv, cwd = spec.cwd, env = spec.env, stdin = spec.stdin,
        timeout_ms = spec.timeout_ms or 120000 }
end

-- Run, and refuse the whole test if the setup command fails.
function T:must(spec)
    local r = self:run(spec)
    if r.code ~= 0 then
        self:refuse("setup-failed", table.concat(spec, " ") .. ": " .. tostring(r.status)
            .. " " .. tostring(r.stderr or r.why))
    end
    return r
end

-- A scratch git repo with a fixed identity and one commit on `main`.
-- The identity is local to the repo, so no ambient identity leaks in.
function T:git_repo(tag)
    local d = self:scratch(tag or "repo")
    self:must{ "git", "init", "-q", "-b", "main", d.abs }
    self:must{ "git", "-C", d.abs, "config", "user.email", "fixture@example.invalid" }
    self:must{ "git", "-C", d.abs, "config", "user.name", "fixture" }
    self:must{ "git", "-C", d.abs, "config", "commit.gpgsign", "false" }
    fs.write(d.rel .. "/README", "fixture\n")
    self:must{ "git", "-C", d.abs, "add", "README" }
    self:must{ "git", "-C", d.abs, "commit", "-q", "-m", "init" }
    return d
end

function T:cleanup()
    for _, d in ipairs(self.dirs) do scratch.rm(d.leaf) end
    self.dirs = {}
end

function T:refuse(reason, detail)
    if detail then out.line("refused: " .. tostring(detail)) end
    self:cleanup()
    V.refused(self.name, reason)
end

function T:skip(reason)
    self:cleanup()
    V.skip(self.name, reason)
end

-- opts.ok / opts.fail override the verdict line for a port whose callers
-- grep an established string (exit codes stay 0 / 1).
function T:finish(opts)
    opts = opts or {}
    self:cleanup()
    if #self.failed > 0 then
        if opts.fail then V.emit(opts.fail(#self.failed, self.failed), 1) end
        V.violation(self.name, #self.failed)
    end
    if opts.ok then V.emit(opts.ok(self.passed), 0) end
    V.ok(self.name, self.passed)
end

return M
