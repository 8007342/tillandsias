-- @trace order:1653-77bt
-- bench-ollama.lua — prefill/decode tokens/sec for one model on an ollama endpoint.
-- Usage: tillandsias-plan script run bench-ollama.lua -- <host:port> <model> <runs>
local HOSTPORT, MODEL, RUNS = arg[1] or "127.0.0.1:11500", arg[2] or "qwen2.5:3b", tonumber(arg[3] or "5")

local filler = {}
for i = 1, 60 do
    filler[#filler + 1] = "Sentence " .. i .. " describes a tillandsia that grows on a branch without soil."
end
local BODY = table.concat(filler, " ") .. " Summarise the passage above in detail."

local function generate(prefix, keep_alive)
    local req = json.encode({
        model = MODEL, prompt = prefix .. " " .. BODY, stream = false, raw = false,
        keep_alive = keep_alive,
        options = { temperature = 0, seed = 42, num_predict = 128, num_ctx = 4096 },
    })
    local t0 = time.now_ms and time.now_ms() or nil
    local r = proc.run({ argv = { "curl", "-s", "-X", "POST", "http://" .. HOSTPORT .. "/api/generate", "-d", req },
        timeout_ms = 600000 })
    if r.code ~= 0 then verdict.could_not_run("bench-ollama", "curl rc=" .. tostring(r.code)) end
    return json.parse(r.stdout)
end

local function rates(d)
    local pp = d.prompt_eval_count / (d.prompt_eval_duration / 1e9)
    local tg = d.eval_count / (d.eval_duration / 1e9)
    return pp, tg
end

-- cold: unload, then one request whose load_duration is the cold start
generate("unload", 0)
local cold = generate("cold-" .. tostring(math.random(1e6)), "30m")
out.line(string.format("cold: load=%.2fs total=%.2fs prompt_tokens=%d", cold.load_duration / 1e9, cold.total_duration / 1e9, cold.prompt_eval_count))

local pps, tgs = {}, {}
for i = 1, RUNS do
    local d = generate("run-" .. i .. "-" .. tostring(math.random(1e6)), "30m")
    local pp, tg = rates(d)
    pps[#pps + 1], tgs[#tgs + 1] = pp, tg
    out.line(string.format("run %d: prefill %d tok @ %.1f t/s, decode %d tok @ %.1f t/s", i, d.prompt_eval_count, pp, d.eval_count, tg))
end

local function stats(t)
    table.sort(t)
    local s = 0
    for _, v in ipairs(t) do s = s + v end
    return s / #t, t[1], t[#t], t[math.floor((#t + 1) / 2)]
end
local m, lo, hi, med = stats(pps)
out.line(string.format("prefill t/s: median %.1f mean %.1f min %.1f max %.1f (n=%d)", med, m, lo, hi, #pps))
m, lo, hi, med = stats(tgs)
out.line(string.format("decode  t/s: median %.1f mean %.1f min %.1f max %.1f (n=%d)", med, m, lo, hi, #tgs))
verdict.ok("bench-ollama", MODEL .. " on " .. HOSTPORT)
