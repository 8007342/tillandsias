-- @trace order:2453-ap8y
--
-- test-fs-msys-path-scope.lua — the fs verbs accept a path under the repo in
-- BOTH spellings a Windows host hands a script: C:/... (native) and /c/...
-- (msys, from Git bash). Before 2453-ap8y the runner read /c/... as a
-- drive-relative path, joined it onto the root (C:\c\Users\...), and refused it
-- as "outside the repository root"; fs.walk also refused the C:/ spelling,
-- because its in-repo check compared a verbatim \\?\C:\ canonical path with the
-- C:\ root. doris's msys census (2026-11-27) traced about 9 fixture reds to this.
--
--   1 EXISTS-MSYS   fs.exists("/c/<repo>/target/...") answers true
--   2 READ-MSYS     fs.read of the same file returns its content
--   3 WALK-MSYS     fs.walk("/c/<repo>/target/...") lists the file
--   4 WALK-NATIVE   fs.walk("C:/<repo>/target/...") lists the file
--   5 READ-NATIVE   fs.read("C:/...") still works (control: unchanged path)
--   6 OUTSIDE       an msys path OUTSIDE the repo is still refused: the
--                   translation widens nothing, the scope check still applies
--
-- Windows-only by construction: elsewhere /c/... is an ordinary absolute path
-- that does not exist, so the fixture names a skip instead of passing vacuously.
--
-- PRE-FIX RESULT (yolanda, msys, trunk binary 2026-11-28): arms 1, 2, 3 and 4
-- refused (exists/read "outside the repository root", walk "must be
-- repo-relative" and "outside the repo and every declared read root").
--
-- Verdict: ok:fs-msys-path-scope:<n> arms | violation:...:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("fs-msys-path-scope")

local d = T:scratch("msys")
local native = d.abs:gsub("\\", "/")
local drive, rest = native:match("^(%a):(/.*)$")
if not drive then
    T:skip("not-a-windows-path:scratch is " .. native .. "; the msys spelling exists only on Windows")
end
local msys = "/" .. drive:lower() .. rest

fs.write(d.rel .. "/f.txt", "hi\n")

local function try(f)
    local ok, v = pcall(f)
    return ok, v
end

local ok1, v1 = try(function() return fs.exists(msys .. "/f.txt") end)
T:arm("1 EXISTS-MSYS fs.exists answers true for an msys path under <repo>/target", ok1 and v1 == true, tostring(v1))

local ok2, v2 = try(function() return fs.read(msys .. "/f.txt") end)
T:arm("2 READ-MSYS fs.read returns the file's content", ok2 and v2 == "hi\n", tostring(v2))

local ok3, v3 = try(function() return fs.walk(msys) end)
T:arm("3 WALK-MSYS fs.walk lists the one file", ok3 and type(v3) == "table" and #v3 == 1, tostring(ok3 and #v3 or v3))

local ok4, v4 = try(function() return fs.walk(native) end)
T:arm("4 WALK-NATIVE fs.walk of the C:/ spelling lists the one file", ok4 and type(v4) == "table" and #v4 == 1,
    tostring(ok4 and #v4 or v4))

local ok5, v5 = try(function() return fs.read(native .. "/f.txt") end)
T:arm("5 READ-NATIVE fs.read of the C:/ spelling is unchanged", ok5 and v5 == "hi\n", tostring(v5))

-- The windows directory is outside every repo, and always present.
local ok6, v6 = try(function() return fs.exists("/" .. drive:lower() .. "/Windows/win.ini") end)
T:arm("6 OUTSIDE an msys path outside the repo is still refused", not ok6 and tostring(v6):find("outside", 1, true) ~= nil,
    tostring(v6):sub(1, 200))

T:finish()
