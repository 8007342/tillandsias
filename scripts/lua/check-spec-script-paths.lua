-- @trace order:815-yace, spec:ci-release, order:2118-9awa
-- @env TILLANDSIAS_SPEC_PATHS_SPECS TILLANDSIAS_SPEC_PATHS_ROOT TILLANDSIAS_SPEC_PATHS_BASELINE
--
-- check-spec-script-paths.lua — PORTED from check-spec-script-paths.sh
-- (2118-9awa, check-[n-z] batch 1). Every `scripts/...` path an active spec
-- names must resolve in the tree.
--
-- WHY. openspec/specs/project-summarizers/spec.md required six summarizers
-- under `scripts/summarizers/`. That directory never existed, two of the six
-- were never committed, and two ship under other names. The bound litmus grepped
-- a cheatsheet for ONE name, which exists, so every step passed and the
-- enumeration rotted green (815-yace). A spec's list of scripts is a claim about
-- the tree, and nothing checked it.
--
-- WHAT IT READS. Every openspec/specs/*/spec.md, for tokens shaped
-- `scripts/<path>.<sh|ps1|lua|rs|yaml|md>`. A token resolves when that path
-- exists relative to the repository root.
--
-- TWO WAYS A PATH MAY BE ABSENT, both named, neither silent:
--   1. a line carrying `spec-path-absent: ok (<reason>)`: a deliberate negative;
--   2. an entry in the BASELINE (scripts/spec-script-paths-baseline.txt,
--      `<spec>\t<path>\t<reason>`), a BURNDOWN list. A NEW unresolved path is
--      refused; a baselined path that now resolves prints a note.
--
-- Verdicts (last line on stdout), unchanged from the .sh:
--   ok:spec-script-paths:<resolved>-resolved,<baselined>-baselined,<exempt>-exempt
--   blocked:spec-script-paths:<n>-unresolved      (exit 1)
--   unavailable:spec-script-paths:<reason>        (exit 2)
-- Per-path violation lines, notes and why/remedy go to stderr, as before.
--
-- Seams (fixtures): TILLANDSIAS_SPEC_PATHS_SPECS (spec dir),
-- TILLANDSIAS_SPEC_PATHS_ROOT (resolution root),
-- TILLANDSIAS_SPEC_PATHS_BASELINE (baseline file).
--
-- Usage: tillandsias-plan script run scripts/lua/check-spec-script-paths.lua

local function envor(k, d)
    local v = env.get(k)
    if v == nil or v == "" then return d end
    return v
end
local SPECS = envor("TILLANDSIAS_SPEC_PATHS_SPECS", "openspec/specs")
local RESOLVE_ROOT = envor("TILLANDSIAS_SPEC_PATHS_ROOT", ".")
local BASELINE = envor("TILLANDSIAS_SPEC_PATHS_BASELINE", "scripts/spec-script-paths-baseline.txt")

local WHY = "a spec's list of scripts is a claim about the tree; a path that does not resolve is drift an implementer would build to (815-yace)"
local REMEDY = "correct the path in the spec, commit the script it describes, or for a deliberate negative mark the line <!-- spec-path-absent: ok (<reason>) -->; never grow the baseline, it is a burndown list"
local function afford() log.raw("  why: " .. WHY); log.raw("  remedy: " .. REMEDY) end

if not fs.exists(SPECS) then
    out.line("unavailable:spec-script-paths:no-spec-dir:" .. SPECS)
    verdict.emit("could-not-run:spec-script-paths:no-spec-dir", 2)
end

local function rel(p)
    local pre = "./"
    if p:sub(1, #pre) == pre then return p:sub(#pre + 1) end
    return p
end

-- One pass over every spec, in sorted path order, token order within a line.
local specs = {}
for _, f in ipairs(fs.walk(SPECS, {}) or {}) do
    if path.basename(f) == "spec.md" then specs[#specs + 1] = f end
end
table.sort(specs)

local EXTS = { sh = true, ps1 = true, lua = true, rs = true, yaml = true, md = true }
local rows = {}
for _, spec in ipairs(specs) do
    local name = rel(spec)
    for _, line in ipairs(text.lines(fs.read(spec) or "")) do
        local ex = line:find("spec-path-absent: ok (", 1, true) ~= nil
        local pos = 1
        while true do
            local s, e = line:find("scripts/[%w_./%-]+", pos)
            if not s then break end
            local tok = line:sub(s, e)
            -- awk's regex: the LONGEST prefix of this run that ends in
            -- `.<ext>` for a known extension (so `a.shx` yields `a.sh`).
            local best
            for i = 1, #tok do
                if tok:sub(i, i) == "." then
                    for ext in pairs(EXTS) do
                        if tok:sub(i + 1, i + #ext) == ext then
                            local endp = i + #ext
                            if not best or endp > best then best = endp end
                        end
                    end
                end
            end
            if best then rows[#rows + 1] = { name, tok:sub(1, best), ex } end
            pos = e + 1
        end
    end
end

if #rows == 0 then
    out.line("unavailable:spec-script-paths:no-spec-names-a-script-path — a check with nothing to read vouches for nothing")
    verdict.emit("could-not-run:spec-script-paths:no-spec-names-a-script-path", 2)
end

local baseline = {}
if fs.exists(BASELINE) then
    for _, l in ipairs(text.lines(fs.read(BASELINE) or "")) do
        local t = text.trim(l)
        if t ~= "" and t:sub(1, 1) ~= "#" then
            local a, b = l:match("^([^\t]*)\t([^\t]*)")
            if a then baseline[a .. "\t" .. b] = true end
        end
    end
end

local resolved, baselined, exempt, unresolved = 0, 0, 0, 0
local seen = {}
local base_name = BASELINE:gsub("^%./", "")
for _, r in ipairs(rows) do
    local spec, p, ex = r[1], r[2], r[3]
    local key = spec .. "\t" .. p
    if not seen[key] then
        seen[key] = true
        local full = RESOLVE_ROOT == "." and p or (RESOLVE_ROOT .. "/" .. p)
        if fs.exists(full) then
            resolved = resolved + 1
            if baseline[key] then
                log.raw("note: " .. spec .. " names " .. p .. ", which now RESOLVES — remove its line from " .. base_name .. " (burndown)")
            end
        elseif ex then
            exempt = exempt + 1
        elseif baseline[key] then
            baselined = baselined + 1
        else
            unresolved = unresolved + 1
            log.raw("violation:spec-script-paths:" .. spec .. ":" .. p .. " — the spec names a script that is not in the tree")
            afford()
        end
    end
end

if unresolved > 0 then
    out.line("blocked:spec-script-paths:" .. unresolved .. "-unresolved")
    afford()
    verdict.emit("blocked:spec-script-paths:" .. unresolved .. "-unresolved", 1)
end
out.line(("ok:spec-script-paths:%d-resolved,%d-baselined,%d-exempt"):format(resolved, baselined, exempt))
verdict.emit("ok:spec-script-paths", 0)
