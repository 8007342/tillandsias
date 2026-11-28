-- @trace order:2454-lhar, spec:default-image
-- @class observing
-- @env LEMONADE_MODELS_ANSWER PI_SETTINGS_FILE
-- @read-env LEMONADE_MODELS_ANSWER PI_SETTINGS_FILE
--
-- local-models-pi.lua — the body of lemonade_pi_config (images/default/
-- lib-local-models.sh), run by `tillandsias-plan script run --helper`
-- (openspec forge-lua-helpers). It replaces the jq filters: new forge code
-- carries no jq (coordinator ruling 2026-11-28).
--
-- Argument 1, the mode:
--   models    print pi's models.json for the Lemonade answer in
--             $LEMONADE_MODELS_ANSWER, with baseUrl = argument 2
--   settings  print settings.json: $PI_SETTINGS_FILE (when it exists) with
--             defaultProvider, defaultModel and enabledModels set
-- Exit 3 with `refused:pi-config:no-local-chat-model` on stderr when the answer
-- lists no downloaded chat or tool-calling model; 2 on a bad call.
--
-- Pi has no model discovery, so its list is generated from the answer.
-- Only downloaded models labelled chat or tool-calling are kept, and none
-- labelled for another modality.

local OTHER = { image = true, audio = true, tts = true, transcription = true,
    embeddings = true, embedding = true, ["3d"] = true, reranking = true }

local function has(labels, want)
    for _, l in ipairs(labels or {}) do
        if l == want then return true end
    end
    return false
end

local function chat_models(answer)
    local out = {}
    for _, m in ipairs((answer and answer.data) or {}) do
        local labels = m.labels or {}
        local chat = has(labels, "chat") or has(labels, "tool-calling")
        local other = false
        for _, l in ipairs(labels) do
            if OTHER[l] then other = true end
        end
        if m.downloaded == true and chat and not other and type(m.id) == "string" then
            out[#out + 1] = m
        end
    end
    return out
end

-- A helper may not call verdict.*: a refusal is the ONLY line on stdout, and
-- lemonade_pi_config turns a `refused:` first line into its error.
local function die(_, msg)
    print(msg)
    error("__refused__", 0)
end

local function main()
local mode = arg[1]
local answer_path = env.get("LEMONADE_MODELS_ANSWER") or ""
if mode ~= "models" and mode ~= "settings" then
    die(2, "refused:pi-config:usage (local-models-pi.lua models <base-url> | settings)")
end
if answer_path == "" then die(2, "refused:pi-config:no-answer (LEMONADE_MODELS_ANSWER unset)") end

local ok, raw = pcall(fs.read, answer_path)
if not ok or not raw then die(2, "refused:pi-config:answer-unreadable:" .. answer_path) end
local pok, answer = pcall(json.parse, raw)
if not pok then die(2, "refused:pi-config:answer-not-json") end

local models = chat_models(answer)
if #models == 0 then
    die(3, "refused:pi-config:no-local-chat-model (Lemonade lists no downloaded chat or tool-calling model)")
end

if mode == "models" then
    local base = arg[2]
    if not base or base == "" then die(2, "refused:pi-config:usage (local-models-pi.lua models <base-url>)") end
    local list = {}
    for _, m in ipairs(models) do
        local ctx = tonumber(m.context_length) or 8192
        if ctx < 1024 then ctx = 1024 end
        local input = { "text" }
        if has(m.labels, "vision") then input[#input + 1] = "image" end
        list[#list + 1] = {
            id = m.id,
            name = m.id,
            contextWindow = ctx,
            maxTokens = math.min(16384, math.floor(ctx / 4)),
            reasoning = has(m.labels, "reasoning"),
            input = json.array(input),
            compat = { supportsDeveloperRole = false, supportsStore = false },
        }
    end
    print(json.encode({
        providers = {
            lemonade = {
                baseUrl = base,
                api = "openai-completions",
                apiKey = "lemonade-local",
                models = json.array(list),
            },
        },
    }))
else
    -- The default prefers a model that can call tools.
    local default = models[1].id
    for _, m in ipairs(models) do
        if has(m.labels, "tool-calling") then default = m.id; break end
    end
    local settings = {}
    local spath = env.get("PI_SETTINGS_FILE") or ""
    if spath ~= "" then
        local rok, sraw = pcall(fs.read, spath)
        if rok and sraw and sraw:match("%S") then
            local jok, parsed = pcall(json.parse, sraw)
            if jok and type(parsed) == "table" then settings = parsed end
        end
    end
    settings.defaultProvider = "lemonade"
    settings.defaultModel = default
    settings.enabledModels = json.array({ "lemonade/*" })
    print(json.encode(settings))
end
end

local done, err = pcall(main)
if not done and err ~= "__refused__" then error(err, 0) end
