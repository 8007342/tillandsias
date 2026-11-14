-- @trace spec:inference-container, spec:async-inference-launch, order:2049-y7k8
-- @class observing
--
-- inference-state.lua — the body of images/default/lib-inference-state.sh,
-- run by `tillandsias-plan script run --helper` (openspec change
-- forge-lua-helpers D3.1). The .sh keeps its function names, its grammar and
-- every caller; only the probe and the parse moved here, so the old
-- `tr | sed | sort -u` chain and its forks are gone.
--
-- Argument: the endpoint (default http://inference:11434).
-- Output, five lines in this order, never an empty line:
--   1 state    ready | not-ready
--   2 models   <N>
--   3 warm     <csv> | -
--   4 reason   <name> | -
--   5 status   the human string, pinned in lib-inference-state.sh
--
-- Reason vocabulary is the .sh's closed set (no-models, endpoint-unreachable,
-- endpoint-timeout, endpoint-http-error, probe-tool-missing, probe-error-<n>).
--
-- Environment (2029-39bt): curl runs from the runner's base environment, with
-- no HTTP(S)_PROXY. The endpoint is an enclave sibling, which the forge
-- already reaches direct: its no_proxy lists `inference` (headless
-- main.rs no_proxy), so this is the route the shell curl took too.

local endpoint = arg[1]
if not endpoint or endpoint == "" then endpoint = "http://inference:11434" end

local UNREACHABLE_HINT = " — if the engine refused its payload: `podman logs tillandsias-inference | grep reason=engine-`"
local NO_MODELS = "NOT-READY (no-models: endpoint is serving but no model is cached — preload pending, a lazy/off preload policy, or a failed pull. THESE ARE DIFFERENT FAULTS: run `podman logs tillandsias-inference | grep reason=pull-failed` — a `reason=pull-failed-tls-untrusted` line means the enclave CA is not trusted by the engine, NOT an empty cache (order 525))"

local function emit(state, models, warm, reason, status)
    print(state)
    print(tostring(models))
    print(warm)
    print(reason)
    print(status)
end

local r = proc.run{ argv = { "curl", "-fsS", "--max-time", "1", endpoint .. "/api/tags" }, timeout_ms = 5000 }

if r.status == "spawn_failed" then
    emit("not-ready", 0, "-", "probe-tool-missing",
        "NOT-READY (probe-tool-missing: curl is absent from this image)")
    return
end

-- The shell captured `2>&1` and $( ) strips trailing newlines.
local captured = ((r.stdout or "") .. (r.stderr or "")):gsub("\n+$", "")
local rc = (r.status == "exited" and r.code) or 28 -- a runner-side timeout reads as curl's own

if rc ~= 0 then
    local reason
    if rc == 6 or rc == 7 then reason = "endpoint-unreachable"
    elseif rc == 28 then reason = "endpoint-timeout"
    elseif rc == 22 then reason = "endpoint-http-error"
    else reason = "probe-error-" .. tostring(rc) end
    local detail = captured ~= "" and captured or ("curl exit " .. tostring(rc))
    local status = "NOT-READY (" .. reason .. ": " .. detail .. ")"
    if reason == "endpoint-unreachable" then
        status = status:gsub("%)$", "") .. UNREACHABLE_HINT .. ")"
    end
    emit("not-ready", 0, "-", reason, status)
    return
end

-- /api/tags: { "models": [ { "name": ... }, ... ] }. A body that is not that
-- shape has no names, which is no-models, exactly as the sed capture read it.
local names, seen = {}, {}
local ok, doc = pcall(json.parse, r.stdout or "")
if ok and type(doc) == "table" and type(doc.models) == "table" then
    for _, m in ipairs(doc.models) do
        local n = type(m) == "table" and m.name or nil
        if type(n) == "string" and n ~= "" and not n:find("[%s\"]") and not seen[n] then
            seen[n] = true
            names[#names + 1] = n
        end
    end
end
table.sort(names) -- byte order, as `sort -u` under LC_ALL=C

if #names > 0 then
    local warm = table.concat(names, ",")
    emit("ready", #names, warm, "-", "READY (models=" .. #names .. ", warm=" .. warm .. ")")
else
    emit("not-ready", 0, "-", "no-models", NO_MODELS)
end
