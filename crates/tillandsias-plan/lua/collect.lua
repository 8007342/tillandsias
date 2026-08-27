-- collect.lua — CRDT collection of validated adversarial responses.
--
-- ALL validated responses are kept. No confidence threshold, no merging,
-- no reduction. Each response carries WHY/AFFORDANCES/WHY_NOT metadata
-- so the consumer has full agency to pick the best answer.
--
-- The collection is CRDT: commutative (order doesn't matter), idempotent
-- (re-adding the same response is a no-op), and additive (never removes).
-- @trace order:902-5bf9

local function deduplicate(responses)
    local seen = {}
    local result = {}
    for _, resp in ipairs(responses) do
        local key = resp.answer:match("^%s*(.-)%s*$"):lower()
        if not seen[key] then
            seen[key] = true
            table.insert(result, resp)
        end
    end
    return result
end

-- Main collection function. Called by Rust via LuaRuntime::call_collect.
-- Input: a Lua table of raw inference responses (JSON parsed by Rust).
-- Output: a table of validated responses with provenance.
function collect(responses)
    if type(responses) ~= "table" then
        expert.log_info("collect: expected table, got " .. type(responses))
        return {}
    end

    local validated = {}
    local stripped = {}

    for _, resp in ipairs(responses) do
        if resp.validated then
            table.insert(validated, {
                answer = resp.answer,
                citations = resp.citations or {},
                confidence = resp.confidence or 0.0,
                query_kind = resp.query_kind or "unknown",
                source_prompt = resp.source_prompt or "",
                why = resp.why or "",
                affordances = resp.affordances or {},
                why_not = resp.why_not or "",
            })
        else
            table.insert(stripped, resp)
        end
    end

    validated = deduplicate(validated)

    expert.log_info(
        string.format(
            "collect: validated=%d stripped=%d deduped=%d",
            #responses, #stripped, #validated
        )
    )

    return validated
end
