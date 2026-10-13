-- @trace order:1653-77bt
-- bench-llama-server.lua — prefill/decode tokens/sec from a llama-server /completion endpoint.
-- Same prompt, same decode length (128, EOS ignored), prompt cache off, on every route.
-- Usage: tillandsias-plan script run bench-llama-server.lua -- <host:port> <runs> <label>
local HOSTPORT, RUNS, LABEL = arg[1] or "127.0.0.1:11510", tonumber(arg[2] or "5"), arg[3] or "route"

local filler = {}
for i = 1, 60 do
    filler[#filler + 1] = "Sentence " .. i .. " describes a tillandsia that grows on a branch without soil."
end
local BODY = table.concat(filler, " ") .. " Summarise the passage above in detail."

local function complete(prefix)
    local req = json.encode({
        prompt = prefix .. " " .. BODY, n_predict = 128, ignore_eos = true,
        temperature = 0, seed = 42, cache_prompt = false,
    })
    local r = proc.run({ argv = { "curl", "-s", "-X", "POST", "http://" .. HOSTPORT .. "/completion", "-d", req },
        timeout_ms = 900000 })
    if r.code ~= 0 then verdict.could_not_run("bench-llama-server", "curl rc=" .. tostring(r.code)) end
    local d = json.parse(r.stdout)
    if type(d) ~= "table" or type(d.timings) ~= "table" then
        verdict.could_not_run("bench-llama-server", "no timings in: " .. tostring(r.stdout):sub(1, 200))
    end
    return d.timings
end

complete("warmup")
local pps, tgs = {}, {}
for i = 1, RUNS do
    local t = complete("run-" .. i .. "-" .. tostring(math.random(1e6)))
    pps[#pps + 1], tgs[#tgs + 1] = t.prompt_per_second, t.predicted_per_second
    out.line(string.format("%s run %d: prefill %d tok @ %.1f t/s, decode %d tok @ %.1f t/s",
        LABEL, i, t.prompt_n, t.prompt_per_second, t.predicted_n, t.predicted_per_second))
end

local function stats(t)
    table.sort(t)
    local s = 0
    for _, v in ipairs(t) do s = s + v end
    return t[math.floor((#t + 1) / 2)], s / #t, t[1], t[#t]
end
local med, m, lo, hi = stats(pps)
out.line(string.format("%s prefill t/s: median %.1f mean %.1f min %.1f max %.1f (n=%d)", LABEL, med, m, lo, hi, #pps))
med, m, lo, hi = stats(tgs)
out.line(string.format("%s decode  t/s: median %.1f mean %.1f min %.1f max %.1f (n=%d)", LABEL, med, m, lo, hi, #tgs))
verdict.ok("bench-llama-server", LABEL .. " on " .. HOSTPORT)
