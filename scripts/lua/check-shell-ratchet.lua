-- @trace order:1384-bxhk
--
-- check-shell-ratchet.lua — the Lua migration's forcing function and its score.
--
-- WHY. An available seam with no forcing function stays at one adopter
-- (902-5bf9: rust_queries, 1 of 458 litmus files four months after it landed).
-- This guard prints the migration's counts on every --check and refuses the
-- three things that would grow the shell corpus back:
--   1 a NEW .sh decider under scripts/ (check-/test-/verify-/guard-); the
--     remedy is scripts/lua/<name>.lua on `tillandsias-plan script run`
--   2 a NEW pipe site in a script, beyond that file's floor (standing debt is
--     never reddened, 1130-i6xj)
--   3 a NEW litmus `command:` with a pipe outside quotes, beyond that file's
--     floor, once the runner's `steps:` form exists (dormant before)
-- and (4) its floors only DESCEND, judged over each floor file's OWN git
-- history, never against a moving ref (a fixture must not encode a moment).
--
-- THE FLOORS ARE PINNED DATA, PER FILE, in scripts/portability/:
--   shell-decider-floor.txt   one path per line: the .sh deciders allowed to exist
--   pipe-site-floor.txt       `scripts <path> <n>` and `litmus <path> <n>` lines
-- A file above its floor, or absent from it with a nonzero count, is NEW.
--
-- POPULATIONS (design §2/§6.3), excluded by path: the bootstrap/installer
-- shell in scripts/portability/bootstrap-shell-allowlist.txt (§6.5), which
-- stays shell by design and is never refused here. images/ is not counted until
-- the image ships the binary.
--   deciders   scripts/<check-|test-|verify-|guard->*.sh, top level (maxdepth 1)
--   pipes      every scripts/**/*.sh, per line: quoted spans and comments
--              stripped, `||` removed, then each `|` is one site
--   litmus     openspec/litmus-tests/*.yaml `command:` values, outer YAML
--              quote kept off, nested quotes stripped, same counting
--
-- Verdicts:
--   ok:shell-ratchet:sh=<n>:floor:<f> pipes=<p>:floor:<pf> litmus-form:command=<c>:steps=<s>:rust_queries=<r> gate-steps:sh=<a>:lua=<b> shell-strings=<k>   exit 0
--   violation:shell-ratchet:new-decider:<path>            exit 1
--   violation:shell-ratchet:new-pipes:<path>:<n>>floor:<f> exit 1
--   violation:shell-ratchet:new-piped-command:<path>      exit 1
--   violation:shell-ratchet:floor-raised:<file>:<key>     exit 1
--   could-not-run:shell-ratchet:empty-population          exit 3
local function err(s) log.raw(s) end
local function read(p) local ok, s = pcall(fs.read, p); if ok then return s end; return nil end
local function lines(s) local t = {}; for l in ((s or "") .. "\n"):gmatch("(.-)\n") do t[#t + 1] = l end; return t end
local function base(p) return p:match("([^/]+)$") end

-- ── populations ────────────────────────────────────────────────────────────
local boot = {}
for _, l in ipairs(lines(read("scripts/portability/bootstrap-shell-allowlist.txt"))) do
    local f = l:match("^%s*(%S+)"); if f and not f:find("^#") then boot[f] = true end
end

local scripts_sh = {}
for _, f in ipairs(fs.walk("scripts", { suffix = ".sh" })) do
    if not boot[f] then scripts_sh[#scripts_sh + 1] = f end
end
local deciders = {}
for _, f in ipairs(scripts_sh) do
    local rel = f:sub(#"scripts/" + 1)
    if not rel:find("/") and (rel:find("^check%-") or rel:find("^test%-") or rel:find("^verify%-") or rel:find("^guard%-")) then
        deciders[#deciders + 1] = f
    end
end
local litmus_files = fs.walk("openspec/litmus-tests", { suffix = ".yaml" })

if #scripts_sh == 0 or #litmus_files == 0 then
    err("[check-shell-ratchet] the scan population is empty (scripts/**/*.sh or openspec/litmus-tests/*.yaml): nothing was counted, so nothing is vouched for")
    verdict.emit("could-not-run:shell-ratchet:empty-population", 3)
end

-- ── counting ───────────────────────────────────────────────────────────────
local function strip_quoted(l)
    l = l:gsub("'[^']*'", "''")
    l = l:gsub('"[^"]*"', '""')
    return l
end
local function pipe_sites(line)
    local l = strip_quoted(line)
    if l:find("^%s*#") then return 0 end
    l = l:gsub("%s#.*$", "")
    l = l:gsub("||", "")
    local _, n = l:gsub("|", "")
    return n
end
local script_pipes, total_pipes = {}, 0
for _, f in ipairs(scripts_sh) do
    local n = 0
    for _, l in ipairs(lines(read(f))) do n = n + pipe_sites(l) end
    if n > 0 then script_pipes[f] = n end
    total_pipes = total_pipes + n
end

local litmus_piped, n_commands, n_steps, n_rq = {}, 0, 0, 0
for _, f in ipairs(litmus_files) do
    local src = read(f) or ""
    if text.is_match(src, [[(?m)^steps:]]) then n_steps = n_steps + 1 end
    if text.is_match(src, [[(?m)^rust_queries:]]) then n_rq = n_rq + 1 end
    local piped = 0
    for _, l in ipairs(lines(src)) do
        local v = l:match("^%s*%-?%s*command:%s*(.*)$")
        if v then
            n_commands = n_commands + 1
            local inner = v:match('^"(.*)"%s*$') or v:match("^'(.*)'%s*$") or v
            inner = inner:gsub('\\"', '"')
            if pipe_sites(inner) > 0 then piped = piped + 1 end
        end
    end
    if piped > 0 then litmus_piped[f] = piped end
end

local gs_sh, gs_lua = 0, 0
for _, f in ipairs(fs.walk("scripts/gate-steps.d", { suffix = ".step" })) do
    local s = read(f) or ""
    if text.is_match(s, [[(?m)^STEP_LUA=]]) then gs_lua = gs_lua + 1 elseif text.is_match(s, [[(?m)^STEP_SCRIPT=]]) then gs_sh = gs_sh + 1 end
end
local shell_strings = 0
for _, f in ipairs(fs.walk("scripts/lua", { suffix = ".lua" })) do
    shell_strings = shell_strings + text.count_lines(read(f) or "", [[allow_shell_strings\s*=\s*true]])
end

-- `script run check-shell-ratchet.lua --dump-floors`: the floor files' content
-- for THIS tree, from the same counting code that enforces them, so a floor is
-- never hand-assembled. Used once to seed, and by a migration commit to lower.
if arg[1] == "--dump-floors" then
    out.line("# === " .. "scripts/portability/shell-decider-floor.txt")
    out.line("# The .sh deciders allowed to exist (1384-bxhk). May only SHRINK.")
    table.sort(deciders)
    for _, f in ipairs(deciders) do out.line(f) end
    out.line("# === " .. "scripts/portability/pipe-site-floor.txt")
    out.line("# Per-file pipe sites (scripts) and piped litmus commands (1384-bxhk). May only DESCEND.")
    local ks = {}
    for f, n in pairs(script_pipes) do ks[#ks + 1] = ("scripts %s %d"):format(f, n) end
    for f, n in pairs(litmus_piped) do ks[#ks + 1] = ("litmus %s %d"):format(f, n) end
    table.sort(ks)
    for _, l in ipairs(ks) do out.line(l) end
    verdict.ok("shell-ratchet-floors-dumped", #deciders, #ks)
end

-- ── floors ─────────────────────────────────────────────────────────────────
local DFLOOR, PFLOOR = "scripts/portability/shell-decider-floor.txt", "scripts/portability/pipe-site-floor.txt"
local function parse_decider_floor(s) local t, n = {}, 0; for _, l in ipairs(lines(s)) do local p = l:match("^%s*([^#%s]%S*)"); if p then t[p] = true; n = n + 1 end end; return t, n end
local function parse_pipe_floor(s)
    local t = {}
    for _, l in ipairs(lines(s)) do
        local kind, p, n = l:match("^%s*(%a+)%s+(%S+)%s+(%d+)")
        if kind then t[kind .. " " .. p] = tonumber(n) end
    end
    return t
end
local dsrc, psrc = read(DFLOOR), read(PFLOOR)
if not dsrc or not psrc then
    err("[check-shell-ratchet] a floor file is missing (" .. DFLOOR .. ", " .. PFLOOR .. "): with no floor nothing can be judged new")
    verdict.emit("could-not-run:shell-ratchet:no-floor", 3)
end
local dfloor, dfloor_n = parse_decider_floor(dsrc)
local pfloor = parse_pipe_floor(psrc)
local pfloor_total = 0
for k, n in pairs(pfloor) do if k:find("^scripts ") then pfloor_total = pfloor_total + n end end

local violations = {}
local function v(line, detail) violations[#violations + 1] = line; if detail then err(detail) end end
-- SCOPE (coordinator, 2026-10-01, 1384-bxhk): the row REFUSES a new shell
-- DECIDER and a new piped litmus command. A new shell FIXTURE (test-*.sh) and a
-- new pipe site in a script are COUNTED and named on stderr as warn:, not
-- refused: refusing every new test-*.sh would force every fixture into Lua
-- while the runtime still runs one process at a time (1384-aixy's proc.spawn
-- is unlanded), and refusing every added pipe would block ordinary bash fixes
-- fleet-wide. The decider refusal is the migration's forcing function; the
-- warn: lines keep the rest visible as a score.
local n_warn = 0
for _, f in ipairs(deciders) do
    if not dfloor[f] then
        if base(f):find("^test%-") then
            n_warn = n_warn + 1
            err("warn:shell-ratchet:new-shell-fixture:" .. f .. " — counted, not refused while scripts/lua cannot spawn (1384-aixy); a Lua fixture is preferred")
        else
            v("violation:shell-ratchet:new-decider:" .. f,
              "  " .. f .. " is a NEW shell decider. Write scripts/lua/" .. base(f):gsub("%.sh$", ".lua") ..
              " instead; the runner is `tillandsias-plan script run` (1384-bqhy).")
        end
    end
end
for f, n in pairs(script_pipes) do
    local fl = pfloor["scripts " .. f] or 0
    if n > fl then
        n_warn = n_warn + 1
        err(("warn:shell-ratchet:new-pipes:%s:%d>floor:%d — counted, not refused; capture then match (grep -q PAT <<<\"$var\"), or move the logic into scripts/lua"):format(f, n, fl))
    end
end
if n_steps > 0 then
    for f, n in pairs(litmus_piped) do
        if n > (pfloor["litmus " .. f] or 0) then
            v("violation:shell-ratchet:new-piped-command:" .. f,
              "  " .. f .. " adds a `command:` with a pipe outside quotes. Use the steps: form, or a fixture script.")
        end
    end
end

-- (4) floors only descend, over each floor file's own history (no moving ref).
local function history(path)
    local r = proc.run { argv = { "git", "log", "--format=%H", "--", path } }
    if r.code ~= 0 then return {} end
    local shas = {}
    for _, l in ipairs(lines(r.stdout or "")) do if l ~= "" then shas[#shas + 1] = l end end
    return shas
end
local function at(sha, path)
    local r = proc.run { argv = { "git", "show", sha .. ":" .. path } }
    if r.code ~= 0 then return nil end
    return r.stdout
end
-- Is any key of `b` absent from `a` (a set) or larger than in `a` (counts)?
local function raised(a, b, is_set)
    for k, nv in pairs(b) do
        local ov = a[k]
        if ov == nil or (not is_set and nv > ov) then return k end
    end
    return nil
end
-- The CURRENT floor against EVERY earlier version of the floor file: no key
-- may exceed, or (for a set) reappear beyond, what any earlier version
-- allowed. A raise that was reverted is therefore fine (the current floor is
-- back down), and a raise that stuck is refused however many commits ago it
-- landed. Judged over the file's own history, never against a moving ref.
local function check_descends(path, parse_fn, is_set)
    local cur = read(path)
    if not cur then return nil end
    local now = parse_fn(cur)
    local versions = {}
    local head = at("HEAD", path)
    if head then versions[#versions + 1] = { v = head, tag = "HEAD" } end
    for _, sha in ipairs(history(path)) do
        local v = at(sha, path)
        if v then versions[#versions + 1] = { v = v, tag = sha:sub(1, 9) } end
    end
    for _, ver in ipairs(versions) do
        local k = raised(parse_fn(ver.v), now, is_set)
        if k then return k .. "@" .. ver.tag end
    end
    return nil
end
local raised_d = check_descends(DFLOOR, function(s) return (parse_decider_floor(s)) end, true)
if raised_d then v("violation:shell-ratchet:floor-raised:" .. DFLOOR .. ":" .. raised_d, "  a floor may only descend; " .. raised_d .. " was ADDED to " .. DFLOOR .. ". Port it instead.") end
local raised_p = check_descends(PFLOOR, parse_pipe_floor, false)
if raised_p then v("violation:shell-ratchet:floor-raised:" .. PFLOOR .. ":" .. raised_p, "  a floor may only descend; " .. raised_p .. " went UP in " .. PFLOOR .. ".") end

table.sort(violations)
for i = 1, #violations - 1 do out.line(violations[i]) end
if #violations > 0 then verdict.emit(violations[#violations], 1) end

verdict.emit(("ok:shell-ratchet:sh=%d:floor:%d pipes=%d:floor:%d litmus-form:command=%d:steps=%d:rust_queries=%d gate-steps:sh=%d:lua=%d shell-strings=%d")
    :format(#deciders, dfloor_n, total_pipes, pfloor_total, n_commands, n_steps, n_rq, gs_sh, gs_lua, shell_strings), 0)
