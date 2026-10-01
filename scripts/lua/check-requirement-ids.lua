-- @trace order:1527-v7cy, order:976-suab, spec:spec-traceability, spec:methodology-accountability
-- @env TILLANDSIAS_SPEC_ROOT TILLANDSIAS_SPEC_GLOB
-- @read-env TILLANDSIAS_SPEC_ROOT
--
-- check-requirement-ids.lua — PORTED from check-requirement-ids.sh, byte for
-- byte. Every `### Requirement:` heading (and the numbered pre-976-suab
-- `### Requirement <n>:` dialect, order 1396-35we) is followed by a
-- `<!-- req-id: ... -->` comment, and no identifier appears twice anywhere in
-- the corpus. Tombstoned specs are checked too — see the .sh's header for why
-- exempting them would shrink the very denominator this guard protects.
--
-- TILLANDSIAS_SPEC_ROOT is a TEST SEAM (scripts/test-requirement-ids.sh points
-- it at a fake openspec tree, outside the repo, exactly like
-- scripts/lua/check-spec-registry-status.lua's TILLANDSIAS_SPEC_ROOT); -- @read-env
-- widens fs.read/fs.walk under it. Production never sets it.
--
-- WHAT THE PORT MAKES SLIGHTLY DIFFERENT: TILLANDSIAS_SPEC_GLOB only ever
-- takes its default shape in this tree, one directory wildcard,
-- "openspec/specs/*/spec.md" — grepping every caller confirms nothing sets it
-- to anything else. This port supports any glob with EXACTLY ONE "*" by
-- walking the prefix directory and keeping paths whose suffix matches; a
-- glob with zero or more than one "*" could-not-runs by name rather than
-- silently matching nothing or everything. fs.walk recurses, so a spec.md
-- more than one directory below the wildcard would also match where the
-- shell glob would not — the live corpus has none (`find openspec/specs
-- -mindepth 3 -name spec.md` is empty), so this is unobservable today.
--
-- Verdict grammar (unchanged, legacy — these are NOT the house ok:/violation:
-- short forms, so verdict.emit carries the exact text):
--   ok:requirement-ids:<n> requirement(s), all identified and unique   exit 0
--   violation:requirement-ids-missing:<n>                              exit 1
--   violation:requirement-ids-duplicated:<n>                          exit 1
--   could-not-run:requirement-ids:unsupported-glob:<glob>              exit 3

local root_env = env.get("TILLANDSIAS_SPEC_ROOT")
local SPEC_ROOT = (root_env and root_env ~= "") and root_env or nil
local function rooted(rel)
    if SPEC_ROOT then return SPEC_ROOT .. "/" .. rel end
    return rel
end

local glob_env = env.get("TILLANDSIAS_SPEC_GLOB")
local GLOB = (glob_env and glob_env ~= "") and glob_env or "openspec/specs/*/spec.md"

local star_at = GLOB:find("*", 1, true)
if not star_at or GLOB:find("*", star_at + 1, true) then
    verdict.emit("could-not-run:requirement-ids:unsupported-glob:" .. GLOB, 3)
end
local glob_prefix = GLOB:sub(1, star_at - 1):gsub("/$", "")
local glob_suffix = GLOB:sub(star_at + 1)

local ok_walk, walked = pcall(fs.walk, rooted(glob_prefix), { suffix = glob_suffix })
local specs = ok_walk and walked or {}

local HEADING1 = [[^### Requirement:]]
local HEADING2 = [[^### Requirement [0-9]+:]]
local REQID_LINE = [[^<!-- req-id: .* -->$]]
local REQID_ANY = "<!%-%- req%-id: ([0-9a-f]+) %-%->"

local missing = 0
local total = 0
local missing_lines = {}
local contents = {}

for _, f in ipairs(specs) do
    local ok_r, content = pcall(fs.read, f)
    if ok_r then
        contents[f] = content
        local lines = text.lines(content)
        local n = #lines
        local prev_was_heading = false
        for i, line in ipairs(lines) do
            if prev_was_heading then
                prev_was_heading = false
                if not text.is_match(line, REQID_LINE) then
                    missing_lines[#missing_lines + 1] =
                        "  " .. f .. ":" .. (i - 1) .. " requirement has no req-id on the line below it"
                    missing = missing + 1
                end
            end
            if text.is_match(line, HEADING1) or text.is_match(line, HEADING2) then
                prev_was_heading = true
                total = total + 1
            end
        end
        if prev_was_heading then
            missing_lines[#missing_lines + 1] =
                "  " .. f .. ":" .. n .. " requirement heading is the last line and has no req-id"
            missing = missing + 1
        end
    end
end

for _, l in ipairs(missing_lines) do log.raw(l) end

if missing > 0 then
    log.raw("  run scripts/stamp-requirement-ids.sh to stamp what is missing (it never reassigns)")
    verdict.emit("violation:requirement-ids-missing:" .. missing, 1)
end

-- Duplicates: every <!-- req-id: HEX --> occurrence corpus-wide (not only the
-- ones right after a heading, same as the .sh's grep -rhoE over the glob).
local occurrences = 0
local id_count = {}
local id_files = {}
for _, f in ipairs(specs) do
    local content = contents[f]
    if content then
        local seen_in_file = {}
        for id in content:gmatch(REQID_ANY) do
            occurrences = occurrences + 1
            id_count[id] = (id_count[id] or 0) + 1
            if not seen_in_file[id] then
                seen_in_file[id] = true
                id_files[id] = id_files[id] or {}
                id_files[id][#id_files[id] + 1] = f
            end
        end
    end
end

local dup_ids = {}
for id, c in pairs(id_count) do
    if c > 1 then dup_ids[#dup_ids + 1] = id end
end
table.sort(dup_ids)

if #dup_ids > 0 then
    for _, d in ipairs(dup_ids) do
        log.raw("  duplicate req-id '" .. d .. "' in:")
        for _, f in ipairs(id_files[d] or {}) do
            log.raw("    " .. f)
        end
    end
    verdict.emit("violation:requirement-ids-duplicated:" .. #dup_ids, 1)
end

verdict.emit("ok:requirement-ids:" .. total .. " requirement(s), all identified and unique", 0)
