-- @trace order:1600-nn5b
--
-- check-worktree-add-cleanup.lua — a fixture that `git worktree add`s into THIS
-- checkout must remove the worktree on every way it can end.
--
-- WHY. A worktree registered in this checkout's .git shares its refs and its
-- CARGO_TARGET_DIR with every other checkout (1590-j20f, 1599-egzz), and shows
-- in `git worktree list` until someone removes it. MEASURED on darwin
-- 2026-10-11: after deadline-killed preflights, closure-guards.*/wt (x5) and
-- scorable-quoting.*/wt (x2) were left registered under $TMPDIR.
--
-- THE RULE, per file that adds to the REAL checkout (an add with no `-C`, or
-- `-C "$ROOT"` / `-C "$REPO_ROOT"`; an add into a scratch repo the fixture made
-- is not this checkout's business). BEFORE its first such add, the file:
--   1 registers an EXIT trap,
--   2 registers a TERM trap whose action EXITS (so the EXIT trap runs; a TERM
--     handler that only cleans up returns and lets the script carry on), and
--   3 somewhere runs `git ... worktree remove`, not only rm -rf, which leaves
--     the registration in .git/worktrees.
-- A KILL that lands while bash waits on a long step defeats any trap. That case
-- is the preflight door's: it gives each guard its own TMPDIR and sweeps the
-- worktrees registered under it (build.sh _pf_sweep_guard_tmp).
--
-- EXEMPTIONS are data with a reason, never a guess about quoting:
-- scripts/portability/worktree-add-scan-exempt.txt, `<path> <reason...>`. A
-- line whose file is gone, or no longer adds anything, is refused as stale.
--
-- Verdicts:
--   ok:worktree-add-cleanup:scanned=<sh>:adders=<a>:real=<r>:unguarded=0:exempt=<e>  exit 0
--   violation:worktree-add-cleanup:unguarded:<path>:<why>                             exit 1
--   violation:worktree-add-cleanup:stale-exempt:<path>                                exit 1
--   could-not-run:worktree-add-cleanup:empty-population                               exit 3

local EXEMPT_FILE = "scripts/portability/worktree-add-scan-exempt.txt"

local function read(p) local ok, s = pcall(fs.read, p); if ok then return s end; return nil end
local function lines(s) local t = {}; for l in ((s or "") .. "\n"):gmatch("(.-)\n") do t[#t + 1] = l end; return t end

local ok_walk, files = pcall(fs.walk, "scripts", { suffix = ".sh" })
if not ok_walk or #files == 0 then
    verdict.emit("could-not-run:worktree-add-cleanup:empty-population", 3,
        "no scripts/**/*.sh was found: nothing was counted, so nothing is vouched for")
end
table.sort(files)

local exempt = {}
for _, l in ipairs(lines(read(EXEMPT_FILE))) do
    local f, why = l:match("^%s*(%S+)%s+(%S.*)$")
    if f and not f:find("^#") then exempt[f] = why end
end

local REAL_C = { ['"$ROOT"'] = true, ["$ROOT"] = true, ['"$REPO_ROOT"'] = true, ["$REPO_ROOT"] = true }

-- Where the line's git runs: nil (cwd, i.e. the checkout) or the -C argument.
local function c_target(l)
    local before = l:match("^(.-)worktree%s+add")
    if not before then return nil end
    return before:match("%-C%s+(\"[^\"]*\")") or before:match("%-C%s+(%S+)")
end

local adders, real_n, exempt_n, violations = 0, 0, 0, {}
local seen_add = {}
for _, f in ipairs(files) do
    local ls = lines(read(f))
    local first_real, any_add = nil, false
    local exit_trap, term_exit, remove = nil, nil, false
    for i, l in ipairs(ls) do
        if not l:match("^%s*#") then
            if l:find("worktree%s+add") then
                any_add = true
                local c = c_target(l)
                if (c == nil or REAL_C[c]) and not first_real then first_real = i end
            end
            if l:find("worktree%s+remove") then remove = true end
            local action, sigs = l:match("^%s*trap%s+(.-)%s+([%u%s]+)%s*;?%s*$")
            if not action then action, sigs = l:match("trap%s+(.-)%s+([%u%s]+)%s*;") end
            if action and sigs then
                if sigs:find("%f[%u]EXIT%f[^%u]") and not exit_trap then exit_trap = i end
                if sigs:find("%f[%u]TERM%f[^%u]") and action:find("exit") and not term_exit then term_exit = i end
            end
            -- a line with several `trap ...;` commands: check each one
            for act, sg in l:gmatch("trap%s+('[^']*')%s+([%u]+)") do
                if sg == "TERM" and act:find("exit") and not term_exit then term_exit = i end
                if sg == "EXIT" and not exit_trap then exit_trap = i end
            end
        end
    end
    if any_add then
        adders = adders + 1
        seen_add[f] = true
    end
    if exempt[f] then
        exempt_n = exempt_n + 1
    elseif first_real then
        real_n = real_n + 1
        local why
        if not exit_trap or exit_trap > first_real then why = "no-exit-trap-before-the-add"
        elseif not term_exit or term_exit > first_real then why = "no-term-trap-that-exits-before-the-add"
        elseif not remove then why = "cleanup-never-runs-worktree-remove" end
        if why then violations[#violations + 1] = "violation:worktree-add-cleanup:unguarded:" .. f .. ":" .. why end
    end
end
local ex_paths = {}
for f in pairs(exempt) do ex_paths[#ex_paths + 1] = f end
table.sort(ex_paths)
for _, f in ipairs(ex_paths) do
    if not seen_add[f] then violations[#violations + 1] = "violation:worktree-add-cleanup:stale-exempt:" .. f end
end

if #violations > 0 then
    for i = 1, #violations - 1 do out.line(violations[i]) end
    log.raw("[check-worktree-add-cleanup] a fixture that adds a worktree to this checkout must, BEFORE the add:")
    log.raw("  trap cleanup EXIT; trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP")
    log.raw("  with cleanup running `git -C \"$ROOT\" worktree remove --force \"$wt\"` (1600-nn5b).")
    log.raw("  An add that is not executed (data in a string) goes in " .. EXEMPT_FILE .. " with its reason.")
    verdict.emit(violations[#violations], 1)
end
verdict.ok("worktree-add-cleanup", "scanned=" .. #files, "adders=" .. adders, "real=" .. real_n,
    "unguarded=0", "exempt=" .. exempt_n)
