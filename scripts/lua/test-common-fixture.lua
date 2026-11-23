-- @trace order:2080-zcur, order:2084-senw, order:2158-vrb7
--
-- test-common-fixture.lua — the shared Lua test kit resolves through the
-- runner's `require` and does what its users rely on.
--   1 require "common.fixture" and "common.verdict" return module tables
--     (pre-fix: no require global, the script errors before any arm)
--   2 a bad module name is refused, never resolved outside lib/lua
--   3 repo_root() is absolute and accepted as a proc.run cwd
--   4 git_repo() builds a repo with one commit on main and a local identity
--   5 scratch dirs are gone after cleanup
--   6 T:scratch().abs works as a git remote (init --bare, remote add, push)
--   7 T:scratch().abs is accepted by rm -rf
--     (6, 7 pre-2158-vrb7 on msys: .abs was \\?\C:\..., refused by both)
--   8 plain_path strips \\?\ and \\?\UNC\, leaves other paths unchanged
--  10 native_path: /c/x -> C:/x and \\?\C:\x -> C:/x on native Windows; identity
--     for /c/x elsewhere (a legal directory there)
--  11 plan_binary is absolute, native, and runs
--   9 posix_shell is Git's bash.exe on native Windows, else the caller's default ("bash" when none)
--
-- Usage: tillandsias-plan script run scripts/lua/test-common-fixture.lua
-- Verdict: ok:common-fixture:<n> arms | violation:common-fixture:<n>-failed
-- msys record: yolanda 2026-11-22 msys ok:common-fixture:11 arms (at 1eb143c62, 3 runs; one earlier red on arm 11 with --version, unexplained, now probed with build-id and reported)

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

-- 2158-vrb7: .abs goes straight to git and rm. Pre-fix on msys it was
-- \\?\C:\..., which git reads as a //host/share and the rm policy refuses.
local function try(argv)
    local ok, res = pcall(T.run, T, argv)
    if not ok then return { code = -1, stdout = "", stderr = tostring(res) } end
    return res
end
local O, W = T:scratch("origin"), T:git_repo("work")
local i = try{ "git", "init", "-q", "--bare", O.abs }
local a = try{ "git", "-C", W.abs, "remote", "add", "origin", O.abs }
local p = try{ "git", "-C", W.abs, "push", "-q", "origin", "main" }
local c = try{ "git", "-C", O.abs, "rev-parse", "--verify", "-q", "refs/heads/main" }
T:arm("6 scratch .abs works as a git remote: init, remote add, push",
    i.code == 0 and a.code == 0 and p.code == 0 and c.code == 0,
    O.abs .. " | " .. (p.stderr or "") .. (a.stderr or ""))
local J = T:scratch("junk")
fs.write(J.rel .. "/f", "z")
local rm = try{ "rm", "-rf", J.abs .. "/" }
T:arm("7 scratch .abs is accepted by rm -rf", rm.code == 0 and not fs.exists(J.rel .. "/f"), J.abs .. " | " .. (rm.stderr or ""))
T:arm("8 plain_path strips the verbatim prefix and leaves other paths alone",
    fixture.plain_path("\\\\?\\C:\\a\\b") == "C:/a/b"
        and fixture.plain_path("\\\\?\\UNC\\srv\\s\\x") == "//srv/s/x"
        and fixture.plain_path("/home/x") == "/home/x" and fixture.plain_path("C:/a") == "C:/a",
    fixture.plain_path("\\\\?\\C:\\a\\b"))

local d = T:scratch()
fs.write(d.rel .. "/x", "y")
T:cleanup()
T:arm("5 cleanup removes every scratch dir", not fs.exists(d.rel) and not fs.exists(repo.rel), d.rel)

-- 9 (2246-fkea). Native Windows: Git's own bash, whatever default is asked.
-- Elsewhere: the default the caller names, "bash" when it names none.
do
    local ep = text.trim(proc.run{ argv = { "git", "--exec-path" }, timeout_ms = 10000 }.stdout or "")
    local a, b = fixture.posix_shell(), fixture.posix_shell("/bin/bash")
    local native_win = ep:find("^%a:/.*/libexec/git%-core$") ~= nil
    T:arm("9 posix_shell is Git's bash on native Windows, else the caller's default",
        native_win and (a == b and a:find("/bin/bash%.exe$") ~= nil)
            or (not native_win and a == "bash" and b == "/bin/bash"),
        "exec-path=" .. ep .. " posix_shell()=" .. a .. " posix_shell(\"/bin/bash\")=" .. b)
end

-- 10, 11 (2246-fkea): the third Windows trap, an msys path a native spawn
-- cannot resolve.
do
    local win = fixture.posix_shell() ~= "bash"
    local a, b = fixture.native_path("/c/Users/x"), fixture.native_path("\\\\?\\C:\\a\\b")
    T:arm("10 native_path makes an msys drive path native on Windows and leaves it alone elsewhere",
        b == "C:/a/b" and ((win and a == "C:/Users/x") or (not win and a == "/c/Users/x"))
            and fixture.native_path("/home/x") == "/home/x" and fixture.native_path("C:/a") == "C:/a",
        "win=" .. tostring(win) .. " /c/Users/x->" .. a .. " verbatim->" .. b)
    local pb = fixture.plan_binary()
    local abs = pb:sub(1, 1) == "/" or pb:find("^%a:/") ~= nil
    -- `build-id` exits 0 with no stderr; `--version` is not a subcommand and
    -- printed ~40 KB of usage (rc 2), and once on msys the arm went red with
    -- no reason recorded (yolanda, 2026-11-22). The detail now says why.
    local r = pb ~= "" and proc.run{ argv = { pb, "build-id" }, timeout_ms = 60000 } or {}
    local ran = r.status == "exited" and r.code == 0
    T:arm("11 plan_binary is absolute, native and spawnable",
        abs and ran and not (win and pb:find("^/%a/")),
        "plan_binary()=" .. pb .. " build-id status=" .. tostring(r.status) .. " code=" .. tostring(r.code)
            .. " why=" .. tostring(r.why or r.reason))
end

T:finish()
