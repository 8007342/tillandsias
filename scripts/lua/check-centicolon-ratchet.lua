-- @trace order:1528-gxzf, order:1395-ue3i
-- @env TILLANDSIAS_REPO_ROOT TILLANDSIAS_CENTICOLON_DIR
--
-- check-centicolon-ratchet.lua — the advisory CentiColon R line, ported from
-- check-centicolon-ratchet.sh without changing its protocol stdout or status.
-- It deliberately delegates grading to the existing grade pipeline, then owns
-- the host-local snapshot comparison that makes the R line a ratchet.
--
-- The production callers pass both an absolute script path and
-- TILLANDSIAS_REPO_ROOT. A standalone relative invocation from another
-- checkout is unsupported: it cannot safely distinguish the port's scripts
-- from the graded root without widening the runner's rooted filesystem API.

local OUT = env.get("TILLANDSIAS_CENTICOLON_DIR") or "target/centicolon"
local snapshot = arg[1] ~= "--no-snapshot"

local function lines(s)
    local out = {}
    for l in (s .. "\n"):gmatch("(.-)\n") do out[#out + 1] = l end
    return out
end

local function grade_verdict(s)
    for _, l in ipairs(lines(s)) do
        if l:sub(1, 20) == "ok:centicolon-grade:" or l:sub(1, 25) == "blocked:centicolon-grade:" then
            return l
        end
    end
    return ""
end

-- centicolon-grade's protocol (warn and its one ok:/blocked: verdict) is
-- stdout by contract. proc.run exposes fds separately, so do not pretend it
-- can reproduce arbitrary shell `2>&1` interleaving; diagnostics on stderr
-- remain the grade pipeline's diagnostics, not ratchet protocol lines.
local SCRIPTS = (arg[0] or "scripts/lua/check-centicolon-ratchet.lua"):gsub("/lua/[^/]+$", "")
local grade = proc.run({ argv = { "bash", SCRIPTS .. "/centicolon-grade.sh" } })
local protocol = grade.stdout or ""
for _, l in ipairs(lines(protocol)) do
    if l:sub(1, 5) == "warn:" then out.line(l) end
end
local grade_line = grade_verdict(protocol)
local grade_ok, grade_json = pcall(fs.read, OUT .. "/grade.json")
if grade_line:sub(1, 3) ~= "ok:" or not grade_ok or grade_json == "" then
    -- Preserve the shell's parameter expansion: an empty grade artifact after
    -- an ok verdict reports that full ok line as the blocked reason.
    local why = grade_line:gsub("^blocked:centicolon%-grade:", "")
    verdict.advisory("centicolon: blocked:" .. why .. " (advisory)")
end

local function kv(key)
    return tonumber(grade_line:match(key .. "=(%d+)")) or 0
end
local R, sat, den = kv("R"), kv("satisfied"), kv("denominator")
local dec, tra, pt = kv("declared"), kv("traced"), kv("positively_tested")
local decoded_grade = json.parse(grade_json)
local now = {}
for _, row in ipairs(decoded_grade.snapshot or {}) do now[#now + 1] = row:gsub("\r", "") end
table.sort(now)

local function contains_file(root, needle)
    local ok, files = pcall(fs.walk, root)
    if not ok then return false end
    for _, file in ipairs(files) do
        local ok_read, content = pcall(fs.read, file)
        if ok_read and content:find(needle, 1, true) then return true end
    end
    return false
end

local function has_trail(spec, req, counted)
    if contains_file("openspec/changes", req) then return true end
    if counted[spec] then return false end
    local ok, bindings = pcall(fs.read, "openspec/litmus-bindings.yaml")
    if ok then
        local in_spec, tombstone = false, false
        for _, line in ipairs(lines(bindings)) do
            if line == "- spec_id: " .. spec then in_spec = true
            elseif line:match("^- spec_id:") then in_spec = false end
            if in_spec and line:match("^  tombstone:") then tombstone = true; break end
        end
        if tombstone then return true end
    end
    return contains_file("openspec/changes", spec)
end

local added, retired, vanished, down, first = 0, 0, 0, 0, ""
local previous_ok, previous = pcall(fs.read, OUT .. "/last.txt")
if previous_ok and previous ~= "" then
    local prev, cur = {}, {}
    for _, row in ipairs(lines(previous:gsub("\r", ""))) do
        -- awk's default FS splits leading and repeated arbitrary whitespace.
        local id, state, spec, req = row:match("^%s*(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
        if id then prev[id] = { state = state, spec = spec, req = req } end
    end
    for _, row in ipairs(now) do
        local id, state = row:match("^%s*(%S+)%s+(%S+)")
        if id then cur[id] = state; if not prev[id] then added = added + 1 end end
    end
    local rank = { declared = 0, traced = 1, positively_tested = 2 }
    local counted = {}
    for spec, _ in pairs((json.parse(fs.read(OUT .. "/obligations.json")).specs_counted or {})) do counted[spec] = true end
    local gone = {}
    for id, p in pairs(prev) do
        if not cur[id] then gone[#gone + 1] = { id = id, spec = p.spec, req = p.req }
        elseif (rank[cur[id]] or 0) < (rank[p.state] or 0) then
            down = down + 1
            if first == "" or id < first then first = id end
        end
    end
    table.sort(gone, function(a, b) return a.id < b.id end)
    for _, g in ipairs(gone) do
        if has_trail(g.spec, g.req, counted) then retired = retired + 1
        else
            vanished = vanished + 1
            if first == "" or g.id < first then first = g.id end
        end
    end
end

local lost = vanished + down
local regime
if not previous_ok or previous == "" then
    regime = "baseline"
else
    local parts = {}
    if lost > 0 then
        parts[#parts + 1] = "lost"
        out.line(string.format("warn:centicolon-ratchet:lost=%d:vanished=%d,down=%d:%s", lost, vanished, down, first))
    end
    if added > 0 then parts[#parts + 1] = "scope-added" end
    if retired > 0 then parts[#parts + 1] = "retired" end
    regime = #parts == 0 and "monotone" or table.concat(parts, "+")
end
if snapshot then fs.write(OUT .. "/last.txt", table.concat(now, "\n") .. "\n") end
verdict.advisory(string.format(
    "centicolon: R=%d satisfied=%d denominator=%d added=%d retired=%d lost=%d histogram=declared:%d,traced:%d,positively_tested:%d regime=%s (advisory)",
    R, sat, den, added, retired, lost, dec, tra, pt, regime))
