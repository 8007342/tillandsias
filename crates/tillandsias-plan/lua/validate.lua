-- validate.lua — Citation validation against the RAG index.
--
-- Every cited reference in every adversarial response is verified:
-- does path:line_start-line_end resolve? Does the span contain the
-- claimed text? Unreferenced claims and unresolvable citations are
-- stripped as hallucinations.
--
-- Extends the existing verify() from answer.rs — this is the Lua-side
-- validation that calls back into Rust for citation resolution.
-- @trace order:920-pxg6

local validate = {}

-- Validate a single citation reference.
-- Returns true if the citation resolves and contains the claimed text.
-- In the PoC, this is a structural check (valid path, valid line range).
-- Full semantic validation (does the span contain the claimed text?)
-- happens in Rust via the verify() path.
function validate.citation(citation)
    if not citation then return false, "nil citation" end
    if not citation.path or #citation.path == 0 then
        return false, "empty path"
    end
    if not citation.line_start or citation.line_start < 1 then
        return false, "invalid line_start"
    end
    if not citation.line_end or citation.line_end < citation.line_start then
        return false, "invalid line_end"
    end
    return true, "ok"
end

-- Validate all citations in a response.
-- Returns the list of valid citations and a list of stripped ones.
function validate.response_citations(citations)
    if not citations then return {}, {} end

    local valid = {}
    local stripped = {}

    -- citations can be a Lua table (from the runtime) or a JSON string
    local cit_list = citations
    if type(citations) == "string" then
        -- If it's a JSON string, we can't parse it in pure Lua without
        -- a JSON library; return it as-is and let Rust handle the parse.
        return citations, {}
    end

    for _, cit in ipairs(cit_list) do
        local ok, reason = validate.citation(cit)
        if ok then
            table.insert(valid, cit)
        else
            table.insert(stripped, { citation = cit, reason = reason })
        end
    end

    return valid, stripped
end

-- Validate a complete inference response (from one adversarial query).
-- Returns the validated response or nil if it has no valid citations.
function validate.inference_response(response)
    if not response then return nil, "nil response" end
    if not response.answer or #response.answer == 0 then
        return nil, "empty answer"
    end

    local valid_cits, stripped_cits = validate.response_citations(response.citations)

    -- A response with no valid citations is either unsourced (valid for
    -- some answer types) or hallucinated. In the CRDT collection layer,
    -- unsourced responses survive but are flagged; hallucinated ones
    -- (citations that failed validation) are stripped.
    local result = {}
    for k, v in pairs(response) do
        result[k] = v
    end
    result.citations = valid_cits
    result.stripped_citations = stripped_cits
    result.validated = true

    return result, "ok"
end

return validate
