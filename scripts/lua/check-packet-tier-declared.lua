-- @trace order:1437-cr8u, order:2080-8i25
-- @env TILLANDSIAS_FRAGMENT_PARSE_BASE TILLANDSIAS_GATE_DIFF_BASE
--
-- check-packet-tier-declared.lua: advisory (never refuses) that a NEWLY
-- DECLARED packet carries `size` and `implementer_tier`, as top-level scalars
-- or on a `notes:` line (e.g. "size: S  implementer_tier: haiku"). Ported from
-- scripts/check-packet-tier-declared.sh (shell-to-lua item paid by 2080-8i25).
--
-- WHY. The filer assigns the tier at declaration time. An unassigned row is
-- invisible to a haiku caller and silently defaults to sonnet for everyone
-- else. Advisory like check-carry-forward: promotion waits on adoption
-- (1437-cr8u).
--
-- DIFF-SCOPED: a fragment is a candidate only if added or modified versus the
-- base ref, staged, or wholly untracked. Only a `packets:` section declares;
-- `status:`/`events:` sections merely reference existing rows. A packet_id
-- already present anywhere in the base tree (plan/index.yaml or a landed
-- fragment) is not a NEW declaration even if the candidate repeats it.
--
-- One line on stdout, always exit 0:
--   ok:packet-tier-declared:<n> | advisory:packet-tier-undeclared:<n> (advisory)

local FRAG_DIR = "plan/index.d"

local function nonempty(v) return v ~= nil and v ~= "" end
local base_ref = env.get("TILLANDSIAS_FRAGMENT_PARSE_BASE")
if not nonempty(base_ref) then base_ref = env.get("TILLANDSIAS_GATE_DIFF_BASE") end
if not nonempty(base_ref) then base_ref = "origin/linux-next" end

local function git(argv)
    local r = proc.run({ argv = argv, timeout_ms = 120000 })
    if r.status ~= "exited" or r.code ~= 0 then return nil end
    return r.stdout or ""
end

if not git({ "git", "rev-parse", "--verify", "--quiet", base_ref }) then
    log.raw("  note: base ref '" .. base_ref .. "' unavailable — packet-tier-declared check skipped")
    verdict.emit("ok:packet-tier-declared:0", 0)
end

-- Every packet_id the base tree already knows, in one git grep pass. git grep
-- exits 1 on no match, which is an empty set, not an error.
local known = {}
local g = proc.run({ argv = { "git", "grep", "-h", "-o", "-E", "packet_id:[[:space:]]*[A-Za-z0-9_-]+",
    base_ref, "--", "plan/index.yaml", FRAG_DIR }, timeout_ms = 120000 })
for _, l in ipairs(text.lines(g.stdout or "")) do
    local id = l:match("^packet_id:%s*([%w_-]+)")
    if id then known[id] = true end
end

local spec = FRAG_DIR .. "/*.yaml"
local seen, candidates = {}, {}
for _, argv in ipairs({
    { "git", "diff", "--name-only", "--diff-filter=AM", base_ref, "--", spec },
    { "git", "ls-files", "--others", "--exclude-standard", "--", spec },
    { "git", "diff", "--name-only", "--cached", "--diff-filter=AM", "--", spec },
}) do
    for _, f in ipairs(text.lines(git(argv) or "")) do
        f = text.trim(f)
        if f ~= "" and not seen[f] then
            seen[f] = true
            candidates[#candidates + 1] = f
        end
    end
end
table.sort(candidates)

local function has_field(block, name)
    for _, l in ipairs(block) do
        -- start of line or after whitespace, then name: and a non-space value
        if l:match("^" .. name .. ":%s*%S") or l:match("%s" .. name .. ":%s*%S") then return true end
    end
    return false
end

local declared, undeclared = 0, 0
for _, f in ipairs(candidates) do
    if fs.exists(f) then
        local in_packets = false
        local pid, block = nil, {}
        local function flush()
            if not pid or known[pid] then return end
            if has_field(block, "size") and has_field(block, "implementer_tier") then
                declared = declared + 1
            else
                undeclared = undeclared + 1
                log.raw("advisory: " .. pid .. " declared with no size/implementer_tier (top-level or notes-line)")
            end
        end
        for _, line in ipairs(text.lines(fs.read(f) or "")) do
            if line:match("^packets:") then
                in_packets = true
            elseif in_packets and line:match("^[A-Za-z_]+:") then
                flush(); pid, block = nil, {}
                in_packets = false
            elseif in_packets then
                local id = line:match("^%s*%-%s*packet_id:%s*(.-)%s*$")
                if id then
                    flush()
                    pid, block = id, { line }
                else
                    block[#block + 1] = line
                end
            end
        end
        flush()
    end
end

if undeclared > 0 then
    verdict.advisory("advisory:packet-tier-undeclared:" .. undeclared .. " (advisory)")
end
verdict.emit("ok:packet-tier-declared:" .. declared, 0)
