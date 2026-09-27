-- centicolon-extract.lua — the CentiColon obligation extractor (order 1395-n7qd).
-- @trace order:1395-n7qd
--
-- A CACHEABLE predicate: its output is a pure function of the bytes it reads
-- (openspec/litmus-bindings.yaml and openspec/specs/<spec>/spec.md) and of its
-- argument. No clock, no shell, no fs.list, no `next` (withheld since
-- 1384-bp6t; `pairs` walks in defined order), no print.
--
--   tillandsias-plan predicate scripts/lua/centicolon-extract.lua --class cacheable [--arg <dirs>]
--
-- THE UNIT (design: plan/issues/centicolon-enforceable-metric-design-2026-09-26.md §3):
-- one obligation per `#### Scenario:` under a `### Requirement:` whose NEXT
-- line is `<!-- req-id: <hex> -->`, in a spec whose status is active or draft.
-- A requirement with no scenario is one obligation by itself. Identity:
-- cc:<req-id>:<sha256(normalized title)[:8]>. `### Invariant:` blocks are the
-- second kind, cc:inv:<spec>:<sha256(title)[:8]>, counted separately.
--
-- THE POPULATION. Without fs.list the predicate cannot enumerate directories,
-- so the CALLER passes the spec directory names it sees (comma-separated) as
-- the argument; the argument is part of the cache key, so the result stays
-- pure. A directory absent from the bindings registry is reported
-- `unregistered` (never silently skipped) and a registry id with no spec file
-- is reported `missing`. An empty argument means registry-only, and the output
-- says so (`population: registry-only`).
--
-- OUTPUT goes through expert.log_info (stderr, "[lua-predicate] " prefix):
--   centicolon-extract:<canonical JSON, keys sorted by the 1384-bp6t encoder>
--   ok:centicolon-extract:obligations=<n> ...           (returns true)
--   refused:centicolon-extract:<why>:<spec>:<title>     (returns false)
--   blocked:centicolon-extract:zero-population          (returns false; never ok:0)
--
-- WHAT IS REFUSED, BY NAME: a `### Requirement:` heading whose next line is not
-- a req-id (the shape check-requirement-ids.sh guards, 976-suab), and two
-- obligations under one requirement with the same identity (duplicate title).
-- The numbered dialect (`### Requirement 1: …`) counts like the plain one when
-- its next line is a req-id (1396-35we gave all 29 such headings forward ids);
-- a numbered heading WITHOUT one is not counted and not refused, but listed as
-- `unkeyed` so the gap stays visible in every run.

-- Every LIST field is built with json.array() so an empty list encodes as []
-- and never as {} (1398-3qiz). The fallback keeps an older binary working.
local A = json.array or function(t) return t or {} end

local COUNTED = { active = true, draft = true }

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Titles are hashed after whitespace normalization, so re-wrapping or
-- trailing spaces never mint a new identity; any other byte change does.
local function norm(s)
    return trim(s:gsub("%s+", " "))
end

local function short(s)
    return hash.sha256(norm(s)):sub(1, 8)
end

local function lines_of(text)
    local out = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        out[#out + 1] = (line:gsub("\r$", ""))
    end
    return out
end

-- Status in both spellings the corpus uses: `status: <word>` on its own line
-- anywhere before the first requirement, or the first non-empty line under
-- `## Status`. Absent -> "unknown", which is excluded and counted as such.
local function spec_status(lines)
    local in_status = false
    for _, line in ipairs(lines) do
        if line:match("^### ") then break end
        local w = line:match("^[Ss]tatus:%s*[%*_`]*(%a+)")
        if w then return w:lower() end
        if line:match("^## Status%s*$") then
            in_status = true
        elseif in_status then
            if line:match("^## ") then
                in_status = false
            elseif line:match("%S") then
                local word = line:match("^[%s%*_`>-]*(%a+)")
                if word then return word:lower() end
            end
        end
    end
    return "unknown"
end

local function count_musts(body)
    local n = 0
    for _, l in ipairs(body) do
        for w in l:gmatch("%u+") do
            if w == "MUST" or w == "SHALL" then n = n + 1 end
        end
    end
    return n
end

local function traces_of(body)
    local seen, out = {}, A()
    for _, l in ipairs(body) do
        for t in l:gmatch("@trace%s+spec:([%w%-_%.]+)") do
            if not seen[t] then seen[t] = true; out[#out + 1] = t end
        end
    end
    table.sort(out)
    return out
end

-- Parse one spec. Returns obligations, invariants, unkeyed titles, refusals.
local function parse_spec(spec, text)
    local lines = lines_of(text)
    local digest = hash.sha256(text)
    local obligations, invariants, unkeyed, refusals = A(), A(), A(), A()
    local req = nil      -- current requirement: {id, title, body, scenarios, ids}
    local in_fence = false

    local function close_req()
        if not req then return end
        local musts = count_musts(req.body)
        local traces = traces_of(req.body)
        if #req.scenarios == 0 then
            obligations[#obligations + 1] = {
                id = "cc:" .. req.id .. ":" .. short(req.title), kind = "requirement",
                spec = spec, req_id = req.id, requirement = req.title, title = req.title,
                must_tokens = musts, traces = traces, spec_digest = digest,
            }
        else
            for _, sc in ipairs(req.scenarios) do
                obligations[#obligations + 1] = {
                    id = "cc:" .. req.id .. ":" .. short(sc), kind = "scenario",
                    spec = spec, req_id = req.id, requirement = req.title, title = sc,
                    must_tokens = musts, traces = traces, spec_digest = digest,
                }
            end
        end
        req = nil
    end

    for i, line in ipairs(lines) do
        if line:match("^```") then in_fence = not in_fence end
        if not in_fence then
            local rt = line:match("^### Requirement:%s*(.-)%s*$")
            local numbered = line:match("^### Requirement%s+%d+[%.:]%s*(.-)%s*$")
            local id = (rt or numbered) and (lines[i + 1] or ""):match("^<!%-%- req%-id: (%x+) %-%->$")
            if rt or (numbered and id) then
                close_req()
                if id then
                    req = { id = id, title = norm(rt or numbered), body = {}, scenarios = {}, ids = {} }
                else
                    refusals[#refusals + 1] = "requirement-without-req-id:" .. spec .. ":" .. norm(rt)
                end
            elseif numbered then
                close_req()
                unkeyed[#unkeyed + 1] = spec .. ":" .. norm(numbered)
            elseif line:match("^### ") or line:match("^## ") or line:match("^# ") then
                close_req()
                local inv = line:match("^### Invariant:%s*(.-)%s*$")
                if inv then
                    invariants[#invariants + 1] = {
                        id = "cc:inv:" .. spec .. ":" .. short(inv), kind = "invariant",
                        spec = spec, title = norm(inv), spec_digest = digest,
                    }
                end
            elseif req then
                local sc = line:match("^#### Scenario:%s*(.-)%s*$")
                if sc then
                    local key = short(sc)
                    if req.ids[key] then
                        refusals[#refusals + 1] = "duplicate-obligation-id:" .. spec .. ":cc:" .. req.id .. ":" .. key
                    end
                    req.ids[key] = true
                    req.scenarios[#req.scenarios + 1] = norm(sc)
                else
                    req.body[#req.body + 1] = line
                end
            end
        end
    end
    close_req()
    return obligations, invariants, unkeyed, refusals, digest
end

local function split_arg(arg)
    local out, seen = A(), {}
    for item in (arg or ""):gmatch("[^,%s]+") do
        if not seen[item] then seen[item] = true; out[#out + 1] = item end
    end
    table.sort(out)
    return out
end

local function by_id(a, b) return a.id < b.id end

local function extract(arg)
    local reg_text = fs.read("openspec/litmus-bindings.yaml")
    local reg = yaml.parse(reg_text) or {}
    local registered, reg_status = {}, {}
    for _, s in ipairs(reg.specs or {}) do
        if type(s) == "table" and type(s.spec_id) == "string" then
            registered[s.spec_id] = true
            reg_status[s.spec_id] = s.status
        end
    end

    local dirs = split_arg(arg)
    local population = (#dirs > 0) and "argument" or "registry-only"
    local specs, unregistered, missing = {}, A(), A()
    if #dirs > 0 then
        local present = {}
        for _, d in ipairs(dirs) do
            present[d] = true
            if registered[d] then specs[#specs + 1] = d else unregistered[#unregistered + 1] = d end
        end
        for id in pairs(registered) do
            if not present[id] then missing[#missing + 1] = id end
        end
    else
        for id in pairs(registered) do specs[#specs + 1] = id end
    end
    table.sort(specs); table.sort(missing)

    local obligations, invariants, unkeyed, refusals = A(), A(), A(), A()
    local excluded, per_spec, mismatch = {}, {}, A()
    local requirements = 0
    for _, spec in ipairs(specs) do
        local ok, text = pcall(fs.read, "openspec/specs/" .. spec .. "/spec.md")
        if not ok then
            missing[#missing + 1] = spec
        else
            local status = spec_status(lines_of(text))
            if reg_status[spec] and reg_status[spec] ~= status then
                mismatch[#mismatch + 1] = spec .. ":spec=" .. status .. ":registry=" .. tostring(reg_status[spec])
            end
            if COUNTED[status] then
                local obs, invs, unk, refs, digest = parse_spec(spec, text)
                local reqs = {}
                for _, o in ipairs(obs) do reqs[o.req_id] = true end
                local nreq = 0
                for _ in pairs(reqs) do nreq = nreq + 1 end
                requirements = requirements + nreq
                per_spec[spec] = { status = status, requirements = nreq, obligations = #obs,
                                   invariants = #invs, unkeyed = #unk, spec_digest = digest }
                for _, o in ipairs(obs) do obligations[#obligations + 1] = o end
                for _, o in ipairs(invs) do invariants[#invariants + 1] = o end
                for _, u in ipairs(unk) do unkeyed[#unkeyed + 1] = u end
                for _, r in ipairs(refs) do refusals[#refusals + 1] = r end
            else
                excluded[status] = (excluded[status] or 0) + 1
            end
        end
    end
    table.sort(obligations, by_id); table.sort(invariants, by_id)
    table.sort(unkeyed); table.sort(refusals); table.sort(missing); table.sort(mismatch)

    return {
        schema = "centicolon-extract/1",
        population = population,
        specs_counted = per_spec,
        requirements = requirements,
        obligations = obligations,
        obligation_count = #obligations,
        invariants = invariants,
        invariant_count = #invariants,
        excluded = excluded,
        unregistered = unregistered,
        missing = missing,
        unkeyed = unkeyed,
        status_mismatch = mismatch,
        refused = refusals,
    }
end

_G["centicolon-extract"] = function(arg)
    local out = extract(arg)
    expert.log_info("centicolon-extract:" .. json.encode(out))
    if #out.refused > 0 then
        for _, r in ipairs(out.refused) do
            expert.log_info("refused:centicolon-extract:" .. r)
        end
        return false
    end
    if out.obligation_count == 0 then
        expert.log_info("blocked:centicolon-extract:zero-population")
        return false
    end
    local ex = {}
    for k, v in pairs(out.excluded) do ex[#ex + 1] = k .. "=" .. v end
    table.sort(ex)
    expert.log_info(string.format(
        "ok:centicolon-extract:obligations=%d requirements=%d specs=%d invariants=%d excluded=%s unregistered=%d missing=%d unkeyed=%d population=%s",
        out.obligation_count, out.requirements, (function() local n = 0 for _ in pairs(out.specs_counted) do n = n + 1 end return n end)(),
        out.invariant_count, (#ex > 0) and table.concat(ex, ",") or "none",
        #out.unregistered, #out.missing, #out.unkeyed, out.population))
    return true
end
