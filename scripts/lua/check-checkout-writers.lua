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
-- Paths under target/ or .tillandsias/ are gitignored, so a leftover there is
-- invisible to diff-scoped guards. They are counted as ignored, not as writers.
-- (target/ can be a symlink out of the repo, so a fixture whose Lua subject is
-- repo-confined uses .tillandsias/fixture-scratch/.)
--
-- A writer that must stay in the tracked tree, because the copy resolves its
-- siblings or ROOT from its own path, is DECLARED in
-- scripts/portability/checkout-writers.txt (`<path> <reason>`). It must also
-- have 1587-qqzs's shape:
--   1 an EXIT trap,
--   2 a TERM trap that EXITS, directly or through a handler function that does,
--   3 and `wait`, so long steps run as `cmd & wait $!` (bash defers a trap until
--     a FOREGROUND command returns, which would leave the KILL nothing to lose).
-- A declared line whose file is gone, or no longer writes, is refused as stale.
--
-- Verdicts:
--   note:checkout-writer:<path>:kept-in-checkout:<reason>                    one per writer
--   ok:checkout-writers:scanned=<n>:writers=<w>:unsafe=0:ignored-scratch=<i> exit 0
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

local declared = {}
for _, l in ipairs(lines(read(DECLARED))) do
    local f, why = l:match("^%s*(%S+)%s+(%S.*)$")
    if f and not f:find("^#") then declared[f] = why end
end

local ROOT_VARS = { "$ROOT/", "${ROOT}/", "$REPO_ROOT/", "${REPO_ROOT}/", "$PROJECT_ROOT/", "${PROJECT_ROOT}/" }
local IGNORED = { "target/", ".tillandsias/" }

-- What a line writes, if anything: "writer", "ignored", or nil.
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
                if ign then found = found or "ignored" else return "writer" end
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

local writers, ignored_n, violations, notes, seen = 0, 0, {}, {}, {}
for _, f in ipairs(files) do
    local ls = lines(read(f))
    local writes, ignored = false, false
    local exit_trap, term_exit, waits = false, false, false
    for _, l in ipairs(ls) do
        if not l:match("^%s*#") then
            local c = classify(l)
            if c == "writer" then writes = true elseif c == "ignored" then ignored = true end
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
    if ignored and not writes then ignored_n = ignored_n + 1 end
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
local dpaths = {}
for f in pairs(declared) do dpaths[#dpaths + 1] = f end
table.sort(dpaths)
for _, f in ipairs(dpaths) do
    if not seen[f] then violations[#violations + 1] = "violation:checkout-writers:stale-declared:" .. f end
end

for _, n in ipairs(notes) do out.line(n) end
if #violations > 0 then
    for i = 1, #violations - 1 do out.line(violations[i]) end
    log.raw("[check-checkout-writers] scratch belongs in ${TMPDIR:-/tmp}: the preflight door deletes each guard's TMPDIR")
    log.raw("  even after a KILL (1600-nn5b). A Lua subject confined to the repo: .tillandsias/fixture-scratch/.")
    log.raw("  A copy that must sit beside a script: declare it in " .. DECLARED .. " with its reason, and give it")
    log.raw("  1587-qqzs's shape: trap cleanup EXIT; a TERM/INT/HUP handler that exits; long steps as `cmd & wait $!`.")
    verdict.emit(violations[#violations], 1)
end
verdict.ok("checkout-writers", "scanned=" .. #files, "writers=" .. writers, "unsafe=0",
    "ignored-scratch=" .. ignored_n)
