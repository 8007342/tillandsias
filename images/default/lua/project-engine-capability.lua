-- @trace order:569, order:2393-j27x, spec:default-image
-- @class observing
--
-- project-engine-capability.lua — the body of images/default/lib-project-engine-capability.sh,
-- run by `tillandsias-plan script run --helper` (openspec change forge-lua-helpers D3.6). It
-- asks the BAKED engine for its capability manifest and reads the CHECKOUT's expected one out
-- of the engine source without executing it; the awk | sort, sed | sed and tr | sed pipelines
-- (16 processes, measured in the forge image) become one engine run and one file read.
--
-- Arguments: <engine> <checkout>. Output, five lines in this order:
--   state      absent | stale-engine | ready | skewed     (the CLOSED vocabulary)
--   baked      engine-contract-vN from the engine's own manifest, or -
--   expected   engine-contract-vN from the checkout's manifest, or -
--   missing    comma-joined tokens the checkout expects and the engine lacks, or -
--   only       comma-joined tokens the engine has and the checkout does not, or -
-- It never errors: a missing, crashing, hanging or pre-manifest engine and an unreadable
-- checkout each land inside the grammar (the probe is optional, order 486).

local bin, checkout = arg[1] or "", arg[2] or ""
local SRC_REL = "images/default/config-overlay/mcp/project-info.sh"

-- One token per line, comments and whitespace removed, the shape filter, sorted and unique
-- in byte order: what `awk '{sub(/#.*/,"")} {gsub(/[ \t\r]+/,"")} /^[a-z][a-z0-9-]*$/' | sort -u` kept.
local function clean(text_)
    local seen, set = {}, {}
    for l in ((text_ or "") .. "\n"):gmatch("([^\n]*)\n") do
        l = l:gsub("#.*", ""):gsub("[ \t\r]+", "")
        if l:match("^[a-z][a-z0-9%-]*$") and not seen[l] then seen[l] = true; set[#set + 1] = l end
    end
    table.sort(set)
    return set, seen
end
local function version(set)
    for _, t in ipairs(set) do if t:match("^engine%-contract%-v%d+$") then return t end end
    return "-"
end
local function join(t) return #t > 0 and table.concat(t, ",") or "-" end

local state = "absent"
local baked, expected, missing, only = "-", "-", "-", "-"
local now, now_has = {}, {}
if bin ~= "" then
    -- stdin is empty so a pre-manifest engine (a JSON-RPC stdin loop) reads EOF and exits.
    local r = proc.run{ argv = { bin, "capabilities" }, stdin = "", timeout_ms = 5000 }
    if r.status ~= "spawn_failed" and r.status ~= "policy_denied" and r.status ~= "policy_consent_required" then
        local raw = (r.status == "exited" and r.code == 0) and (r.stdout or "") or ""
        now, now_has = clean(raw)
        if #now == 0 then state = "stale-engine" else state = "ready"; baked = version(now) end
    end
end

local want, want_has = {}, {}
if checkout ~= "" then
    local c = proc.run{ argv = { "cat", checkout .. "/" .. SRC_REL }, timeout_ms = 10000 }
    if c.status == "exited" and c.code == 0 then
        -- The lines between PROJECT_INFO_ENGINE_MANIFEST=' and the next line starting with ',
        -- both excluded; with no closing line, the range runs to the end and its last line is
        -- dropped, as `sed -n "/^X='/,/^'/p" | sed '1d;$d'` did.
        local body, inside, closed = {}, false, false
        for l in ((c.stdout or "") .. "\n"):gmatch("([^\n]*)\n") do
            if not inside then
                if l:match("^PROJECT_INFO_ENGINE_MANIFEST='") then inside = true end
            elseif l:match("^'") then
                closed = true; break
            else
                body[#body + 1] = l
            end
        end
        if inside and not closed and #body > 0 then body[#body] = nil end
        want, want_has = clean(table.concat(body, "\n"))
        if #want > 0 then expected = version(want) end
    end
end

if state == "ready" and #want > 0 then
    local m, o = {}, {}
    for _, t in ipairs(want) do if not now_has[t] then m[#m + 1] = t end end
    for _, t in ipairs(now) do if not want_has[t] then o[#o + 1] = t end end
    missing, only = join(m), join(o)
    if missing ~= "-" or only ~= "-" then state = "skewed" end
end

out.line(state); out.line(baked); out.line(expected); out.line(missing); out.line(only)
