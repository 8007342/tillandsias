-- @trace order:1908-9q4c
-- @env TILLANDSIAS_GLOSSARY_BASE TILLANDSIAS_GATE_DIFF_BASE
--
-- check-glossary-retired-synonyms.lua — WARN when a change ADDS a line using a
-- retired synonym from methodology/glossary.yaml, naming its replacement.
--
-- WHY (1908-9q4c, operator 2026-10-27). One word carried up to seven senses
-- across methodology, specs and skills ("tier", "gate", "claim"), so an agent
-- reading a rule could read a different rule than its author wrote. The
-- glossary gives each term one meaning; this check keeps new text on it.
--
-- ADVISORY: it always exits 0. Old lines are never re-litigated and there is
-- no repo-wide rewrite; only lines this change ADDS (tracked and untracked
-- .md/.yaml/.yml/.sh/.lua files) are read. The glossary, the audit note and
-- this check's own files quote the retired phrases by design and are skipped.
--
-- Grammar (one line on stdout; each site on stderr):
--   ok:glossary-retired-synonyms:<n> checked          exit 0
--   advisory:glossary-retired-synonyms:<n>            exit 0
--   ok:glossary-retired-synonyms:base-unavailable     exit 0
--   ok:glossary-retired-synonyms:no-glossary          exit 0
--   could-not-run:glossary-retired-synonyms           exit 3  (not inside a git work tree)
--
-- Pinned by scripts/lua/test-glossary-retired-synonyms.lua.

local function nonempty(v) return v ~= nil and v ~= "" end

local function git(argv, cwd)
    local r = proc.run({ argv = argv, cwd = cwd, timeout_ms = 60000 })
    if r.status ~= "exited" or r.code ~= 0 then return nil end
    return r.stdout or ""
end

local top = git({ "git", "rev-parse", "--show-toplevel" })
if not top then
    verdict.could_not_run("glossary-retired-synonyms", "not inside a git work tree")
end
local ROOT = text.trim(top)
local GLOSSARY = "methodology/glossary.yaml"

local body = fs.read(ROOT .. "/" .. GLOSSARY)
if not body then verdict.ok("glossary-retired-synonyms", "no-glossary") end

local base_ref = env.get("TILLANDSIAS_GLOSSARY_BASE")
if not nonempty(base_ref) then base_ref = env.get("TILLANDSIAS_GATE_DIFF_BASE") end
if not nonempty(base_ref) then base_ref = "origin/linux-next" end
if not git({ "git", "rev-parse", "--verify", "--quiet", base_ref .. "^{commit}" }, ROOT) then
    log.raw("  note: base ref '" .. base_ref .. "' unavailable — added-line check skipped")
    verdict.ok("glossary-retired-synonyms", "base-unavailable")
end

-- The retired_synonyms flow mappings: `- {phrase: X, replacement: Y}`.
local PAIRS = {}
for _, l in ipairs(text.lines(body)) do
    local p, r = l:match("^%s*%- {phrase: ([^,]+), replacement: ([^}]+)}%s*$")
    if p then PAIRS[#PAIRS + 1] = { phrase = text.trim(p), low = text.trim(p):lower(), replacement = text.trim(r) } end
end
if #PAIRS == 0 then verdict.ok("glossary-retired-synonyms", "0 checked") end

local SKIP = {
    [GLOSSARY] = true,
    ["scripts/lua/check-glossary-retired-synonyms.lua"] = true,
    ["scripts/lua/test-glossary-retired-synonyms.lua"] = true,
}
local SPECS = { "*.md", "*.yaml", "*.yml", "*.sh", "*.lua" }
local function with_specs(argv)
    argv[#argv + 1] = "--"
    for _, s in ipairs(SPECS) do argv[#argv + 1] = s end
    return argv
end

local seen, files = {}, {}
for _, argv in ipairs({
    with_specs({ "git", "diff", "--name-only", "--diff-filter=AM", base_ref }),
    with_specs({ "git", "ls-files", "--others", "--exclude-standard" }),
}) do
    for _, f in ipairs(text.lines(git(argv, ROOT) or "")) do
        f = text.trim(f)
        if f ~= "" and not seen[f] and not SKIP[f]
            and not text.starts_with(f, "plan/issues/glossary-vocabulary-audit-") then
            seen[f] = true; files[#files + 1] = f
        end
    end
end
table.sort(files)

local function added_lines(diff)
    local out, n = {}, 0
    for _, l in ipairs(text.lines(diff)) do
        if text.starts_with(l, "@@") then
            n = tonumber(l:match("^@@ %-[%d,]+ %+(%d+)")) or 0
        elseif text.starts_with(l, "+++") then
            -- file header
        elseif text.starts_with(l, "+") then
            out[#out + 1] = n
            n = n + 1
        end
    end
    return out
end

-- Whole-word, case-insensitive, plain-text match (grep -iwF).
local function is_word(c) return c ~= "" and c:match("[%w_]") ~= nil end
local function has_word(line, needle)
    local start = 1
    while true do
        local i, j = line:find(needle, start, true)
        if not i then return false end
        if not is_word(line:sub(i - 1, i - 1)) and not is_word(line:sub(j + 1, j + 1)) then return true end
        start = i + 1
    end
end

local checked, warnings = 0, 0
for _, f in ipairs(files) do
    local path = ROOT .. "/" .. f
    if fs.exists(path) then
        checked = checked + 1
        local lines = text.lines(fs.read(path) or "")
        local added
        if git({ "git", "ls-files", "--error-unmatch", "--", f }, ROOT) then
            added = added_lines(git({ "git", "diff", "-U0", base_ref, "--", f }, ROOT) or "")
        else
            added = {}
            for i = 1, #lines do added[#added + 1] = i end
        end
        for _, ln in ipairs(added) do
            local low = (lines[ln] or ""):lower()
            for _, p in ipairs(PAIRS) do
                if has_word(low, p.low) then
                    warnings = warnings + 1
                    log.raw("WARN: " .. f .. ":" .. ln .. ' uses retired "' .. p.phrase
                        .. '"; the glossary term is "' .. p.replacement .. '" (' .. GLOSSARY .. ")")
                end
            end
        end
    end
end

if warnings > 0 then
    log.raw("  advisory: new lines should use the glossary term (1908-9q4c); nothing is refused")
    verdict.emit("advisory:glossary-retired-synonyms:" .. warnings, 0)
end
verdict.ok("glossary-retired-synonyms", checked .. " checked")
