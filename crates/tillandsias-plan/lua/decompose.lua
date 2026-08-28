-- decompose.lua — Adversarial query decomposition.
--
-- Given a natural-language query about the project, returns a table of
-- adversarial prompt variants. Each variant is an affirmative prompt
-- (LLMs generate positive assertions naturally), and the cross-validation
-- of multiple variants reduces hallucination skew per the Weak Law of
-- Large Numbers.
--
-- Consumer is unaware this happens — it's a transparent black box.
-- @trace order:920-pxg6

-- Query shape detection patterns.
local shape_detectors = {
    {
        name = "existence",
        test = function(q)
            local l = q:lower()
            return l:find("does") ~= nil
                or l:find("use[sd]?%s") ~= nil
                or l:find("have%s") ~= nil
                or l:find("implement") ~= nil
                or l:find("tell me about") ~= nil
                or l:find("^what is [^%s]+%s*$") ~= nil
                or l:find("describe") ~= nil
        end,
    },
    {
        name = "explanation",
        test = function(q)
            local l = q:lower()
            return l:find("how") ~= nil
                or l:find("explain") ~= nil
                or l:find("why") ~= nil
        end,
    },
    {
        name = "comparison",
        test = function(q)
            local l = q:lower()
            return l:find("compare") ~= nil
                or l:find("difference") ~= nil
                or l:find("versus") ~= nil
                or l:find(" vs ") ~= nil
        end,
    },
    {
        name = "alternatives",
        test = function(q)
            local l = q:lower()
            return l:find("alternative") ~= nil
                or l:find("instead") ~= nil
                or l:find("replace") ~= nil
        end,
    },
}

local function extract_entity(query)
    local quoted = query:match("[%\"']([^%\"']+)[%\"']")
    if quoted then return quoted end
    local after_prep = query:match("[Cc]ompare%s+(.-)%s+[Aa]nd%s+")
        or query:match("[Aa]bout%s+(.-)%s*$")
        or query:match("[Uu]sing%s+(.-)%s*$")
        or query:match("[Ww]ith%s+(.-)%s*$")
    if after_prep and #after_prep > 2 then return after_prep end
    local the_phrase = query:match("[Tt]he%s+([%w%s']+)%s*$")
        or query:match("[Aa]%s+([%w%s']+)%s*$")
    if the_phrase and #the_phrase > 2 then return the_phrase:match("^%s*(.-)%s*$") end
    local last = query:match("([%w%s']+)%s*$")
    if last and #last > 2 then return last:match("^%s*(.-)%s*$") end
    return query
end

local strategies = {}

function strategies.existence(query, entity)
    return {
        { prompt = query, kind = "original" },
        { prompt = "This project does not use " .. entity, kind = "negation" },
        { prompt = "Alternatives to " .. entity .. " in this project", kind = "alternative" },
        { prompt = "The opposite approach to " .. entity .. " in this project", kind = "opposite" },
        { prompt = "Side effects of using " .. entity .. " in this project", kind = "side_effects" },
        { prompt = "Side effects of NOT using " .. entity .. " in this project", kind = "side_effects_negation" },
    }
end

function strategies.explanation(query, entity)
    return {
        { prompt = query, kind = "original" },
        { prompt = "The opposite of " .. entity .. " in this project", kind = "opposite" },
        { prompt = "Why NOT to use " .. entity .. " in this project", kind = "negation" },
    }
end

function strategies.comparison(query, entity)
    return {
        { prompt = query, kind = "original" },
        { prompt = entity .. " is not used in this project", kind = "negation" },
        { prompt = "Alternatives to " .. entity .. " in this project", kind = "alternative" },
    }
end

function strategies.alternatives(query, entity)
    return {
        { prompt = query, kind = "original" },
        { prompt = entity .. " is the best approach for this project", kind = "affirmation" },
        { prompt = "Why NOT to use " .. entity .. " alternatives in this project", kind = "negation" },
    }
end

local function default_strategy(query, entity)
    return {
        { prompt = query, kind = "original" },
        { prompt = "This project does not use " .. entity, kind = "negation" },
        { prompt = "Alternatives to " .. entity .. " in this project", kind = "alternative" },
    }
end

-- Main decomposition function. Called by Rust via LuaRuntime::call_decompose.
function decompose(query)
    if not query or #query == 0 then
        return { { prompt = "", kind = "empty" } }
    end

    local shape = "default"
    for _, detector in ipairs(shape_detectors) do
        if detector.test(query) then
            shape = detector.name
            break
        end
    end

    local entity = extract_entity(query)
    local strategy = strategies[shape] or default_strategy
    local prompts = strategy(query, entity)

    expert.log_info(
        string.format(
            "decompose: shape=%s entity='%s' variants=%d",
            shape, entity, #prompts
        )
    )

    return prompts
end
