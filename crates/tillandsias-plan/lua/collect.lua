-- collect.lua — first-wins dedup of validated adversarial responses.
--
-- ALL validated responses are kept. No confidence threshold, no merging,
-- no reduction. Each response carries WHY/AFFORDANCES/WHY_NOT metadata
-- so the consumer has full agency to pick the best answer.
--
-- This is a SEEN-SET DEDUP, not a CRDT — the earlier header's CRDT claim
-- (commutativity in particular) was false: first-wins keeps whichever
-- duplicate arrives first, so order matters. Named honestly per the
-- 687eb6d57 facade audit. Idempotent re-adds and never-removes do hold.
-- @trace order:920-pxg6

local function deduplicate(responses)
    local seen = {}
    local result = {}
    for _, resp in ipairs(responses) do
        -- A nil or non-string answer used to CRASH the whole collection
        -- ("attempt to index a nil value") and with it the request that
        -- carried five good responses beside one bad one (920-pxg6). A
        -- response with no answer text is dropped, not fatal.
        if type(resp.answer) == "string" then
            local key = resp.answer:match("^%s*(.-)%s*$"):lower()
            if not seen[key] then
                seen[key] = true
                table.insert(result, resp)
            end
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
        if resp.validated and type(resp.answer) == "string" and #resp.answer > 0 then
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
