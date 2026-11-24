-- @trace order:2080-zcur, order:2084-senw, order:2158-vrb7
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

-- ORDER 2246-fkea (from 2218-x4s3). The POSIX shell a fixture spawns, by a
-- name the native runner can run on every host. On native Windows a bare
-- `bash` resolves to WSL's bash.exe (another filesystem, another git), and
-- /bin/bash does not exist; Git for Windows ships its own, next to git:
-- `git --exec-path` answers <env>/libexec/git-core (mingw64/ or ucrt64/, per
-- Git build), and the shell is <env>/bin/bash.exe. Everywhere else, the
-- caller's default: "bash" (PATH) unless it names one, e.g. "/bin/bash" for a
-- site that must run the shell build.sh is written for (on macOS /bin/bash is
-- 3.2 and PATH may find a newer one; the two are not interchangeable).
-- Use it as argv[1] wherever a fixture would write "bash":
--   proc.run{ argv = { fixture.posix_shell(), "-s" }, stdin = ... }
-- check-lua-fixture-native-argv-added.lua refuses a bare "bash" in an added
-- scripts/lua file, and a root taken from `pwd -P` (use repo_root()).
local GIT_BASH -- false once probed and absent
function M.posix_shell(default)
    if GIT_BASH == nil then
        GIT_BASH = false
        local r = proc.run{ argv = { "git", "--exec-path" }, timeout_ms = 10000 }
        local ep = text.trim(r.stdout or "")
        if ep:find("^%a:/.*/libexec/git%-core$") then  -- mingw64/ or ucrt64/, per Git build
            GIT_BASH = (ep:gsub("/[^/]+/libexec/git%-core$", "/bin/bash.exe"))
        end
    end
    return GIT_BASH or default or "bash"
end

-- ORDER 2257-qnt7. Where PATH finds a tool, or nil. Never spawn `which`: it is a
-- package of its own, absent in the WSL builder, where a spawn failure read as
-- "the tool is missing". `type -P` is bash's own PATH search: no function,
-- alias or builtin. path: the PATH to search (default: this process's). On
-- native Windows the answer is made spawnable (2258-6xu8): /usr/bin/bash is an MSYS
-- mount no drive rule can map, so cygpath says where it is, and the .exe that
-- msys hides is put back.
function M.which(tool, path)
    -- The PATH is set inside the shell: a narrow one must not stop it starting.
    local r = proc.run{ argv = { M.posix_shell(), "-s", "--", tool, path }, timeout_ms = 10000,
        stdin = '[ $# -lt 2 ] || P="$2"\nhit="$(PATH="${P-$PATH}"; type -P -- "$1")" || exit 1\n'
            .. 'if command -v cygpath >/dev/null 2>&1; then\n'
            .. '  case "$hit" in (*.exe) ;; (*) [ ! -f "$hit.exe" ] || hit="$hit.exe" ;; esac\n'
            .. '  hit="$(cygpath -m -- "$hit")" || exit 1\nfi\nprintf "%s\\n" "$hit"\n' }
    local p = text.trim(r.stdout or "")
    if r.code ~= 0 or p == "" then return nil end
    return p
end

-- ORDER 2246-fkea. A path a native spawn can resolve, from whatever spelling a
-- shell or the scratch door handed back: an MSYS drive path /c/x becomes C:/x
-- (Git bash's $PWD and resolve_plan_binary answer that form, and a native
-- CreateProcess cannot find it: "The system cannot find the path specified"),
-- and a verbatim \\?\C:\x becomes C:/x (plain_path). Anything else is
-- returned unchanged, so on Linux and macOS this is the identity: /c/x is
-- only rewritten when the runner is native Windows (posix_shell() found
-- Git's bash), because /c is a legal directory everywhere else.
function M.native_path(p)
    if type(p) ~= "string" then return p end
    p = M.plain_path(p)
    if M.posix_shell() ~= "bash" then  -- "bash" with no default = not native Windows
        local drive, rest = p:match("^/(%a)/(.*)$")
        if drive then return drive:upper() .. ":/" .. rest end
        drive = p:match("^/(%a)$")
        if drive then return drive:upper() .. ":/" end
    end
    return p
end

-- ORDER 2246-fkea. The plan binary for a fixture to spawn: the probe
-- (scripts/plan-binary-probe.sh) run under posix_shell(), its answer joined
-- to repo_root() when relative and made native with native_path(). "" when
-- the probe resolves nothing. Never build "$PWD/..." inside the probe's
-- shell: under Git bash that is /c/..., which a native spawn cannot resolve.
function M.plan_binary()
    local root = M.repo_root()
    local r = proc.run{ argv = { M.posix_shell(), "-s" }, cwd = root, timeout_ms = 60000,
        stdin = '. scripts/plan-binary-probe.sh\np="$(resolve_plan_binary 2>/dev/null)" || p=""\nprintf "%s" "$p"\n' }
    local p = text.trim(r.stdout or "")
    if p == "" then return "" end
    if p:sub(1, 2) == "./" then p = root .. "/" .. p:sub(3)
    elseif not (p:sub(1, 1) == "/" or p:find("^%a:[/\\]")) then p = root .. "/" .. p end
    return M.native_path(p)
end

-- ORDER 2253-j2at. An absolute path in either spelling the fleet produces:
-- /x on Linux, macOS and MSYS, and a drive path C:/x or C:\x on native
-- Windows. A check written `p:sub(1, 1) == "/"` reads every Windows path as
-- relative (macuahuitl relayed: the Mac's attest-smoke hit the same bug).
function M.is_abs(p)
    if type(p) ~= "string" or p == "" then return false end
    return p:sub(1, 1) == "/" or p:find("^%a:[/\\]") ~= nil
end

local SCRATCH = "target/plan-scratch"

-- ORDER 2158-vrb7. scratch.mkdir returns a Windows verbatim path (\\?\C:\...).
-- git reads it as //host/share ("hostname contains invalid characters") and
-- the rm policy reads it as outside the workspace. Hand out the plain form,
-- C:/..., the spelling repo_root() already uses. Non-verbatim paths pass as-is.
function M.plain_path(p)
    if type(p) ~= "string" then return p end
    local rest = p:match("^\\\\%?\\UNC\\(.*)$")
    if rest then return "//" .. (rest:gsub("\\", "/")) end
    rest = p:match("^\\\\%?\\(%a:.*)$")
    if rest then return (rest:gsub("\\", "/")) end
    return p
end

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
    local d = { rel = SCRATCH .. "/" .. leaf, abs = M.plain_path(scratch.mkdir(leaf)), leaf = leaf }
    self.dirs[#self.dirs + 1] = d
    return d
end

-- A scratch dir with the shortest name the kit can give, for a fixture whose
-- subject is path length (unix-socket SUN_LEN). Same {rel=, abs=} and cleanup.
function T:short_scratch()
    self.seq = self.seq + 1
    local leaf = "s" .. tostring(time.now_ms() % 10000000) .. self.seq
    scratch_root()
    local d = { rel = SCRATCH .. "/" .. leaf, abs = M.plain_path(scratch.mkdir(leaf)), leaf = leaf }
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
