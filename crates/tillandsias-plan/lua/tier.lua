-- tier.lua — Latency tier classification and budget enforcement.
--
-- Classifies queries into IMMEDIATE/QUICK/FINE/NON_USABLE based on
-- query complexity and host capability.
-- @trace order:920-pxg6
-- @trace spec:inference-policy-router

-- Latency tier definitions (milliseconds)
TIER_BUDGETS = {
    immediate = 500,
    quick = 3000,
    fine = 12000,
    non_usable = 15000,
}

-- Maximum adversarial variants per tier
TIER_MAX_VARIANTS = {
    immediate = 1,
    quick = 3,
    fine = 6,
    non_usable = 0,
}

-- All three servable tiers are REACHABLE (920-pxg6). The previous form's
-- first branch (short -> quick) was subsumed by its second, so "immediate"
-- was only reachable for the empty query no caller ever sends — one tier
-- wearing three names. Short queries now classify immediate: their budget
-- is the deterministic floor (synthesis inside 500ms is a fantasy on the
-- CPU tier), so the pipeline serves them the cited retrieval-only digest.
-- "non_usable" stays a budget-overrun verdict (LatencyTier::from_ms), never
-- a classification.
function tier_classify(query)
    if not query or #query == 0 then
        return "immediate"
    end
    local len = #query
    local word_count = select(2, query:gsub("%S+", ""))
    if len < 30 or word_count < 5 then
        return "immediate"
    end
    if len < 100 or word_count < 15 then
        return "quick"
    end
    return "fine"
end

function tier_max_variants(tier_name)
    return TIER_MAX_VARIANTS[tier_name] or TIER_MAX_VARIANTS.fine
end

function tier_budget_ms(tier_name)
    return TIER_BUDGETS[tier_name] or TIER_BUDGETS.fine
end

function tier_trim(prompts, tier_name)
    local max = tier_max_variants(tier_name)
    if #prompts <= max then
        return prompts
    end
    local trimmed = {}
    -- Always keep the original prompt
    for _, p in ipairs(prompts) do
        if p.kind == "original" then
            table.insert(trimmed, p)
            break
        end
    end
    -- Fill remaining slots with highest-priority variants
    local priority = { "negation", "alternative", "opposite", "side_effects",
                       "side_effects_negation", "affirmation" }
    for _, kind in ipairs(priority) do
        if #trimmed >= max then break end
        for _, p in ipairs(prompts) do
            if p.kind == kind then
                table.insert(trimmed, p)
                break
            end
        end
    end
    return trimmed
end
