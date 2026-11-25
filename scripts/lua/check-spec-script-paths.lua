-- @trace order:815-yace, order:2083-6k44, spec:ci-release
-- @env TILLANDSIAS_SPEC_PATHS_SPECS TILLANDSIAS_SPEC_PATHS_ROOT TILLANDSIAS_SPEC_PATHS_BASELINE
--
-- check-spec-script-paths.lua: every `scripts/...` path an active spec names
-- must resolve in the tree. Ported from scripts/check-spec-script-paths.sh
-- (shell-to-lua item paid by 2083-6k44); the per-spec awk body is now the
-- scan() function below, not a string carried over.
--
-- WHY. openspec/specs/project-summarizers/spec.md required six summarizers
-- under `scripts/summarizers/`; that directory never existed, two of the six
-- were never committed and two ship under other names. The bound litmus
-- grepped a cheatsheet for ONE name, which exists, so it rotted green
-- (815-yace). A spec's list of scripts is a claim about the tree.
--
-- WHAT IT READS. Every <specs>/*/spec.md, for tokens shaped
-- `scripts/<path>.<sh|ps1|lua|rs|yaml|md>`. A token resolves when that path
-- exists relative to the resolution root.
--
-- TWO WAYS A PATH MAY BE ABSENT, both named, neither silent:
--   1. Its own line carries `spec-path-absent: ok (<reason>)` (an HTML
--      comment): a deliberate negative.
--   2. An entry in the BASELINE (scripts/spec-script-paths-baseline.txt,
--      `<spec>\t<path>\t<reason>`): a BURNDOWN list of drift that predates the
--      check. A NEW unresolved path is refused; a baselined path that now
--      resolves prints a note asking for the entry to be removed.
--
-- Verdicts (last line):
--   ok:spec-script-paths:<resolved>-resolved,<baselined>-baselined,<exempt>-exempt
--   blocked:spec-script-paths:<n>-unresolved               (exit 1)
--   could-not-run:spec-script-paths:<reason>               (exit 2)
--
-- Seams (fixtures): TILLANDSIAS_SPEC_PATHS_SPECS (spec dir),
-- TILLANDSIAS_SPEC_PATHS_ROOT (resolution root),
-- TILLANDSIAS_SPEC_PATHS_BASELINE (baseline file). Relative defaults resolve
-- against the runner's cwd, the repository root.

local function nonempty(v) return v ~= nil and v ~= "" end
local function envor(k, d) local v = env.get(k); if nonempty(v) then return v end; return d end
local SPECS = envor("TILLANDSIAS_SPEC_PATHS_SPECS", "openspec/specs")
local RESOLVE_ROOT = envor("TILLANDSIAS_SPEC_PATHS_ROOT", ".")
local BASELINE = envor("TILLANDSIAS_SPEC_PATHS_BASELINE", "scripts/spec-script-paths-baseline.txt")

local WHY = "a spec's list of scripts is a claim about the tree; a path that does not resolve is drift an implementer would build to (815-yace)"
local REMEDY = "correct the path in the spec, commit the script it describes, or for a deliberate negative mark the line <!-- spec-path-absent: ok (<reason>) -->; never grow the baseline, it is a burndown list"
local function afford() log.raw("  why: " .. WHY); log.raw("  remedy: " .. REMEDY) end

if not fs.exists(SPECS) then
    verdict.emit("could-not-run:spec-script-paths:no-spec-dir:" .. SPECS, 2)
end

local EXT = { sh = true, ps1 = true, lua = true, rs = true, yaml = true, md = true }

-- The tokens on one line, as awk's leftmost-longest match of
-- scripts/[A-Za-z0-9_./-]+\.(sh|ps1|lua|rs|yaml|md) found them: from each
-- `scripts/` start, the LONGEST prefix of the path-character run that ends
-- in an allowed extension; scanning resumes after it.
local function scan(line)
    local toks, pos = {}, 1
    while true do
        local s, e = line:find("scripts/[%w_%./%-]+", pos)
        if not s then break end
        local run, cut = line:sub(s, e), nil
        for k = #run, 9, -1 do
            local ext = run:sub(1, k):match("%.(%w+)$")
            if ext and EXT[ext] and k > 9 then cut = k; break end
        end
        if cut then
            toks[#toks + 1] = run:sub(1, cut)
            pos = s + cut
        else
            pos = s + 1
        end
    end
    return toks
end

local specs = {}
for _, f in ipairs(fs.walk(SPECS, { suffix = "spec.md" })) do
    if f:match("[/\\]spec%.md$") or f == "spec.md" then specs[#specs + 1] = (f:gsub("\\", "/")) end
end
table.sort(specs)

local rows = {}
for _, spec in ipairs(specs) do
    local rel = spec:gsub("^%./", "")
    for _, line in ipairs(text.lines(fs.read(spec) or "")) do
        local ex = line:find("spec-path-absent: ok (", 1, true) ~= nil
        for _, p in ipairs(scan(line)) do rows[#rows + 1] = { rel, p, ex } end
    end
end
if #rows == 0 then
    verdict.emit("could-not-run:spec-script-paths:no-spec-names-a-script-path — a check with nothing to read vouches for nothing", 2)
end

local baseline = {}
if fs.exists(BASELINE) then
    for _, l in ipairs(text.lines(fs.read(BASELINE) or "")) do
        if not l:match("^%s*#") and not l:match("^%s*$") then
            local a, b = l:match("^([^\t]*)\t([^\t]*)")
            if a then baseline[a .. "\t" .. b] = true end
        end
    end
end

local resolved, baselined, exempt, unresolved = 0, 0, 0, 0
local seen = {}
for _, r in ipairs(rows) do
    local spec, path, ex = r[1], r[2], r[3]
    local key = spec .. "\t" .. path
    if not seen[key] then
        seen[key] = true
        if fs.exists(RESOLVE_ROOT .. "/" .. path) then
            resolved = resolved + 1
            if baseline[key] then
                log.raw("note: " .. spec .. " names " .. path .. ", which now RESOLVES — remove its line from " .. BASELINE .. " (burndown)")
            end
        elseif ex then
            exempt = exempt + 1
        elseif baseline[key] then
            baselined = baselined + 1
        else
            unresolved = unresolved + 1
            log.raw("violation:spec-script-paths:" .. spec .. ":" .. path .. " — the spec names a script that is not in the tree")
        end
    end
end

if unresolved > 0 then
    afford()
    verdict.emit("blocked:spec-script-paths:" .. unresolved .. "-unresolved", 1)
end
verdict.emit("ok:spec-script-paths:" .. resolved .. "-resolved," .. baselined .. "-baselined," .. exempt .. "-exempt", 0)
