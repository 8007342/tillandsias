-- @env PATH
-- @trace order:2454-lhar, order:2455-lomp, spec:default-image
--
-- test-forge-pi-omp-harness.lua — the Pi and Oh My Pi lanes use ONLY the local
-- models Lemonade Server serves. Runs the REAL generators in
-- images/default/lib-local-models.sh against a stub Lemonade /models answer
-- (a file; no network):
--   1 PI-FILTER  models.json names one provider, lemonade, and only the
--                downloaded models labelled chat or tool-calling (no image,
--                audio, tts, transcription, embeddings or 3d model)
--   2 PI-SHAPE   openai-completions, a dummy key, contextWindow from
--                context_length, maxTokens = min(16384, ctx/4), the compat
--                flags; settings.json defaults to lemonade and a tool-calling
--                model, and enables lemonade/* only
--   3 PI-EMPTY   an answer with no usable chat model is refused, no file
--   4 OMP        models.yml has exactly the lemonade provider (auth none,
--                openai-models-list discovery, baseUrl from the env) and
--                config.yml disables every cloud provider, never lemonade
--   5 URL        a base URL that could inject YAML/JSON is refused
--   6 WIRED      the entrypoints call these generators, give each harness its
--                own PI_CODING_AGENT_DIR, set PI_OFFLINE / OTEL_SDK_DISABLED /
--                OMP_SKIP_SETUP, and omp is pinned by version and sha256
--   7 NO-CLOUD   no cloud model API host appears in the lane's files
--
-- Usage: tillandsias-plan script run scripts/lua/test-forge-pi-omp-harness.lua
-- Verdict: ok:forge-pi-omp-harness:7 arms | violation:forge-pi-omp-harness:<n>-failed

local NAME = "forge-pi-omp-harness"
local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.code ~= 0 or ROOT == "" then verdict.could_not_run(NAME, "git rev-parse --show-toplevel did not answer") end
local PLAN = require("common.fixture").plan_binary()
if PLAN == nil or PLAN == "" then verdict.could_not_run(NAME, "no plan binary to run lua/local-models-pi.lua with") end
local LIB = ROOT .. "/images/default/lib-local-models.sh"

local REL = "target/plan-scratch/pi-omp-harness-" .. tostring(time.now_ms())
local ABS = ROOT .. "/" .. REL
local passed, failed = 0, {}
local function arm(name, cond, got)
    if cond then passed = passed + 1; out.line("ok:   " .. name)
    else out.line("FAIL: " .. name .. " — got: " .. tostring(got)); failed[#failed + 1] = name end
end
local function rd(rel) local ok, s = pcall(fs.read, rel); return ok and s or nil end

fs.mkdir(REL)
-- A Lemonade answer in the shape `GET /api/v1/models` returns.
fs.write(REL .. "/models.json", json.encode({ data = {
    { id = "Qwen3-Coder-30B", downloaded = true, labels = { "chat", "tool-calling" }, context_length = 65536, recipe = "llamacpp" },
    { id = "Gemma-3-4b-it", downloaded = true, labels = { "chat", "vision" }, context_length = 8192, recipe = "llamacpp" },
    { id = "Not-Downloaded-Chat", downloaded = false, labels = { "chat" }, context_length = 32768 },
    { id = "nomic-embed", downloaded = true, labels = { "embeddings" } },
    { id = "SDXL-Turbo", downloaded = true, labels = { "image" } },
    { id = "Kokoro-tts", downloaded = true, labels = { "tts", "audio" } },
    { id = "Whisper-Base", downloaded = true, labels = { "audio", "transcription" } },
    { id = "Chat-But-Audio", downloaded = true, labels = { "chat", "audio" }, context_length = 4096 },
    { id = "Trellis-3d", downloaded = true, labels = { "3d" } },
} }))
fs.write(REL .. "/empty.json", json.encode({ data = {
    { id = "nomic-embed", downloaded = true, labels = { "embeddings" } },
    { id = "Chat-Not-Here", downloaded = false, labels = { "chat" } },
} }))
fs.write(REL .. "/drive.sh", table.concat({
    "#!/usr/bin/env bash",
    'lib="$1"; mode="$2"; shift 2',
    '. "$lib"',
    'case "$mode" in',
    '    (pi) lemonade_pi_config "$@" ;;',
    '    (omp) lemonade_omp_config "$@" ;;',
    '    (url) lemonade_base_url ;;',
    'esac',
}, "\n") .. "\n")

local BASE = "http://lemonade.test:13305/api/v1"
local function run(mode, args, url)
    local argv = { "env", "TILLANDSIAS_LEMONADE_URL=" .. (url or BASE), "TILLANDSIAS_PLAN_BIN=" .. PLAN, "bash", ABS .. "/drive.sh", LIB, mode }
    for _, a in ipairs(args or {}) do argv[#argv + 1] = a end
    return proc.run({ argv = argv, timeout_ms = 60000 })
end

-- 1/2 Pi
local r1 = run("pi", { ABS .. "/models.json", ABS .. "/pi" })
local okm, pim = pcall(json.parse, rd(REL .. "/pi/models.json") or "")
local oks, pis = pcall(json.parse, rd(REL .. "/pi/settings.json") or "")
if not okm or type(pim) ~= "table" then pim = {} end
if not oks or type(pis) ~= "table" then pis = {} end
local provs, ids = {}, {}
for k, _ in pairs(pim.providers or {}) do provs[#provs + 1] = k end
local lem = (pim.providers or {}).lemonade or {}
for _, m in ipairs(lem.models or {}) do ids[#ids + 1] = m.id end
table.sort(ids)
arm("1 PI-FILTER only the lemonade provider, only downloaded chat/tool-calling models",
    r1.code == 0 and #provs == 1 and provs[1] == "lemonade"
        and table.concat(ids, ",") == "Gemma-3-4b-it,Qwen3-Coder-30B",
    "code=" .. tostring(r1.code) .. " providers=" .. table.concat(provs, ",") .. " ids=" .. table.concat(ids, ",") .. " err=" .. (r1.stderr or ""))

local q, g
for _, m in ipairs(lem.models or {}) do
    if m.id == "Qwen3-Coder-30B" then q = m elseif m.id == "Gemma-3-4b-it" then g = m end
end
q = q or {}; g = g or {}
local en = pis.enabledModels or {}
arm("2 PI-SHAPE openai-completions, ctx and maxTokens, compat; settings default to lemonade and enable lemonade/* only",
    lem.api == "openai-completions" and lem.baseUrl == BASE and type(lem.apiKey) == "string" and lem.apiKey ~= ""
        and q.contextWindow == 65536 and q.maxTokens == 16384 and g.contextWindow == 8192 and g.maxTokens == 2048
        and (q.compat or {}).supportsDeveloperRole == false and (q.compat or {}).supportsStore == false
        and pis.defaultProvider == "lemonade" and pis.defaultModel == "Qwen3-Coder-30B"
        and #en == 1 and en[1] == "lemonade/*",
    json.encode(pim) .. " " .. json.encode(pis))

-- 3 nothing usable
local r3 = run("pi", { ABS .. "/empty.json", ABS .. "/pi-empty" })
arm("3 PI-EMPTY no usable local chat model is refused and writes no models.json",
    r3.code ~= 0 and rd(REL .. "/pi-empty/models.json") == nil
        and (r3.stderr or ""):find("refused:pi-config:no-local-chat-model", 1, true) ~= nil,
    "code=" .. tostring(r3.code) .. " err=" .. (r3.stderr or ""))

-- 4 omp
local r4 = run("omp", { ABS .. "/omp" })
local oky, my = pcall(yaml.parse, rd(REL .. "/omp/models.yml") or "")
local okc, cy = pcall(yaml.parse, rd(REL .. "/omp/config.yml") or "")
if not oky or type(my) ~= "table" then my = {} end
if not okc or type(cy) ~= "table" then cy = {} end
local oprov = {}
for k, _ in pairs(my.providers or {}) do oprov[#oprov + 1] = k end
local ol = (my.providers or {}).lemonade or {}
local disabled = {}
for _, p in ipairs(cy.disabledProviders or {}) do disabled[p] = true end
local CLOUD = { "anthropic", "openai", "openai-codex", "google", "google-vertex", "google-gemini-cli",
    "google-antigravity", "amazon-bedrock", "azure-openai-responses", "github-copilot", "openrouter",
    "xai", "mistral", "groq", "cerebras", "deepseek", "together", "fireworks", "huggingface", "cursor",
    "kimi-code", "moonshot", "zai", "minimax", "ollama-cloud", "vercel-ai-gateway", "cloudflare-ai-gateway",
    "gitlab-duo", "kiro", "perplexity", "nvidia", "litellm", "bifrost" }
local missing = {}
for _, p in ipairs(CLOUD) do if not disabled[p] then missing[#missing + 1] = p end end
arm("4 OMP only lemonade (auth none, openai-models-list, env baseUrl); every cloud provider disabled",
    r4.code == 0 and #oprov == 1 and oprov[1] == "lemonade" and ol.auth == "none"
        and ol.api == "openai-completions" and ol.baseUrl == BASE
        and (ol.discovery or {}).type == "openai-models-list"
        and #missing == 0 and not disabled["lemonade"],
    "providers=" .. table.concat(oprov, ",") .. " missing=" .. table.concat(missing, ",") .. " err=" .. (r4.stderr or ""))

-- 5 url
local r5 = run("url", {}, 'http://evil"\n  x: 1')
local r5b = run("url", {}, "file:///etc/passwd")
local r5c = run("url", {}, "")
arm("5 URL an injecting or non-http base URL is refused; the default is the enclave alias",
    r5.code ~= 0 and r5b.code ~= 0 and text.trim(r5c.stdout or "") == "http://lemonade:13305/api/v1",
    tostring(r5.code) .. "/" .. tostring(r5b.code) .. "/" .. (r5c.stdout or ""))

-- 6 wired
local epi = rd("images/default/entrypoint-forge-pi.sh") or ""
local eomp = rd("images/default/entrypoint-forge-omp.sh") or ""
local lc = rd("images/default/lib-common.sh") or ""
local cf = rd("images/default/Containerfile") or ""
local pi_dir = epi:match('export PI_CODING_AGENT_DIR="([^"]+)"')
local omp_dir = eomp:match('export PI_CODING_AGENT_DIR="([^"]+)"')
local omp_sha = lc:match('OMP_LINUX_X64_SHA256="(%x+)"') or ""
arm("6 WIRED entrypoints call the generators, own agent dirs, offline env, omp pinned by version and sha256",
    epi:find("lemonade_pi_config", 1, true) and eomp:find("lemonade_omp_config", 1, true)
        and epi:find("export PI_OFFLINE=1", 1, true)
        and eomp:find("export OTEL_SDK_DISABLED=true", 1, true) and eomp:find("export OMP_SKIP_SETUP=1", 1, true)
        and pi_dir and omp_dir and pi_dir ~= omp_dir
        and #omp_sha == 64 and lc:find('OMP_VERSION="[0-9]+%.[0-9]+%.[0-9]+"')
        and lc:find('PI_NPM_INTEGRITY="sha512-', 1, true)
        and cf:find("lib-local-models.sh", 1, true) and cf:find("entrypoint-forge-pi.sh", 1, true)
        and cf:find("entrypoint-forge-omp.sh", 1, true),
    "pi_dir=" .. tostring(pi_dir) .. " omp_dir=" .. tostring(omp_dir) .. " sha=" .. omp_sha)

-- 7 no cloud host
local libsrc = rd("images/default/lib-local-models.sh") or ""
local hits = {}
for _, h in ipairs({ "api.openai.com", "api.anthropic.com", "generativelanguage.googleapis.com",
    "openrouter.ai", "api.x.ai", "api.mistral.ai", "api.groq.com", "api.githubcopilot.com" }) do
    for fname, src in pairs({ lib = libsrc, pi = epi, omp = eomp }) do
        if src:find(h, 1, true) then hits[#hits + 1] = fname .. ":" .. h end
    end
end
arm("7 NO-CLOUD no cloud model API host in the lane's files", libsrc ~= "" and #hits == 0, table.concat(hits, ","))

proc.run({ argv = { "rm", "-rf", ABS } })
if #failed > 0 then verdict.emit("violation:" .. NAME .. ":" .. #failed .. "-failed", 1) end
verdict.emit("ok:" .. NAME .. ":" .. passed .. " arms", 0)
