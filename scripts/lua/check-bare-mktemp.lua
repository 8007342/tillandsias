-- @trace order:1619-7i9r
-- @env TILLANDSIAS_BARE_MKTEMP_SCAN_DIR TILLANDSIAS_BARE_MKTEMP_FLOOR
--
-- check-bare-mktemp.lua — refuse a NEW `mktemp` without a template in
-- scripts/**/*.sh, and count the standing ones against a floor that only falls.
--
-- WHY (MEASURED on darwin 27.0.1, 2026-10-11, TMPDIR exported through env(1)):
-- `mktemp`, `mktemp -d`, `mktemp -t x` and `mktemp -d -t x` all made their file
-- in /var/folders/.../T, IGNORING TMPDIR. Only an explicit template,
-- `mktemp "${TMPDIR:-/tmp}/x.XXXXXX"`, landed in TMPDIR. The preflight door gives
-- each guard its own TMPDIR and deletes it after the guard, killed or not
-- (1600-nn5b). On darwin, scratch made without a template is outside that
-- directory and is never swept. GNU mktemp honours TMPDIR, so Linux does not
-- show this.
--
-- A SITE is a `mktemp` in command position: at the start of a line, or after
-- `$(`, `(`, a backtick, `;`, `&&`, `||` or `| `. It is a site when no template
-- argument follows its options. -t and -p take an argument; -t's argument is a
-- prefix, not a template, and it still ignores TMPDIR. Comment lines are not
-- sites, and neither is `command -v mktemp` (or which/type/hash).
--
-- THE FLOOR IS PINNED DATA, PER FILE: scripts/portability/bare-mktemp-floor.txt,
-- `<path> <n>` lines. A file above its floor, or absent from it with a nonzero
-- count, is NEW. A floor ABOVE the count is refused as stale, so a change that
-- converts sites lowers the floor in the same commit. `--dump-floor` prints the
-- floor the tree has now. THE REMEDY a refusal names:
--   mktemp -d "$(scripts/scratch-dir.sh fixtures)/<name>.XXXXXX"
-- (1637-cnxq: the template lives inside the checkout; a host temp template is
-- refused on a new line by check-scratch-location-added.lua.)
--
-- Verdicts:
--   ok:bare-mktemp:sites=<n>:floor=<f>:files=<k>:templated=<t>       exit 0
--   violation:bare-mktemp:new-site:<path>:<n>>floor:<f>               exit 1
--   violation:bare-mktemp:stale-floor:<path>:<n><floor:<f>            exit 1
--   could-not-run:bare-mktemp:empty-population                        exit 3

local SCAN_DIR = env.get("TILLANDSIAS_BARE_MKTEMP_SCAN_DIR") or ""
if SCAN_DIR == "" then SCAN_DIR = "scripts" end
local FLOOR_FILE = env.get("TILLANDSIAS_BARE_MKTEMP_FLOOR") or ""
if FLOOR_FILE == "" then FLOOR_FILE = "scripts/portability/bare-mktemp-floor.txt" end

local function read(p) local ok, s = pcall(fs.read, p); if ok then return s end; return nil end
local function lines(s) local t = {}; for l in ((s or "") .. "\n"):gmatch("(.-)\n") do t[#t + 1] = l end; return t end

local ok_walk, files = pcall(fs.walk, SCAN_DIR, { suffix = ".sh" })
if not ok_walk then files = {} end
table.sort(files)
if #files == 0 then
    verdict.emit("could-not-run:bare-mktemp:empty-population", 3,
        "no " .. SCAN_DIR .. "/**/*.sh was found: nothing was counted, so nothing is vouched for")
end

local LOOKUPS = { command = true, which = true, type = true, hash = true }

-- Is the mktemp at byte i in command position?
local function command_position(l, i)
    local before = l:sub(1, i - 1)
    if before:match("^%s*$") then return true end
    if before:match("%$%($") or before:match("%($") or before:match("`$") then return true end
    if before:match(";%s*$") or before:match("&&%s*$") or before:match("||%s*$") or before:match("[^|]|%s+$") then return true end
    return false
end

-- The words after `mktemp`, up to the end of its command.
local function args_after(rest)
    local words, j = {}, 1
    while true do
        local s = rest:match("^%s*()", j)
        local c = rest:sub(s, s)
        if c == "" or c == ")" or c == ";" or c == "|" or c == "&" or c == "`" or c == ">" or c == "<" then break end
        if rest:sub(s, s + 1):match("^%d>") then break end
        local w, e
        if c == '"' then
            -- a double-quoted word may hold $( ... ) and ${...}; take it to its closing quote
            local depth, k = 0, s + 1
            while k <= #rest do
                local ch = rest:sub(k, k)
                if ch == "\\" then k = k + 1
                elseif ch == "(" then depth = depth + 1
                elseif ch == ")" then depth = depth - 1
                elseif ch == '"' and depth <= 0 then break end
                k = k + 1
            end
            w, e = rest:sub(s, k), k + 1
        elseif c == "'" then
            local k = rest:find("'", s + 1, true) or #rest
            w, e = rest:sub(s, k), k + 1
        else
            local k = rest:find("[%s);|&`<>]", s) or (#rest + 1)
            w, e = rest:sub(s, k - 1), k
        end
        words[#words + 1] = w
        j = e
    end
    return words
end

-- "bare", "templated", or nil (not a call)
local function judge(l, i)
    if not command_position(l, i) then return nil end
    local prev = l:sub(1, i - 1):match("(%S+)%s+$")
    if prev and LOOKUPS[prev] then return nil end
    local after = l:sub(i + 6)
    if after:match("^[%w_%-]") then return nil end -- mktemp-something, a longer word
    local words = args_after(after)
    local k = 1
    while words[k] and words[k]:sub(1, 1) == "-" do
        local o = words[k]
        if o:match("^%-[%a]*[tp]$") then k = k + 1 end -- -t/-p take an argument
        k = k + 1
    end
    if words[k] then return "templated" end
    return "bare"
end

-- ── counting ───────────────────────────────────────────────────────────────
local count, templated, where = {}, 0, {}
for _, f in ipairs(files) do
    for ln, l in ipairs(lines(read(f))) do
        if not l:match("^%s*#") then
            local start = 1
            while true do
                local i = l:find("mktemp", start, true)
                if not i then break end
                local prevc = i > 1 and l:sub(i - 1, i - 1) or ""
                if not prevc:match("[%w_%-/.]") then
                    local v = judge(l, i)
                    if v == "bare" then
                        count[f] = (count[f] or 0) + 1
                        where[f] = where[f] or {}
                        where[f][#where[f] + 1] = f .. ":" .. ln .. ": " .. text.trim(l)
                    elseif v == "templated" then templated = templated + 1 end
                end
                start = i + 6
            end
        end
    end
end

local total, site_files = 0, {}
for f, n in pairs(count) do total = total + n; site_files[#site_files + 1] = f end
table.sort(site_files)

if arg[1] == "--dump-floor" then
    out.line("# Per-file mktemp sites WITHOUT a template in scripts/**/*.sh (1619-7i9r). On darwin")
    out.line("# they ignore TMPDIR, so the preflight door's per-guard TMPDIR sweep never sees them.")
    out.line("# May only DESCEND: give the site a template inside the checkout, mktemp \"$(scripts/scratch-dir.sh logs)/<name>.XXXXXX\" (1637-cnxq), and lower its line.")
    for _, f in ipairs(site_files) do out.line(f .. " " .. count[f]) end
    verdict.ok("bare-mktemp-floor-dumped", tostring(#site_files))
end

-- ── judging against the floor ──────────────────────────────────────────────
local floor, floor_total = {}, 0
for _, l in ipairs(lines(read(FLOOR_FILE))) do
    local f, n = l:match("^%s*(%S+)%s+(%d+)%s*$")
    if f and not f:find("^#") then floor[f] = tonumber(n); floor_total = floor_total + tonumber(n) end
end

-- A peer this bounces must be able to fix it without asking: the refusal names
-- the darwin reason, the exact remedy and the file's bare sites, on stdout.
local WHY = "  why: on darwin a mktemp without a template ignores TMPDIR (measured: /var/folders/.../T), so the preflight door's per-guard TMPDIR sweep never sees it (1619-7i9r)"
local REMEDY = '  remedy: give the call a template inside the checkout, e.g. mktemp -d "$(scripts/scratch-dir.sh fixtures)/<name>.XXXXXX" (a file: mktemp "$(scripts/scratch-dir.sh logs)/<name>.XXXXXX"); a host temp template is refused on a new line by check-scratch-location-added.lua (1637-cnxq)'
local violations, detail = {}, {}
for _, f in ipairs(site_files) do
    local n, fl = count[f], floor[f] or 0
    if n > fl then
        local v = "violation:bare-mktemp:new-site:" .. f .. ":" .. n .. ">floor:" .. fl
        violations[#violations + 1] = v
        local d = { WHY, REMEDY }
        for _, w in ipairs(where[f]) do d[#d + 1] = "  site: " .. w end
        detail[v] = d
    end
end
local floor_files = {}
for f, _ in pairs(floor) do floor_files[#floor_files + 1] = f end
table.sort(floor_files)
for _, f in ipairs(floor_files) do
    local n = count[f] or 0
    if n < floor[f] then
        violations[#violations + 1] = "violation:bare-mktemp:stale-floor:" .. f .. ":" .. n .. "<floor:" .. floor[f]
    end
end

if #violations > 0 then
    for i = 1, #violations - 1 do
        out.line(violations[i])
        for _, d in ipairs(detail[violations[i]] or {}) do out.line(d) end
    end
    local last = violations[#violations]
    if detail[last] then
        -- the verdict line stays last, so its detail goes before it
        for _, d in ipairs(detail[last]) do out.line(d) end
    end
    log.raw("[check-bare-mktemp] on darwin a mktemp without a template ignores TMPDIR, so the preflight door's")
    log.raw("  per-guard TMPDIR (deleted after every guard, killed or not) never contains it. Give it a template:")
    log.raw("  mktemp -d \"$(scripts/scratch-dir.sh fixtures)/<name>.XXXXXX\"   (1619-7i9r, 1637-cnxq)")
    log.raw("  A stale-floor line means sites were converted: lower " .. FLOOR_FILE .. " (--dump-floor prints it).")
    verdict.emit(violations[#violations], 1)
end

verdict.ok("bare-mktemp", "sites=" .. total, "floor=" .. floor_total, "files=" .. #site_files,
    "templated=" .. templated)
