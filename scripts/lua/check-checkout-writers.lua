-- @trace order:1611-imnj
-- @env TILLANDSIAS_CHECKOUT_WRITERS_SCAN_DIR TILLANDSIAS_CHECKOUT_WRITERS_DECLARED
--
-- check-checkout-writers.lua — a script under scripts/ that makes SCRATCH files
-- inside the checkout's tracked tree, instead of ${TMPDIR:-/tmp}, must be able
-- to clean them up on the preflight door's TERM, 1 s, KILL.
--
-- WHY. The door KILLs a guard that outlives its deadline, and no trap survives
-- a KILL. A scratch file left in scripts/ or at the root is untracked code to
-- every diff-scoped guard that runs after it. OBSERVED on darwin 2026-10-11:
-- test-litmus-step-pipefail, deadline-skipped, left
-- scripts/.wka4-prefix-runner.<pid>.sh. Since 1600-nn5b the door gives each
-- guard its own TMPDIR and deletes it after the guard, killed or not, so a file
-- under ${TMPDIR:-/tmp} is cleaned up for free.
--
-- A WRITER is a non-comment line that builds a path under a checkout-root
-- variable ($ROOT, $REPO_ROOT, $PROJECT_ROOT, braced or not) and marks it as
-- scratch: the line runs mktemp on it, or the path carries $$ or XXXX. A copy
-- made beside a script (a `.mutant` path built from `dirname`) is one too.
-- Paths under target/ are gitignored, so a leftover there is invisible to
-- diff-scoped guards: counted as ignored-scratch, not as writers.
-- .tillandsias/fixture-scratch/ is the third safe kind (coordinator's ruling,
-- 2026-10-11), for a fixture whose Lua subject is repo-confined (target/ can be
-- a symlink out of the repo). It is gitignored and inside the repo, but safe
-- ONLY per run: .tillandsias/fixture-scratch/<guard>.$$ (a $$-named subdir the
-- door can find by the guard's pid), in a file with an EXIT trap that removes
-- it. A flat name directly in fixture-scratch/, or anywhere else under
-- .tillandsias/, is a writer.
--
-- A writer that must stay in the tracked tree, because the copy resolves its
-- siblings or ROOT from its own path, is DECLARED in
-- scripts/portability/checkout-writers.txt (`<path> [artifacts=<basename-glob>] <reason>`;
-- the glob is what the preflight door sweeps when it KILLs the writer, 1630-dwab). It must also
-- have 1587-qqzs's shape:
--   1 an EXIT trap,
--   2 a TERM trap that EXITS, directly or through a handler function that does,
--   3 and `wait`, so long steps run as `cmd & wait $!` (bash defers a trap until
--     a FOREGROUND command returns, which would leave the KILL nothing to lose).
-- A declared line whose file is gone, or no longer writes, is refused as stale.
--
-- Verdicts:
--   note:checkout-writer:<path>:kept-in-checkout:<reason>                    one per writer
--   ok:checkout-writers:scanned=<sh>:lua=<n>:writers=<w>:unsafe=0:ignored-scratch=<i>:fixture-scratch=<f>:lua-unresolved=<u> exit 0
--   violation:checkout-writers:unsafe:<path>:lua-fixture-writes-the-checkout-move-it-to-scratch   exit 1
--   violation:checkout-writers:unsafe:<path>:lua-writer-declared-without-artifacts   exit 1
--   violation:checkout-writers:unsafe:<path>:fixture-scratch-without-exit-trap    exit 1
--   violation:checkout-writers:unsafe:<path>:<why>                           exit 1
--   violation:checkout-writers:stale-declared:<path>                         exit 1
--   could-not-run:checkout-writers:empty-population                          exit 3

local SCAN_DIR = env.get("TILLANDSIAS_CHECKOUT_WRITERS_SCAN_DIR") or "scripts"
if SCAN_DIR == "" then SCAN_DIR = "scripts" end
local DECLARED = env.get("TILLANDSIAS_CHECKOUT_WRITERS_DECLARED") or "scripts/portability/checkout-writers.txt"
if DECLARED == "" then DECLARED = "scripts/portability/checkout-writers.txt" end

local function read(p) local ok, s = pcall(fs.read, p); if ok then return s end; return nil end
local function lines(s) local t = {}; for l in ((s or "") .. "\n"):gmatch("(.-)\n") do t[#t + 1] = l end; return t end

local ok_walk, files = pcall(fs.walk, SCAN_DIR, { suffix = ".sh" })
if not ok_walk or #files == 0 then
    verdict.emit("could-not-run:checkout-writers:empty-population", 3,
        "no " .. SCAN_DIR .. "/**/*.sh was found: nothing was counted, so nothing is vouched for")
end
table.sort(files)

local declared, swept = {}, {}
for _, l in ipairs(lines(read(DECLARED))) do
    local f, why = l:match("^%s*(%S+)%s+(%S.*)$")
    -- 1630-dwab: an optional `artifacts=<basename-glob>` token names what the
    -- writer leaves, for the preflight door to sweep when it KILLs the writer.
    if why and f and why:find("^artifacts=%S") then swept[f] = true end
    if why then why = why:gsub("^artifacts=%S+%s*", "") end
    if f and not f:find("^#") and why ~= "" then declared[f] = why end
end

local ROOT_VARS = { "$ROOT/", "${ROOT}/", "$REPO_ROOT/", "${REPO_ROOT}/", "$PROJECT_ROOT/", "${PROJECT_ROOT}/" }
local IGNORED = { "target/" }

-- Where under .tillandsias/ a scratch path is safe: one $$-named subdir of
-- fixture-scratch/, or a path inside it.
local function per_run(path)
    local rest = path:match("^%.tillandsias/fixture%-scratch/([^/]+)")
    return rest ~= nil and rest:sub(-2) == "$$" and #rest > 2
end

-- What a line writes, if anything: "writer", "fixture-scratch", "ignored", or nil.
local function classify(l)
    local found
    for _, v in ipairs(ROOT_VARS) do
        local from = 1
        while true do
            local s, e = l:find(v, from, true)
            if not s then break end
            local rest = l:sub(e + 1)
            local path = rest:match("^[^\"%s']*") or ""
            local scratch = path:find("$$", 1, true) or path:find("XXXX", 1, true)
                or l:sub(1, s):find("mktemp", 1, true)
            if scratch then
                local ign = false
                for _, p in ipairs(IGNORED) do if path:sub(1, #p) == p then ign = true end end
                if per_run(path) then found = "fixture-scratch"
                elseif ign then found = found or "ignored"
                else return "writer" end
            end
            from = e + 1
        end
    end
    if l:find("dirname", 1, true) and l:find("/.mutant", 1, true) then return "writer" end
    return found
end

-- A trap action EXITS when it says exit, or calls a function whose body does.
local function exits(action, ls)
    if action:find("exit") then return true end
    local fn = action:gsub("^['\"]", ""):match("^([%w_]+)")
    if not fn then return false end
    for i, l in ipairs(ls) do
        if l:match("^%s*" .. fn .. "%s*%(%)") then
            for j = i, math.min(i + 20, #ls) do
                if ls[j]:find("%f[%w]exit%f[%W]") then return true end
                if j > i and ls[j]:match("^}") then break end
            end
        end
    end
    return false
end

local writers, ignored_n, fs_n, violations, notes, seen = 0, 0, 0, {}, {}, {}
for _, f in ipairs(files) do
    local ls = lines(read(f))
    local writes, ignored, fscratch = false, false, false
    local exit_trap, term_exit, waits = false, false, false
    for _, l in ipairs(ls) do
        if not l:match("^%s*#") then
            local c = classify(l)
            if c == "writer" then writes = true
            elseif c == "fixture-scratch" then fscratch = true
            elseif c == "ignored" then ignored = true end
            for act, sg in l:gmatch("trap%s+('[^']*')%s+([%u]+)") do
                if sg == "EXIT" then exit_trap = true end
                if sg == "TERM" and exits(act, ls) then term_exit = true end
            end
            for act, sigs in l:gmatch("trap%s+([%w_]+)%s+([%u ]+)") do
                if sigs:find("%f[%u]EXIT%f[^%u]") then exit_trap = true end
                if sigs:find("%f[%u]TERM%f[^%u]") and exits(act, ls) then term_exit = true end
            end
            if l:find("%f[%w]wait%s+[\"$]") then waits = true end
        end
    end
    if ignored and not writes and not fscratch then ignored_n = ignored_n + 1 end
    if fscratch and not writes then
        fs_n = fs_n + 1
        if not exit_trap then
            violations[#violations + 1] = "violation:checkout-writers:unsafe:" .. f .. ":fixture-scratch-without-exit-trap"
        end
    end
    if writes then
        writers = writers + 1
        seen[f] = true
        local why
        if not declared[f] then why = "scratch-in-the-checkout-move-it-to-TMPDIR-or-declare-it"
        elseif not exit_trap then why = "no-exit-trap"
        elseif not term_exit then why = "no-term-trap-that-exits"
        elseif not waits then why = "no-wait-so-long-steps-defer-the-trap" end
        if why then
            violations[#violations + 1] = "violation:checkout-writers:unsafe:" .. f .. ":" .. why
        else
            notes[#notes + 1] = "note:checkout-writer:" .. f .. ":kept-in-checkout:" .. declared[f]
        end
    end
end
-- ── ORDER 2287-mg7v: THE LUA POPULATION ────────────────────────────────────
-- Until 2026-11-24 only .sh was walked, so the scan said writers=0 while three Lua
-- fixtures wrote scripts into the live checkout (#1464 was evicted twice on one).
-- Every fs.write( in a test-*.lua is judged by the PREFIX of its path: a literal, or
-- a local followed through its assignments. target/ and .tillandsias/fixture-scratch/<x> are safe; a kit
-- scratch dir (`X.rel`) is safe, because common.fixture roots it under target/; any
-- other repo-relative literal is a WRITER. A prefix that cannot be followed (a function
-- parameter, a call) is UNRESOLVED: counted, never read as safe, not refused.
-- Lua runs no trap, so a Lua writer cannot have 1587-qqzs's shape. It may stay only when
-- DECLARED with an artifacts= glob, which is what the door sweeps when it KILLs the writer.
local function lua_assigns(src)
    local a = {}
    for name, expr in ("\n" .. src):gmatch("\n%s*local%s+([%a_][%w_]*)%s*=%s*([^\n]*)") do
        a[name] = a[name] or {}; a[name][#a[name] + 1] = expr
    end
    for name, expr in ("\n" .. src):gmatch("\n%s*([%a_][%w_]*)%s*=%s*([^\n=][^\n]*)") do
        a[name] = a[name] or {}; a[name][#a[name] + 1] = expr
    end
    return a
end
local function lua_prefix(expr, assigns, depth)
    expr = (expr or ""):gsub("^%s+", ""):gsub("^%(", "")
    if depth > 6 then return "unresolved" end
    local lit = expr:match('^"([^"]*)') or expr:match("^'([^']*)")
    if lit then
        if lit:find("^target/") or lit:find("^%.tillandsias/fixture%-scratch/[^/]") then return "safe" end
        if lit == "" then return "unresolved" end
        return "writer"
    end
    if expr:match("^[%a_][%w_]*%.rel%f[^%w_]") then return "safe" end
    local name, after = expr:match("^([%a_][%w_]*)(.?)")
    if not name or after == "(" or after == ":" or after == "." or after == "[" then
        -- `name .. x` has a space or a dot pair after it; a field or a call does not resolve
        if not (name and expr:match("^[%a_][%w_]*%s*%.%.")) then return "unresolved" end
    end
    local got = "unresolved"
    for _, e in ipairs(assigns[name] or {}) do
        local r = lua_prefix(e, assigns, depth + 1)
        if r == "writer" then return "writer" end
        if r == "safe" then got = "safe" end
    end
    return got
end
local lua_n, lua_unresolved, unres = 0, 0, {}
local ok_lua, lua_files = pcall(fs.walk, SCAN_DIR, { suffix = ".lua" })
for _, f in ipairs(ok_lua and lua_files or {}) do
    if f:match("[^/]*$"):find("^test%-") then
        lua_n = lua_n + 1
        local src, unresolved, writes = {}, false, false
        for _, l in ipairs(lines(read(f))) do if not l:match("^%s*%-%-") then src[#src + 1] = l end end
        -- an embedded shell or YAML text is data: its `d=...` is not a Lua assignment
        local body = table.concat(src, "\n"):gsub("%[(=*)%[.-%]%1%]", "[[]]")
        local assigns = lua_assigns(body)
        for arg1 in body:gmatch("%f[%w_]fs%.write%(([^\n]*)") do
            local r = lua_prefix(arg1, assigns, 0)
            if r == "writer" then writes = true elseif r == "unresolved" then unresolved = true end
        end
        if writes then
            writers = writers + 1
            seen[f] = true
            if declared[f] and swept[f] then
                notes[#notes + 1] = "note:checkout-writer:" .. f .. ":kept-in-checkout:" .. declared[f]
            else
                violations[#violations + 1] = "violation:checkout-writers:unsafe:" .. f .. (declared[f]
                    and ":lua-writer-declared-without-artifacts" or ":lua-fixture-writes-the-checkout-move-it-to-scratch")
            end
        elseif unresolved then lua_unresolved = lua_unresolved + 1; unres[#unres + 1] = f:match("[^/]*$") end
    end
end
local dpaths = {}
for f in pairs(declared) do dpaths[#dpaths + 1] = f end
table.sort(dpaths)
for _, f in ipairs(dpaths) do
    if not seen[f] then violations[#violations + 1] = "violation:checkout-writers:stale-declared:" .. f end
end

for _, n in ipairs(notes) do out.line(n) end
if #unres > 0 then out.line("note:checkout-writers:lua-unresolved:" .. table.concat(unres, " ")) end
if #violations > 0 then
    for i = 1, #violations - 1 do out.line(violations[i]) end
    log.raw("[check-checkout-writers] scratch belongs in ${TMPDIR:-/tmp}: the preflight door deletes each guard's TMPDIR")
    log.raw("  even after a KILL (1600-nn5b). A Lua subject confined to the repo: .tillandsias/fixture-scratch/<guard>.$$")
    log.raw("  with an EXIT trap that removes it (never a flat name directly in fixture-scratch/).")
    log.raw("  A copy that must sit beside a script: declare it in " .. DECLARED .. " with its reason, and give it")
    log.raw("  1587-qqzs's shape: trap cleanup EXIT; a TERM/INT/HUP handler that exits; long steps as `cmd & wait $!`.")
    verdict.emit(violations[#violations], 1)
end
verdict.ok("checkout-writers", "scanned=" .. #files, "lua=" .. lua_n, "writers=" .. writers, "unsafe=0",
    "ignored-scratch=" .. ignored_n, "fixture-scratch=" .. fs_n, "lua-unresolved=" .. lua_unresolved)
