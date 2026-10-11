-- @env TILLANDSIAS_INFERENCE_ENDPOINT TILLANDSIAS_INFERENCE_MODEL HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy
-- @trace order:1584-ik5v
--
-- check-local-expert-health.lua — PORTED from check-local-expert-health.sh
-- (carried obligation shell->lua, paid by 1584-ik5v): probe the local Ollama
-- inference endpoint.
--
-- Prints exactly one line matching (unchanged, byte for byte):
--   ^(ok:local-experts-healthy|degraded:local-experts[^;]*|down:local-experts[^;]*)$
-- Exit 0 on ok/degraded, 1 on down. degraded:/down: are emitted verbatim:
-- 1584-ik5v widened verdict.emit to accept them, because configure-ollama.sh and
-- the forge image's meta-orchestration skill read these exact lines.
--
-- The env family is TILLANDSIAS_INFERENCE_* with a CPU-floor model default
-- (the .sh's 2026-08-28 repair; lib-dev-env.sh's tier table and pipeline.rs
-- InferenceConfig agree).
--
-- SAME TOOLS AS THE .sh, ONE STEP EACH: curl for the two requests, jq for the
-- two reads. proc.run children start from a scrubbed environment, so the proxy
-- variables curl honours are forwarded explicitly; without them a forge whose
-- endpoint is reached through its proxy would answer differently from the .sh.

local ENDPOINT = env.get("TILLANDSIAS_INFERENCE_ENDPOINT") or "http://127.0.0.1:11434"
local MODEL = env.get("TILLANDSIAS_INFERENCE_MODEL") or "qwen2.5:0.5b"
if ENDPOINT == "" then ENDPOINT = "http://127.0.0.1:11434" end
if MODEL == "" then MODEL = "qwen2.5:0.5b" end

local PROXY = {}
for _, k in ipairs({ "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "no_proxy" }) do
    local v = env.get(k)
    if v ~= nil and v ~= "" then PROXY[k] = v end
end

local function curl(args, timeout_s)
    local argv = { "curl", "-sf", "--max-time", tostring(timeout_s) }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    return proc.run({ argv = argv, env = PROXY, timeout_ms = (timeout_s + 5) * 1000 })
end
local function ok(r) return r.status == "exited" and r.code == 0 end
-- jq over a body; "" on any failure, as the .sh's `|| echo ""`.
local function jq(filter, body)
    local r = proc.run({ argv = { "jq", "-r", filter }, stdin = body or "" })
    if not ok(r) then return "" end
    return r.stdout or ""
end

-- Is Ollama reachable?
if not ok(curl({ ENDPOINT .. "/api/tags" }, 3)) then
    verdict.emit("down:local-experts-ollama-unreachable", 1)
end

-- Is the model available? A fixed-string search of the listed names, as the
-- .sh's grep -qF.
local tags = curl({ ENDPOINT .. "/api/tags" }, 5)
local available = ok(tags) and jq(".models[].name // empty", tags.stdout) or ""
if not text.contains(available, MODEL) then
    verdict.emit("degraded:local-experts-model-missing:" .. MODEL, 0)
end

-- A quick inference.
local gen = curl({ ENDPOINT .. "/api/generate", "-d",
    "{\"model\":\"" .. MODEL .. "\",\"prompt\":\"Say OK\",\"stream\":false}" }, 10)
local response = ok(gen) and jq(".response // empty", gen.stdout) or ""
-- `$(...)` strips trailing newlines only, so strip exactly those.
if (response:gsub("\n+$", "")) == "" then
    verdict.emit("degraded:local-experts-inference-failed:" .. MODEL, 0)
end

verdict.emit("ok:local-experts-healthy", 0)
