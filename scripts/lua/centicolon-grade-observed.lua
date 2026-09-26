-- centicolon-grade-observed.lua — the Observing half of the CentiColon grader (order 1395-88tp).
-- @trace order:1395-88tp
--
-- OBSERVING, never cached: its verdict depends on a run log, not on repo bytes
-- alone. It reads two files the caller places inside the repository root:
--
--   tillandsias-plan predicate scripts/lua/centicolon-grade-observed.lua --class observing \
--       --arg '<static.json>|<results.jsonl>'
--
-- <static.json> is centicolon-grade-static.lua's JSON; <results.jsonl> is the
-- per-test litmus results stream (run-litmus-test.sh -> cycle-metrics.sh
-- --emit-timing-batch: {"step":"litmus:<name>","status":"pass|fail|skip",
-- "digest":"<sha256 of the litmus file>","regime":…,"spec":…,"spec_digest":…,
-- "host":…,"ts":…}).
--
-- positively_tested (design §4.2 fact 4): a CANDIDATE step (enforced, reachable,
-- tiered — decided by the static half) whose litmus file has a results record
-- with the SAME digest, and the LATEST such record is `pass`. A record for other
-- bytes counts for nothing; a later `fail` for the same bytes un-earns it; a
-- `skip` earns nothing. Everything below the rung keeps its reason, so R is
-- printed with its residue, never as a bare number.

-- Every LIST field is built with json.array() so an empty list encodes as []
-- and never as {} (1398-3qiz). The fallback keeps an older binary working.
local A = json.array or function(t) return t or {} end

local function split(s, sep)
    local out = {}
    for item in (s or ""):gmatch("[^" .. sep .. "]+") do out[#out + 1] = item end
    return out
end

local function norm_name(n)
    if n:sub(1, 7) == "litmus:" then return n end
    return "litmus:" .. n
end

local function observe(arg)
    local parts = split(arg, "|")
    local st = json.parse(fs.read(parts[1]))
    -- latest[name][digest] = {ts, status, host, seq}
    local latest, records = {}, 0
    local okr, text = pcall(fs.read, parts[2] or "")
    if okr then
        local seq = 0
        for line in (text .. "\n"):gmatch("([^\n]*)\n") do
            if line:match("^%s*{") then
                local okd, r = pcall(json.parse, line)
                if okd and type(r) == "table" and type(r.step) == "string"
                    and r.step:sub(1, 7) == "litmus:" and type(r.digest) == "string" then
                    seq = seq + 1; records = records + 1
                    local by = latest[r.step] or {}
                    local prev = by[r.digest]
                    local ts = tostring(r.ts or "")
                    if not prev or ts > prev.ts or (ts == prev.ts and seq > prev.seq) then
                        by[r.digest] = { ts = ts, status = r.status, host = r.host, seq = seq,
                                         regime = r.regime, spec = r.spec, spec_digest = r.spec_digest }
                    end
                    latest[r.step] = by
                end
            end
        end
    end

    local hist = { declared = 0, traced = 0, positively_tested = 0 }
    local reasons, obs = {}, A()
    for _, o in ipairs(st.obligations or {}) do
        local state, reason, by_host, regime = o.state, o.reason, nil, nil
        if #(o.candidates or {}) > 0 then
            reason = "unrun"
            for _, c in ipairs(o.candidates) do
                local rec = (latest[norm_name(c.litmus)] or {})[c.digest]
                -- A run under the obligation's OWN spec binds that spec's bytes
                -- too: a green record for an older spec.md earns nothing.
                local spec_moved = rec and rec.spec == o.spec and type(rec.spec_digest) == "string"
                    and rec.spec_digest ~= o.spec_digest
                if spec_moved then
                    if reason ~= "failed" then reason = "spec-changed" end
                elseif rec and rec.status == "pass" then
                    state = "positively_tested"; reason = "green"; by_host = rec.host
                    regime = rec.regime
                    break
                elseif rec and rec.status == "fail" then
                    reason = "failed"
                elseif rec and reason ~= "failed" then
                    reason = "skipped"
                end
            end
        end
        hist[state] = hist[state] + 1
        if state ~= "positively_tested" then reasons[reason] = (reasons[reason] or 0) + 1 end
        obs[#obs + 1] = { id = o.id, req_id = o.req_id, spec = o.spec, state = state,
                          reason = reason, host = by_host, regime = regime }
    end
    local denominator = #obs
    return {
        schema = "centicolon-grade-observed/1",
        records = records,
        denominator = denominator,
        satisfied = hist.positively_tested,
        R = denominator - hist.positively_tested,
        histogram = hist,
        residue_reasons = reasons,
        obligations = obs,
        static_refused = st.refused or A(),
    }
end

_G["centicolon-grade-observed"] = function(arg)
    local out = observe(arg)
    expert.log_info("centicolon-grade-observed:" .. json.encode(out))
    expert.log_info(string.format(
        "ok:centicolon-grade-observed:R=%d satisfied=%d denominator=%d declared=%d traced=%d positively_tested=%d records=%d",
        out.R, out.satisfied, out.denominator, out.histogram.declared, out.histogram.traced,
        out.histogram.positively_tested, out.records))
    return true
end
