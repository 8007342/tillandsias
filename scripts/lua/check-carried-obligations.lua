-- @trace order:1577-g96z, order:1570-k5yt, spec:ci-release
-- @env TILLANDSIAS_CARRIED_BASE TILLANDSIAS_CARRIED_HEAD TILLANDSIAS_CARRIED_REF
--
-- check-carried-obligations.lua — what does THIS change owe each carried
-- obligation backlog? The rule is methodology/convergence.yaml
-- `carried_obligations` (1570-k5yt; spec ci-release req-id ec267f02): a change
-- that touches a backlog's AREA is DUE, and a due change carries ONE item (the
-- backlog's counter at HEAD is below its counter at BASE) or ONE waiver line
-- (`Carried-Waiver: <backlog> <reason>` as a commit trailer on the change).
-- Silence is the only thing refused, and only at landing; a work-ref push
-- warns. A change outside the area owes nothing and is never shown the
-- obligation. An agent learns what it owes from THIS output, never from prose.
--
-- One stdout line per backlog, then one verdict:
--   carried:<backlog>:not-due
--   carried:<backlog>:paid:<item>
--   carried:<backlog>:waived:<reason>
--   carried:<backlog>:due:<item> (<n> lines)        + candidates and the exact
--                                                     waiver line on stderr
--   carried:<backlog>:unsupported-counter           (a backlog this guard cannot count)
--   ok:carried-obligations:backlogs=<n> due=<n> silent=<n>          exit 0
--   violation:carried:<backlog>:silent                              exit 1  (--landing only,
--                                                                   stage gentle/enforced)
--   violation:carried:<backlog>:waiver-not-a-trailer                exit 1  (--landing; a
--                                                                   Carried-Waiver line git did not
--                                                                   parse: not in the last paragraph)
--   skip:carried-obligations:no-base:<ref>                          exit 0
--
-- DUE is the change's own diff, `git diff --name-only BASE...HEAD` (BASE
-- defaults to origin/linux-next, as the -added deciders do), against the
-- backlog's `area` globs (`*` stays inside one path segment, `**` crosses).
-- PAID means the counter of EXISTING items fell — for shell-to-lua, the
-- population check-shell-ratchet.lua counts as `sh=` (top-level scripts/
-- check-/test-/verify-/guard- .sh outside bootstrap-shell-allowlist.txt), read
-- at the MERGE BASE and at HEAD with `git ls-tree` so both ends are measured
-- the same way and the base is the change's own, not a trunk that moved. Removing a floor line for a file already gone changes nothing here,
-- which is the point (convergence.yaml counter: slack is not debt).
-- WAIVED is a trailer read with `git log --format=%(trailers:key=Carried-
-- Waiver,valueonly) BASE..HEAD` (the Native-Lint precedent, 1235-rfub);
-- reasons are COUNTED, NOT JUDGED at the gentle stage.
--
-- THE SUGGESTION is the backlog's smallest existing items at or under
-- `item_ceiling_lines`, deciders before fixtures (fixtures stay shell longest:
-- native process conformance is open, 1543-ffhg/1544-cnae), up to five, and
-- the one offered is picked by the work ref's order modulo five so two
-- concurrent changes are not steered onto the same file.
--
-- TAKEN ITEMS are skipped: a .sh another open origin/work/* ref deletes is
-- never offered, and each skip prints `taken-by:work/<ref> <item>` on stderr
-- (two hosts ported the same offered item on 2026-10-10). Only refs fetched
-- into this clone are seen.
--
-- WHAT IT CANNOT SEE: uncommitted work (it reads BASE...HEAD, the change as it
-- will be pushed); a port on a ref not yet pushed or fetched;
-- whether a waiver's reason is TRUE (gentle stage: counted, not judged). Only
-- the shell-to-lua counter is implemented; any other backlog prints
-- unsupported-counter rather than a guess.
--
-- Arguments: --landing  refuse a due, silent change (the land queue's mode).

local BASE = env.get("TILLANDSIAS_CARRIED_BASE")
if not BASE or BASE == "" then BASE = "origin/linux-next" end
local HEAD = env.get("TILLANDSIAS_CARRIED_HEAD")
if not HEAD or HEAD == "" then HEAD = "HEAD" end
local LANDING = false
for i = 1, #arg do if arg[i] == "--landing" then LANDING = true end end

local function git(args)
    local argv = { "git" }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local r = proc.run({ argv = argv, timeout_ms = 120000 })
    return (r.status == "exited" and r.code == 0), (r.stdout or "")
end
local function lines(s)
    local out = {}
    for _, l in ipairs(text.lines(s)) do if l ~= "" then out[#out + 1] = l end end
    return out
end

local base_ok = git({ "rev-parse", "--verify", "--quiet", BASE .. "^{commit}" })
if not base_ok then
    verdict.skip("carried-obligations", "no-base:" .. BASE)
end

local _, mb = git({ "merge-base", BASE, HEAD })
local MERGE_BASE = text.trim(mb)
if MERGE_BASE == "" then MERGE_BASE = BASE end

-- ── the rule, read from methodology ────────────────────────────────────────
local ok_m, mtext = pcall(fs.read, "methodology/convergence.yaml")
local ok_y, conv = false, nil
if ok_m then ok_y, conv = pcall(yaml.parse, mtext) end
local backlogs = (ok_y and type(conv) == "table" and type(conv.carried_obligations) == "table"
    and conv.carried_obligations.backlogs) or nil
if type(backlogs) ~= "table" or #backlogs == 0 then
    verdict.emit("blocked:carried-obligations:no-backlog-table", 2,
        "methodology/convergence.yaml carried_obligations.backlogs did not parse to a non-empty list; nothing can be judged")
end

-- ── the change ─────────────────────────────────────────────────────────────
local _, diff = git({ "diff", "--name-only", BASE .. "..." .. HEAD })
local changed = lines(diff)
local _, tr = git({ "log", "--format=%(trailers:key=Carried-Waiver,valueonly)", BASE .. ".." .. HEAD })
local waivers = {} -- backlog -> first reason
for _, l in ipairs(lines(tr)) do
    local b, reason = text.trim(l):match("^(%S+)%s+(.+)$")
    if b and not waivers[b] then waivers[b] = text.trim(reason) end
end
-- A `Carried-Waiver:` line git did NOT parse as a trailer: git reads trailers
-- ONLY from a message's LAST paragraph, so a waiver written above the
-- Co-Authored-By block is invisible to %(trailers) (measured on 1570-25iq,
-- 2026-10-10). Found in the raw messages, it is NAMED rather than ignored.
local _, raw = git({ "log", "--format=%B", BASE .. ".." .. HEAD })
local unparsed = {} -- backlog -> the raw line
for _, l in ipairs(lines(raw)) do
    local b = l:match("^Carried%-Waiver:%s*(%S+)")
    if b and not waivers[b] and not unparsed[b] then unparsed[b] = l end
end

local function glob_to_pattern(g)
    local p = g:gsub("[%^%$%(%)%%%.%[%]%+%-%?]", "%%%0")
    p = p:gsub("%*%*", "\1"):gsub("%*", "[^/]*"):gsub("\1", ".*")
    return "^" .. p .. "$"
end
local function in_area(area)
    for _, path in ipairs(changed) do
        for _, g in ipairs(area) do
            if path:match(glob_to_pattern(g)) then return path end
        end
    end
    return nil
end

-- ── the shell-to-lua counter, at a ref ─────────────────────────────────────
local function shell_population(ref)
    local _, allow = git({ "show", ref .. ":scripts/portability/bootstrap-shell-allowlist.txt" })
    local boot = {}
    for _, l in ipairs(text.lines(allow)) do
        local f = l:match("^%s*(%S+)")
        if f and not f:find("^#") then boot[f] = true end
    end
    local _, tree = git({ "ls-tree", "--name-only", ref, "scripts/" })
    local pop = {}
    for _, f in ipairs(lines(tree)) do
        local leaf = f:match("^scripts/([^/]+)$")
        if leaf and leaf:match("%.sh$") and not boot[f]
            and (leaf:match("^check%-") or leaf:match("^test%-") or leaf:match("^verify%-") or leaf:match("^guard%-")) then
            pop[#pop + 1] = f
        end
    end
    table.sort(pop)
    return pop
end
local COUNTERS = { ["shell-to-lua"] = shell_population }

local function line_count(path)
    local ok_r, c = pcall(fs.read, path)
    if not ok_r then return nil end
    local _, n = c:gsub("\n", "") -- newline count, as `wc -l` counts
    return n
end

local function ref_order()
    local name = env.get("TILLANDSIAS_CARRIED_REF")
    if not name or name == "" then
        local _, b = git({ "rev-parse", "--abbrev-ref", "HEAD" })
        name = text.trim(b)
    end
    return tonumber(name:match("work/(%d+)%-") or "") or 0
end

-- Items another open work ref already deletes (ported or retired there): one
-- `git diff --name-only --diff-filter=D merge-base..tip` per origin/work/*
-- ref not yet contained in BASE. Measured 2026-10-10: two hosts ported the
-- same offered item half a day after the rule went live. Computed only when
-- a backlog is due.
local taken_cache
local function taken_items()
    if taken_cache then return taken_cache end
    taken_cache = {}
    local _, refs = git({ "for-each-ref", "--format=%(refname:short)", "refs/remotes/origin/work/" })
    for _, ref in ipairs(lines(refs)) do
        local merged = git({ "merge-base", "--is-ancestor", ref, BASE })
        if not merged then
            local _, mbr = git({ "merge-base", BASE, ref })
            mbr = text.trim(mbr)
            if mbr ~= "" then
                local _, del = git({ "diff", "--name-only", "--diff-filter=D", mbr, ref })
                for _, f in ipairs(lines(del)) do
                    if not taken_cache[f] then taken_cache[f] = ref:gsub("^origin/", "") end
                end
            end
        end
    end
    return taken_cache
end

local function candidates(pop, ceiling)
    local items = {}
    local taken = taken_items()
    for _, f in ipairs(pop) do
        local n = line_count(f)
        if n and n <= ceiling and taken[f] then
            log.raw("  taken-by:" .. taken[f] .. " " .. f)
        elseif n and n <= ceiling then
            items[#items + 1] = { f, n, f:match("^scripts/test%-") and 1 or 0 }
        end
    end
    table.sort(items, function(a, b)
        if a[3] ~= b[3] then return a[3] < b[3] end
        if a[2] ~= b[2] then return a[2] < b[2] end
        return a[1] < b[1]
    end)
    local top = {}
    for i = 1, math.min(5, #items) do top[i] = items[i] end
    return top
end

-- ── judge each backlog ─────────────────────────────────────────────────────
local n_due, silent = 0, {}
for _, b in ipairs(backlogs) do
    local name = tostring(b.name)
    local area = type(b.area) == "table" and b.area or {}
    local counter = COUNTERS[name]
    local touched = in_area(area)
    if not touched then
        out.line("carried:" .. name .. ":not-due")
    elseif not counter then
        out.line("carried:" .. name .. ":unsupported-counter")
        log.raw("  " .. name .. ": this guard has no counter for it; it judges only " .. table.concat({ "shell-to-lua" }, ","))
    else
        n_due = n_due + 1
        -- At the MERGE BASE, never the base ref's tip: the diff (BASE...HEAD)
        -- is already the change's own, and a trunk that landed other ports
        -- since this change branched would otherwise read as this change
        -- paying nothing (measured on this guard's own change, 2026-10-10).
        local base_pop, head_pop = counter(MERGE_BASE), counter(HEAD)
        local head_set = {}
        for _, f in ipairs(head_pop) do head_set[f] = true end
        local removed = nil
        for _, f in ipairs(base_pop) do if not head_set[f] then removed = f; break end end
        if #head_pop < #base_pop and removed then
            out.line("carried:" .. name .. ":paid:" .. removed)
        elseif waivers[name] then
            out.line("carried:" .. name .. ":waived:" .. waivers[name])
        else
            local ceiling = tonumber(b.item_ceiling_lines) or 150
            local top = candidates(head_pop, ceiling)
            if #top == 0 then
                out.line("carried:" .. name .. ":due:(no item at or under " .. ceiling .. " lines)")
                log.raw("  nothing in reach (every small item is taken or none exists): write `Carried-Waiver: " .. name .. " no-item-in-reach` in the message's last paragraph")
            else
                local pick = top[(ref_order() % #top) + 1]
                out.line("carried:" .. name .. ":due:" .. pick[1] .. " (" .. pick[2] .. " lines)")
                log.raw("  " .. name .. " is DUE: this change touches its area (" .. touched .. ") and neither pays an item nor waives.")
                log.raw("  candidates (smallest existing items at or under " .. ceiling .. " lines; the offered one is picked by the work ref's order):")
                for _, c in ipairs(top) do log.raw("    " .. c[1] .. " (" .. c[2] .. " lines)") end
                log.raw("  pay it: port one to scripts/lua/ on `tillandsias-plan script run`, delete the .sh, lower both floors with check-shell-ratchet.lua --dump-floors;")
                log.raw("  or put this trailer on any commit in the change, in the message's LAST paragraph next to Co-Authored-By (git reads trailers only there); one line; reasons too-big:<item>:<lines>, blocked-by:<order>, no-item-in-reach, conflict:<work-ref>, uncounted-item:<path>:")
                log.raw("Carried-Waiver: " .. name .. " <reason>")
            end
            if unparsed[name] then
                log.raw("  waiver present but not a trailer: move it to the last paragraph — " .. unparsed[name])
            end
            local stage = tostring(b.stage or "gentle")
            if stage == "gentle" or stage == "enforced" then silent[#silent + 1] = name end
        end
    end
end

if LANDING and #silent > 0 and unparsed[silent[1]] then
    verdict.emit("violation:carried:" .. silent[1] .. ":waiver-not-a-trailer", 1,
        "  waiver present but not a trailer: move it to the last paragraph (git reads trailers only from a message's last paragraph): " .. unparsed[silent[1]])
end
if LANDING and #silent > 0 then
    verdict.emit("violation:carried:" .. silent[1] .. ":silent", 1,
        "  a due change landed with neither a ported item nor a `Carried-Waiver: " .. silent[1] ..
        " <reason>` trailer (methodology/convergence.yaml carried_obligations, stage gentle).")
end
verdict.ok("carried-obligations", "backlogs=" .. #backlogs .. " due=" .. n_due .. " silent=" .. #silent)
