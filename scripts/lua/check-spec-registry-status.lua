-- @trace order:1525-c6jm, order:1397-eppt
-- @env TILLANDSIAS_SPEC_ROOT TILLANDSIAS_SPEC_UNDECIDED
-- @read-env TILLANDSIAS_SPEC_ROOT
--
-- check-spec-registry-status.lua — PORTED from check-spec-registry-status.sh,
-- byte for byte. A spec and the litmus registry must agree on the spec's
-- status.
--
-- RULE: for every registry entry whose spec file exists, the first WORD of
-- the first non-blank line under the spec's `## Status` (an optional
-- `status:` prefix is ignored, and so is an annotation after the word) must
-- equal the entry's `status:`. A spec with no `## Status` is a mismatch.
--
-- TILLANDSIAS_SPEC_ROOT is a TEST SEAM (scripts/test-spec-registry-status.sh
-- points it at a fake openspec tree, outside the repo); production never sets
-- it. WHAT THE PORT MAKES SLIGHTLY DIFFERENT: the .sh distinguished `cd`
-- failing on a wholly missing SPEC_ROOT (`no-root`) from a present root with
-- no registry file (`no-registry`); this port reports `no-registry` for both,
-- since the runner has no `cd` to fail — a distinction the shipped fixture
-- never exercises (every arm builds a complete fake tree).
--
-- OUTPUT: ok:spec-registry-status:<checked> undecided=<n> (each named above)  exit 0
--         refused:spec-registry-status:<n> (of <checked>) — ...             exit 1
--         could-not-run:spec-registry-status:no-registry                    exit 3
--         could-not-run:spec-registry-status:no-entries-resolved            exit 3
local root_env = env.get("TILLANDSIAS_SPEC_ROOT")
local SPEC_ROOT = (root_env and root_env ~= "") and root_env or nil

local function path(rel)
    if SPEC_ROOT then return SPEC_ROOT .. "/" .. rel end
    return rel
end

local R = path("openspec/litmus-bindings.yaml")
local ok_r, registry_src = pcall(fs.read, R)
if not ok_r then
    verdict.emit("could-not-run:spec-registry-status:no-registry", 3)
end

-- UNDECIDED PAIRS, named with the reason they could not be decided from the
-- evidence. `${VAR-default}` semantics: the default applies only when the
-- variable is wholly UNSET, not when it is set to the empty string — the
-- fixture relies on this to force undecided="" for its clean-agreement arm.
local und_env = env.get("TILLANDSIAS_SPEC_UNDECIDED")
local UNDECIDED = und_env ~= nil and und_env or "tray-host-control-socket"

local function in_undecided(id)
    return (" " .. UNDECIDED .. " "):find(" " .. id .. " ", 1, true) ~= nil
end

local function undecided_reason(id)
    if id == "tray-host-control-socket" then
        return "registry tombstone says superseded by orders 123-128 (host-guest-transport; 125 and 128 still pending); successor specs host-guest-transport and vsock-transport exist and control-wire traces vsock-transport 19x vs this spec 8x, but whether the Unix-socket tray control plane this spec describes still exists beside vsock is a design question"
    end
    return ""
end

-- Registry entries: `- spec_id: <id>` then, on a LATER line, `  status: <word>`
-- (awk's state machine, ported line for line).
local entries = {}
local pending_id = nil
for _, l in ipairs(text.lines(registry_src)) do
    local sid = l:match("^%- spec_id:%s*(%S+)")
    if sid then
        pending_id = sid
    else
        local st = l:match("^  status:%s*(%S+)")
        if st and pending_id then
            entries[#entries + 1] = { id = pending_id, reg = st }
            pending_id = nil
        end
    end
end

local function spec_status_of(f)
    local ok, content = pcall(fs.read, f)
    if not ok then return nil end
    local seen_header = false
    for _, l in ipairs(text.lines(content)) do
        if not seen_header then
            if text.is_match(l, [=[^## Status[[:space:]]*$]=]) then seen_header = true end
        else
            local trimmed = l:match("^%s*(.-)%s*$")
            if trimmed ~= "" then
                local body = l:gsub("^status:%s*", "")
                return body:match("%S+")
            end
        end
    end
    return nil
end

local checked, bad, und = 0, 0, 0
local mismatches = {}
for _, e in ipairs(entries) do
    local f = path("openspec/specs/" .. e.id .. "/spec.md")
    local ok_f, _ = pcall(fs.read, f)
    if ok_f then
        checked = checked + 1
        local spec = spec_status_of(f)
        if spec ~= e.reg then
            if in_undecided(e.id) then
                und = und + 1
                out.line("undecided:" .. e.id .. ":spec=" .. (spec or "") .. ":registry=" .. e.reg .. " — " .. undecided_reason(e.id))
            else
                bad = bad + 1
                mismatches[#mismatches + 1] = "mismatch:" .. e.id .. ":spec=" .. (spec or "<none>") .. ":registry=" .. e.reg
            end
        end
    end
end

if checked == 0 then
    verdict.emit("could-not-run:spec-registry-status:no-entries-resolved", 3)
end
if bad == 0 then
    verdict.emit("ok:spec-registry-status:" .. checked .. " undecided=" .. und, 0)
end
for _, m in ipairs(mismatches) do out.line(m) end
verdict.emit("refused:spec-registry-status:" .. bad .. " (of " .. checked .. ") — reconcile each pair with a recorded reason (1397-eppt)", 1)
