-- @trace order:2402-isab
--
-- check-lua-posix-only-absolute.lua — no Lua file decides "is this path absolute?" by its first
-- character alone. On native Windows fixture.plan_binary() and repo_root() hand back C:/...,
-- which `p:sub(1, 1) ~= "/"` reads as relative; the caller then prefixes the repo root and the
-- path points nowhere. Measured on yolanda's msys run of #1627: podman-sync-budgets never
-- spawned the plan binary (rc=nil), and the command-policy hook was handed an unrunnable
-- TILLANDSIAS_PLAN_BIN and allowed everything unchecked.
--
-- Refused: a line with `:sub(1, 1) ~= "/"` (any spacing) that does not also accept a drive
-- path (`%a:`) on the same line. Use fixture.is_abs(p) in a fixture, or
-- `p:sub(1, 1) == "/" or p:find("^%a:[/\\]")` where common.fixture is not loaded.
-- An `== "/"` test is not refused: it is often a deliberate POSIX-only or relative-only check.
--
-- Usage: tillandsias-plan script run scripts/lua/check-lua-posix-only-absolute.lua [-- <dir>...]
-- Verdict: ok:lua-posix-only-absolute:<n> files | violation:lua-posix-only-absolute:<n>

local DIRS = #arg > 0 and arg or { "scripts/lua", "lib/lua" }
local files = {}
for _, d in ipairs(DIRS) do
    if not fs.exists(d) then
        verdict.emit("refused:lua-posix-only-absolute:no-dir:" .. d, 1,
            "  why: there is nothing there to read, so nothing was checked\n  remedy: pass directories that hold .lua files")
    end
    for _, f in ipairs(fs.walk(d, { suffix = ".lua" })) do files[#files + 1] = f end
end
table.sort(files)
-- This check and its fixture name the shape they refuse; their lines are the rule, not a use.
local SELF = { "check-lua-posix-only-absolute.lua", "test-lua-posix-only-absolute.lua" }
local function is_self(f) for _, s in ipairs(SELF) do if f:sub(-#s) == s then return true end end return false end
local hits = {}
for _, f in ipairs(files) do
    if not is_self(f) then
        local n = 0
        for l in (fs.read(f):gsub("\r", "") .. "\n"):gmatch("([^\n]*)\n") do
            n = n + 1
            local code = l:gsub("%-%-.*$", "")
            if code:find(':sub%(%s*1%s*,%s*1%s*%)%s*~=%s*"/"') and not code:find("%a:", 1, true) then
                hits[#hits + 1] = f .. ":" .. n .. ": " .. text.trim(l)
            end
        end
    end
end
if #hits == 0 then verdict.emit("ok:lua-posix-only-absolute:" .. #files .. " files", 0) end
for _, h in ipairs(hits) do out.line("  " .. h) end
verdict.emit("violation:lua-posix-only-absolute:" .. #hits, 1,
    "  why: a native Windows path is C:/x, and a first-character test reads it as relative (2402-isab)\n"
    .. "  remedy: fixture.is_abs(p), or p:sub(1, 1) == \"/\" or p:find(\"^%a:[/\\\\]\") where common.fixture is not loaded")
