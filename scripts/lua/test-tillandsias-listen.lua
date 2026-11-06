-- @trace order:2007-hear
-- @env PATH
--
-- test-tillandsias-listen.lua — the forge's listening page for audio candidates
-- (images/default/cli/tillandsias-listen), on a project that is not tillandsias:
-- a scratch git repo for a game's sound effects.
--   1 HOSTILE   file names and sidecar text are escaped: a file named like an
--               <img onerror> tag and a sidecar prompt holding </li><script> are
--               shown as text, never as markup, and links are URL-quoted
--   2 LISTED    every audio file (flac, mp3, wav) gets one <audio controls>
--               row; a .txt beside them does not
--   3 IGNORED   a folder git ignores gets index.html, and git status is unchanged
--   4 UNTRACKED a folder git does not ignore is REFUSED folder_in_git and no
--               index.html is written
--   5 TRACKED   a folder holding a tracked file is refused the same way
--   6 ALLOW     --allow-tracked writes it anyway
--   7 ENCLOSED  a folder inside another repo that ignores it (this checkout's
--               target/) gets index.html
-- Red before 2007-hear: the tool did not exist.
--
-- Usage: tillandsias-plan script run scripts/lua/test-tillandsias-listen.lua

local TOOL = "images/default/cli/tillandsias-listen"
if not fs.exists(TOOL) then
    verdict.emit("violation:tillandsias-listen:no-subject", 1, TOOL .. " does not exist")
end
local PATHV = env.get("PATH") or "/usr/bin:/bin"
local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
local REL = "target/plan-scratch/tl" .. tostring(math.random(100000, 999999))
local DIR = ROOT .. "/" .. REL
-- The scratch repo lives OUTSIDE this checkout's tree of tracked files, but
-- under target/ which this checkout ignores; it gets its own `git init`.
local R = DIR .. "/game"
fs.mkdir(REL .. "/game/sfx/takes")
fs.mkdir(REL .. "/game/sfx/loose")
fs.mkdir(REL .. "/game/sfx/kept")
fs.mkdir(REL .. "/nogit")
local function g(...)
    return proc.run({ argv = { "git", "-C", R, ... }, env = { PATH = PATHV, HOME = DIR, GIT_CONFIG_NOSYSTEM = "1" },
        timeout_ms = 30000 })
end
g("init", "-q")
fs.write(REL .. "/game/.gitignore", "sfx/takes/\n")
fs.write(REL .. "/game/sfx/kept/theme.flac", "fLaC kept")
g("add", ".gitignore", "sfx/kept/theme.flac")
g("-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid", "commit", "-q", "-m", "base")

local HOSTILE = "<img src=x onerror=alert(1)>.flac"
for _, n in ipairs({ HOSTILE, "a\"b'&c.mp3", "jump.wav", "notes.txt" }) do
    fs.write(REL .. "/game/sfx/takes/" .. n, "audio bytes")
end
fs.write(REL .. "/game/sfx/takes/jump.wav.provenance.json",
    '{"workflow":"tool/sfx.api.json","seed":7,"prompt":"</li><script>alert(2)</script>"}')
fs.write(REL .. "/game/sfx/loose/hit.flac", "audio bytes")
fs.write(REL .. "/nogit/a.ogg", "audio bytes")

local function run(args)
    local argv = { "python3", ROOT .. "/" .. TOOL }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local r = proc.run({ argv = argv, env = { PATH = PATHV, HOME = DIR, GIT_CONFIG_NOSYSTEM = "1" }, timeout_ms = 60000 })
    return r.code, r.stdout or "", r.stderr or ""
end
local function has(s, n) return (s or ""):find(n, 1, true) ~= nil end
local function count(s, n) local c, i = 0, 1
    while true do local j = (s or ""):find(n, i, true); if not j then return c end; c = c + 1; i = j + 1 end
end
local function status() return (g("status", "--porcelain", "--ignored=no").stdout or "") end

local failed, passed = {}, 0
local function arm(name, cond, got)
    if cond then
        passed = passed + 1
        out.line("ok:   " .. name)
    else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got):gsub("\n", " | "))
        failed[#failed + 1] = name
    end
end

local before = status()
local c, o, e = run({ R .. "/sfx/takes" })
local page = fs.read(REL .. "/game/sfx/takes/index.html") or ""
arm("1 HOSTILE names and sidecar text are escaped, never markup", c == 0
    and has(page, "&lt;img src=x onerror=alert(1)&gt;.flac")
    and not has(page, "<img src=x") and not has(page, "<script>")
    and has(page, "&lt;/li&gt;&lt;script&gt;alert(2)&lt;/script&gt;")
    and has(page, 'src="%3Cimg%20src%3Dx%20onerror%3Dalert%281%29%3E.flac"')
    and has(page, "a&quot;b&#x27;&amp;c.mp3"), c .. " " .. e .. page)
arm("2 LISTED one player per audio file, none for the .txt", count(page, "<audio controls") == 3
    and not has(page, "notes.txt") and has(o, '"files": 3'), page)
arm("3 IGNORED an ignored folder gets the page and git status is unchanged",
    c == 0 and status() == before, before .. " -> " .. status())

c, o, e = run({ R .. "/sfx/loose" })
arm("4 UNTRACKED a folder git does not ignore is refused, nothing written", c == 2
    and has(e, "refused:tillandsias-listen:folder_in_git") and has(e, "not ignored")
    and not fs.exists(REL .. "/game/sfx/loose/index.html"), c .. " " .. e)

c, o, e = run({ R .. "/sfx/kept" })
arm("5 TRACKED a folder with a tracked file is refused", c == 2 and has(e, "git tracks files")
    and not fs.exists(REL .. "/game/sfx/kept/index.html"), c .. " " .. e)

c, o, e = run({ R .. "/sfx/loose", "--allow-tracked" })
arm("6 ALLOW --allow-tracked writes it anyway", c == 0 and fs.exists(REL .. "/game/sfx/loose/index.html"), c .. " " .. e)

c, o, e = run({ DIR .. "/nogit" })
arm("7 ENCLOSED a folder an enclosing repo ignores gets the page", c == 0
    and has(fs.read(REL .. "/nogit/index.html") or "", "a.ogg"), c .. " " .. e)

proc.run({ argv = { "rm", "-rf", DIR }, timeout_ms = 30000 })
if #failed > 0 then
    verdict.emit("violation:tillandsias-listen:" .. table.concat(failed, ","), 1, passed .. " passed")
end
verdict.ok("tillandsias-listen", passed .. " arms")
