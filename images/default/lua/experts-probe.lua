-- @trace order:718-ja7g, order:2049-krk2
-- @class observing
--
-- experts-probe.lua — the body of images/default/lib-experts-probe.sh, run by
-- `tillandsias-plan script run --helper` (openspec change forge-lua-helpers
-- D3.2). It asks the plan binary for its capabilities, runs `experts-probe`,
-- and splits the verdict line with string matching instead of three
-- `printf | sed` captures and a `capabilities | grep -qx`.
--
-- Argument: the plan binary to ask (the .sh passes the one it resolved).
-- Output, four lines in this order, never an empty line:
--   1 line     the binary's `experts_probe: ...` line, or a named substitute
--   2 l1       tier token (ready|unset|unreachable|scheme-unsupported|malformed|unknown)
--   3 l2       tier token
--   4 advice   the single next action, or -
-- L0 is file-backed and always ready; the .sh sets it.
--
-- Environment (2029-39bt): the binary runs from the runner's base environment.
-- Its inputs are TILLANDSIAS_EMBED_ENDPOINT, TILLANDSIAS_SPEC_EXPERT_ENDPOINT
-- and TILLANDSIAS_INFERENCE_ENDPOINT, all TILLANDSIAS_* and so passed; no
-- proxy, which is the forge's route to enclave and loopback endpoints anyway.

local bin = arg[1] or ""

local function substitute(advice)
    print("experts_probe: l0=ready l1=unknown l2=unknown embed=? synth=? advice=" .. advice)
    print("unknown")
    print("unknown")
    print(advice)
end

if bin == "" then
    substitute("probe-binary-missing: tillandsias-plan is not on PATH, so tier liveness is UNKNOWN rather than absent")
    return
end

-- A binary predating this subcommand is named as such, not read as a dead
-- endpoint (the stale-artifact signal of order 569).
local caps = proc.run{ argv = { bin, "capabilities" }, timeout_ms = 10000 }
local has = false
for _, l in ipairs(text.lines(caps.stdout or "")) do
    if l == "experts-probe" then has = true; break end
end
if not has then
    substitute("probe-subcommand-missing: this tillandsias-plan predates experts-probe (718-ja7g) — rebuild it; tier liveness is UNKNOWN, not absent")
    return
end

local r = proc.run{ argv = { bin, "experts-probe" }, timeout_ms = 30000 }
local first = text.lines(r.stdout or "")[1] or ""
if first:sub(1, #"experts_probe:") ~= "experts_probe:" then
    substitute("probe-no-verdict: experts-probe produced no parseable line")
    return
end

local l1 = first:match(" l1=(%S+)") or ""
local l2 = first:match(" l2=(%S+)") or ""
-- advice runs to end of line: it is a sentence and may contain spaces.
local advice = first:match(" advice=(.*)$") or ""
print(first)
print(l1 ~= "" and l1 or "unknown")
print(l2 ~= "" and l2 or "unknown")
print(advice ~= "" and advice or "-")
