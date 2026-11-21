-- @trace spec:ci-release, plan 1354-uv4e, order:2118-knjy
-- @env PATH HOME TILLANDSIAS_SIGPIPE_ROOT
--
-- census-sigpipe-verdict-pipelines.lua — how many verdict pipelines that SIGPIPE
-- can decide does the STANDING corpus carry? Ported from the .sh of the same
-- name (order 2118-knjy); the verdict line is byte-identical.
--
-- `check-sigpipe-verdict-pipelines-added.sh` is DIFF-SCOPED by design: it flags
-- only pipelines added in a change, never the existing corpus. Nothing counts
-- what is already there. This does, by RUNNING THE DECIDER, not reimplementing
-- it: its own TILLANDSIAS_SIGPIPE_BASE seam is pointed at the EMPTY TREE, so
-- every line reads as "added" and the diff-scoped guard becomes a whole-corpus
-- census without a second definition of "verdict pipeline". The control that
-- makes the number mean something is scripts/lua/test-census-sigpipe-verdict-pipelines.lua.
--
-- The census is a REPORT: it exits 0 even with violations present (699-dycj,
-- 660-ryhn); it must never fail a build.
--
-- Usage: tillandsias-plan script run scripts/lua/census-sigpipe-verdict-pipelines.lua [-- --list]
-- Verdict: ok:sigpipe-verdict-standing:<sites> sites in <files> files

local DECIDER = "scripts/check-sigpipe-verdict-pipelines-added.sh"
local list = (arg or {})[1] == "--list"
local NAME = "sigpipe-verdict-standing"

local function report(sites, files)
    verdict.emit("ok:" .. NAME .. ":" .. sites .. " sites in " .. files .. " files", 0)
end

if not fs.read(DECIDER) then
    out.err("  note: " .. DECIDER .. " absent — nothing to drive")
    report(0, 0)
end
local h = proc.run({ argv = { "git", "hash-object", "-t", "tree", "/dev/null" }, timeout_ms = 30000 })
local EMPTY = text.trim(h.stdout or "")
if h.code ~= 0 or EMPTY == "" then
    out.err("  note: could not derive the empty-tree object — census not run")
    report(0, 0)
end

local r = proc.run({ argv = { "bash", DECIDER }, timeout_ms = 1800000,
    -- TILLANDSIAS_SIGPIPE_ROOT (the decider's own seam) is forwarded, so the
    -- fixture can census a scratch corpus instead of this whole checkout.
    env = { PATH = env.get("PATH"), HOME = env.get("HOME"), TILLANDSIAS_SIGPIPE_BASE = EMPTY,
        TILLANDSIAS_SIGPIPE_ROOT = env.get("TILLANDSIAS_SIGPIPE_ROOT") } })
local all = (r.stdout or "") .. "\n" .. (r.stderr or "")

-- REFUSED: lines, minus the census and its fixture (they quote the shape).
local SELF = {
    ["scripts/test-census-sigpipe-verdict-pipelines.sh"] = true,
    ["scripts/census-sigpipe-verdict-pipelines.sh"] = true,
    ["scripts/lua/test-census-sigpipe-verdict-pipelines.lua"] = true,
    ["scripts/lua/census-sigpipe-verdict-pipelines.lua"] = true,
}
local sites, per_file, files = 0, {}, 0
for _, l in ipairs(text.lines(all)) do
    if l:sub(1, 8) == "REFUSED:" then
        local f = l:match("^REFUSED:%s+(%S+)")
        local selfref = false
        for p in pairs(SELF) do
            if text.contains(l, p) then selfref = true end
        end
        if not selfref then
            sites = sites + 1
            f = f or "?"
            if not per_file[f] then per_file[f] = 0; files = files + 1 end
            per_file[f] = per_file[f] + 1
        end
    end
end
if list and sites > 0 then
    local rows = {}
    for f, n in pairs(per_file) do rows[#rows + 1] = { f = f, n = n } end
    table.sort(rows, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.f > b.f end)
    for _, row in ipairs(rows) do out.line(string.format("%7d %s", row.n, row.f)) end
end
report(sites, files)
