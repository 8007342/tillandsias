-- centicolon-grade-static.lua — the Cacheable half of the CentiColon grader (order 1395-88tp).
-- @trace order:1395-88tp
--
-- Pure over repo bytes: fs.read, yaml.parse, json.encode, hash.sha256. No shell,
-- no clock, no fs.list, no `next`.
--
--   tillandsias-plan predicate scripts/lua/centicolon-grade-static.lua --class cacheable \
--       --arg '<obligations.json>|<litmus-file>,<litmus-file>,...'
--
-- <obligations.json> is the extractor's (1395-n7qd) canonical JSON, written by
-- the caller to a path inside the repository root; the litmus file list comes
-- from the caller for the same reason the extractor's spec list does (the
-- Cacheable class has no fs.list), and it is part of the cache key.
--
-- RUNGS DECIDED HERE (design §4.2, rules reused, not re-decided):
--   declared  — the obligation is in the extractor's output.
--   traced    — some litmus step names its req-id with a `requirement:` key
--               (file-level applies to every step; step-level adds to it).
-- and, per referencing step, the three PURE facts positively_tested needs:
--   enforced  — the step block has an assert KEY (census-litmus-step-
--               enforcement.sh's rule: assert_exit, assert_output_contains,
--               assert_output_matches, assert_output_nonempty, success_pattern)
--   reachable — the file's name is bound in litmus-bindings.yaml under a spec
--               the file itself declares (test-litmus-binding-truth.sh), its
--               phase is not retired, and it is not in unbound-grandfathered.txt
--   tier      — pre-build (phase pre-build, size instant|quick) or release
--               (any other non-retired phase); otherwise untiered
-- A step with all three is a CANDIDATE; the Observing half
-- (centicolon-grade-observed.lua) promotes it only on a green run record whose
-- digest matches this file's bytes. Existence earns traced, never more.
--
-- DIGEST: sha256 of the litmus file's bytes, the same value run-litmus-test.sh
-- writes into its per-test record, so a record dies when the file changes.
--
-- REFUSED BY NAME: a `requirement:` value that names no req-id the extractor
-- emitted (violation:centicolon-requirement-unresolved). Zero resolved keys over
-- a non-empty litmus corpus is also refused, never ok:0 — but the JSON is still
-- emitted, so an advisory consumer can print R while the refusal stands.

local ASSERT_KEYS = {
    assert_exit = true, assert_output_contains = true, assert_output_matches = true,
    assert_output_nonempty = true, success_pattern = true,
}

local function as_list(v)
    if type(v) == "string" then return { v } end
    if type(v) == "table" then
        local out = {}
        for _, x in ipairs(v) do if type(x) == "string" then out[#out + 1] = x end end
        return out
    end
    return {}
end

local function split(s, sep)
    local out = {}
    for item in (s or ""):gmatch("[^" .. sep .. "]+") do
        item = item:gsub("^%s+", ""):gsub("%s+$", "")
        if item ~= "" then out[#out + 1] = item end
    end
    return out
end

-- Every table in the document carrying a string `step` key, in document order.
local function collect_steps(node, out)
    if type(node) ~= "table" then return end
    if type(node.step) == "string" then out[#out + 1] = node end
    for _, v in ipairs(node) do collect_steps(v, out) end
    for k, v in pairs(node) do
        if type(k) ~= "number" and type(v) == "table" then collect_steps(v, out) end
    end
end

local function enforced(step)
    for k in pairs(step) do if ASSERT_KEYS[k] then return true end end
    return false
end

local function tier_of(doc)
    local phase, size = doc.phase, doc.size
    if phase == "retired" then return "retired" end
    if phase == "pre-build" then
        if size == "instant" or size == "quick" then return "pre-build" end
        return "untiered"
    end
    if type(phase) == "string" and phase ~= "" then return "release" end
    return "untiered"
end

local function grade(arg)
    local parts = split(arg, "|")
    local ob_path = parts[1]
    if not ob_path then error("usage: --arg '<obligations.json>|<litmus files>'") end
    local ext = json.parse(fs.read(ob_path))
    local files = split(parts[2] or "", ",")
    table.sort(files)

    local reg = yaml.parse(fs.read("openspec/litmus-bindings.yaml")) or {}
    local bound = {}   -- spec_id -> set of litmus names
    for _, s in ipairs(reg.specs or {}) do
        if type(s) == "table" and type(s.spec_id) == "string" then
            local set = {}
            for _, n in ipairs(as_list(s.litmus_tests)) do set[n] = true end
            bound[s.spec_id] = set
        end
    end
    local grandfathered = {}
    local okg, gtext = pcall(fs.read, "openspec/litmus-tests/unbound-grandfathered.txt")
    if okg then
        for line in (gtext .. "\n"):gmatch("([^\n]*)\n") do
            local n = line:match("^%s*(litmus:[%w%-_%.]+)")
            if n then grandfathered[n] = true end
        end
    end

    -- req-id -> obligation rows
    local by_req, known = {}, {}
    for _, o in ipairs(ext.obligations or {}) do
        if o.req_id then
            known[o.req_id] = true
            by_req[o.req_id] = by_req[o.req_id] or {}
            table.insert(by_req[o.req_id], o)
        end
    end

    local refs = {}           -- req-id -> list of step references
    local unresolved, parse_errors = {}, {}
    local resolved_keys, key_count = 0, 0
    for _, path in ipairs(files) do
        local okr, text = pcall(fs.read, path)
        local okp, doc = false, nil
        if okr then okp, doc = pcall(yaml.parse, text) end
        if not (okr and okp and type(doc) == "table") then
            parse_errors[#parse_errors + 1] = path
        else
            local name = type(doc.name) == "string" and doc.name or ("file:" .. path)
            local digest = hash.sha256(text)
            local specs = as_list(doc.spec)
            local is_bound = false
            for _, sp in ipairs(specs) do
                if bound[sp] and bound[sp][name] then is_bound = true end
            end
            local tier = tier_of(doc)
            local reach
            if doc.phase == "retired" then reach = "inert:retired"
            elseif grandfathered[name] then reach = "inert:grandfathered"
            elseif not is_bound then reach = "inert:unbound"
            else reach = "reachable" end

            local file_reqs = as_list(doc.requirement)
            local steps = {}
            collect_steps(doc, steps)
            for idx, st in ipairs(steps) do
                local reqs = {}
                for _, r in ipairs(file_reqs) do reqs[#reqs + 1] = r end
                for _, r in ipairs(as_list(st.requirement)) do reqs[#reqs + 1] = r end
                for _, r in ipairs(reqs) do
                    key_count = key_count + 1
                    if known[r] then
                        resolved_keys = resolved_keys + 1
                        refs[r] = refs[r] or {}
                        table.insert(refs[r], {
                            litmus = name, file = path, digest = digest, step = idx,
                            step_name = st.step, enforced = enforced(st),
                            reach = reach, tier = tier,
                        })
                    else
                        unresolved[#unresolved + 1] = path .. ":" .. idx .. ":" .. r
                    end
                end
            end
        end
    end
    table.sort(unresolved); table.sort(parse_errors)

    local out_obs = {}
    for _, o in ipairs(ext.obligations or {}) do
        local cands = refs[o.req_id] or {}
        local row = { id = o.id, req_id = o.req_id, spec = o.spec, spec_digest = o.spec_digest, candidates = {} }
        if #cands == 0 then
            row.state = "declared"; row.reason = "no-binding"
        else
            row.state = "traced"
            local best = nil
            for _, c in ipairs(cands) do
                local why
                if not c.enforced then why = "unenforced"
                elseif c.reach ~= "reachable" then why = c.reach
                elseif c.tier ~= "pre-build" and c.tier ~= "release" then why = "untiered"
                else why = "candidate" end
                c.why = why
                if why == "candidate" then row.candidates[#row.candidates + 1] = c end
                if not best or why == "candidate" then best = why end
            end
            row.reason = best
        end
        out_obs[#out_obs + 1] = row
    end
    table.sort(out_obs, function(a, b) return a.id < b.id end)

    local refused = {}
    for _, u in ipairs(unresolved) do
        refused[#refused + 1] = "violation:centicolon-requirement-unresolved:" .. u
    end
    if #files > 0 and resolved_keys == 0 then
        refused[#refused + 1] = "zero-resolved-requirement-keys:files=" .. #files
    end

    return {
        schema = "centicolon-grade-static/1",
        litmus_files = #files,
        requirement_keys = key_count,
        resolved_keys = resolved_keys,
        parse_errors = parse_errors,
        obligations = out_obs,
        refused = refused,
    }
end

_G["centicolon-grade-static"] = function(arg)
    local out = grade(arg)
    expert.log_info("centicolon-grade-static:" .. json.encode(out))
    local n = { declared = 0, traced = 0, candidate = 0 }
    for _, o in ipairs(out.obligations) do
        n[o.state] = n[o.state] + 1
        if #o.candidates > 0 then n.candidate = n.candidate + 1 end
    end
    if #out.refused > 0 then
        for _, r in ipairs(out.refused) do expert.log_info("refused:centicolon-grade-static:" .. r) end
        return false
    end
    expert.log_info(string.format(
        "ok:centicolon-grade-static:obligations=%d declared=%d traced=%d candidates=%d resolved_keys=%d files=%d",
        #out.obligations, n.declared, n.traced, n.candidate, out.resolved_keys, out.litmus_files))
    return true
end
