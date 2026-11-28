-- @env PATH HOME
-- @trace order:1834-ujsf, spec:local-coding-delegation, order:2330-sn77
--
-- test-local-delegate-ladder.lua — the local-delegate outcome token (delegate-outcome.sh
-- local-record) and the rung aggregator (scripts/lua/local-delegate-ladder.lua). Ported from
-- the .sh of the same name (2330-sn77). Ledgers are generated: A accepted, R rejected, V
-- reverted, one token per outcome.
--
--   1 token grammar and its refusals       2 harness wiring
--   3 rung boundaries                      4 R3 / R4
--   5 demotion                             6 a later revert supersedes the acceptance
--   7 stable order, identical reruns       8 the older token grammar is unchanged
--   9 aggregate without --repo (2427-ldrr)
--
-- Usage: tillandsias-plan script run scripts/lua/test-local-delegate-ladder.lua
-- Verdict: ok:local-delegate-ladder:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("local-delegate-ladder")
local SH, ROOT, PLAN = fixture.posix_shell(), fixture.repo_root(), fixture.plan_binary()
if PLAN == "" then T:skip("no-plan-binary") end
local d = T:scratch()
local function outcome(args)
    local argv = { SH, ROOT .. "/scripts/delegate-outcome.sh" }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local r = proc.run{ argv = argv, cwd = ROOT, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 60000,
        env = { PATH = env.get("PATH"), HOME = env.get("HOME"), TILLANDSIAS_PLAN_BIN = PLAN } }
    return r.code, text.trim((r.stdout or "") .. (r.stderr or ""))
end
-- o: overrides of the valid defaults; a false removes the flag.
local function record(o)
    local v = { model = "m", quant = "q", order = "o1", disposition = "accepted" }
    for k, x in pairs(o) do v[k] = x end
    local args = { "local-record" }
    for _, k in ipairs{ "model", "quant", "order", "disposition", "tokens-avoided", "retries", "harness-verdict" } do
        if v[k] then args[#args + 1] = "--" .. k; args[#args + 1] = v[k] end
    end
    args[#args + 1] = "--dry-run"
    return outcome(args)
end
local function token(name, want, o)
    local rc, got = record(o)
    T:arm(name, rc == 0 and got == want, "rc=" .. tostring(rc) .. " " .. got)
end
local function refused(name, o)
    local rc, got = record(o)
    T:arm(name, rc ~= 0 and not text.contains("\n" .. got, "\nlocal-delegate:"), "rc=" .. tostring(rc) .. " " .. got)
end
token("1a the token grammar is exact", "local-delegate:qwen3-coder-30b:Q5_K_M:1834-ujsf:accepted:4000:1",
    { model = "qwen3-coder-30b", quant = "Q5_K_M", order = "1834-ujsf", ["tokens-avoided"] = "4000", retries = "1" })
token("1b tokens are signed and retries default to 0", "local-delegate:m:q:o1:reverted:-250:0", { disposition = "reverted", ["tokens-avoided"] = "-250" })
refused("1c a bad disposition is refused", { disposition = "maybe" })
refused("1c a colon in the model is refused", { model = "a:b" })
refused("1c non-numeric tokens are refused", { ["tokens-avoided"] = "12x" })
refused("1c a missing order is refused", { order = false })
local RED = "refused:local-delegate:o1:closure-red:rounds=2"
token("2a retries come from the harness rounds", "local-delegate:m:q:o1:accepted:0:2", { ["harness-verdict"] = "ok:local-delegate:o1:ok:rounds=3:closure=passed" })
refused("2b a red harness cannot be recorded accepted", { ["harness-verdict"] = RED })
token("2c a red harness can be recorded rejected", "local-delegate:m:q:o1:rejected:0:0", { disposition = "rejected", ["harness-verdict"] = RED })

local WORD = { A = "accepted", R = "rejected", V = "reverted" }
local function gen(model, quant, seq, tokens, prefix)
    local out, i = {}, 0
    for c in seq:gmatch(".") do
        out[#out + 1] = '        summary: "local-delegate outcome local-delegate:' .. model .. ":" .. quant .. ":" .. (prefix or "o") .. i .. ":" .. WORD[c] .. ":"
            .. (c == "A" and tokens or 0) .. ':0"\n'
        i = i + 1
    end
    return table.concat(out)
end
local function aggregate(body)
    fs.write(d.rel .. "/ledger.yaml", body)
    local r = proc.run{ argv = { PLAN, "script", "run", "scripts/lua/local-delegate-ladder.lua", "--", "aggregate", "--repo", ROOT, "--ledger", d.abs .. "/ledger.yaml" }, cwd = ROOT,
        env_unset = { "TILLANDSIAS_*" }, env = { PATH = env.get("PATH"), HOME = env.get("HOME"), TILLANDSIAS_REPO_ROOT = ROOT }, timeout_ms = 60000 }
    return (r.stdout or ""):gsub("\r", ""), "rc=" .. tostring(r.code) .. " " .. (r.stdout or "") .. (r.stderr or "")
end
local function expect(name, body, want)
    local o, why = aggregate(body)
    local line, missing = " " .. (o:match("^[^\n]*") or "") .. " ", {}
    for w in want:gmatch("%S+") do
        if not text.contains(line, " " .. w .. " ") then missing[#missing + 1] = w end
    end
    T:arm(name, #missing == 0, "missing " .. table.concat(missing, " ") .. " in " .. why)
end
local function seq(a, r, v) return ("A"):rep(a) .. ("R"):rep(r) .. ("V"):rep(v) end
local function one(s, tokens) return gen("m", "Q5", s, tokens or 0) end
expect("3a 15A/4R/1V is R1 promote", one(seq(15, 4, 1)), "rung=R1 verdict=promote outcomes=20 accepted=15 reverted=1")
expect("3b 14A/5R/1V (70%, 5%) is R1", one(seq(14, 5, 1)), "rung=R1")
expect("3c 13A/6R/1V (65%) is R0 hold", one(seq(13, 6, 1)), "rung=R0 verdict=hold")
expect("3d 15A/3R/2V (10% revert) is R0", one(seq(15, 3, 2)), "rung=R0")
expect("3e 17A/3R is R2 promote", one(seq(17, 3, 0)), "rung=R2 verdict=promote")
expect("3f 16A/3R/1V (5% revert) is R1", one(seq(16, 3, 1)), "rung=R1")
expect("3g 19 outcomes is none:sample", one(seq(19, 0, 0)), "rung=none:sample verdict=hold outcomes=19")
expect("3h 20A without tokens is R2", one(seq(20, 0, 0)), "rung=R2")
expect("4a positive tokens is R3", one(seq(17, 3, 0), 10), "rung=R3 tokens_saved=170")
expect("4b negative tokens is R2", one(seq(17, 3, 0), -10), "rung=R2")
expect("4c 100 outcomes with 2V is R4", one("VV" .. ("A"):rep(98), 10), "rung=R4 outcomes=100")
expect("4d 100 outcomes with 3V is R3", one("VVV" .. ("A"):rep(97), 10), "rung=R3")
expect("4e 99 outcomes is R3", one(("A"):rep(99), 10), "rung=R3")
expect("5a 20A is R3 promote", one(seq(20, 0, 0), 10), "rung=R3 verdict=promote")
expect("5b then 2V is R0 demote", one(seq(20, 0, 0), 10) .. gen("m", "Q5", "VV", 0, "x"), "rung=R0 verdict=demote earned=R0 outcomes=22")
expect("6 a later revert supersedes the acceptance of the same order", one(seq(20, 0, 0)) .. '        summary: "local-delegate:m:Q5:o0:reverted:0:0"\n', "outcomes=20 reverted=1 accepted=19")
local G = gen("zeta", "Q4", ("A"):rep(20), 0, "z") .. gen("alpha", "Q8", ("A"):rep(20), 0, "a") .. gen("alpha", "Q4", ("A"):rep(5), 0, "b")
local o1, why = aggregate(G)
local o2 = aggregate(G)
T:arm("7a two runs are identical", o1 ~= "" and o1 == o2, why)
local heads = {}
for m, q in ("\n" .. o1):gmatch("\nmodel=(%S+) quant=(%S+) ") do heads[#heads + 1] = m .. "/" .. q end
T:arm("7b groups are sorted by model and quant", table.concat(heads, ",") == "alpha/Q4,alpha/Q8,zeta/Q4", table.concat(heads, ","))
T:arm("7c a small group stays none:sample", text.contains(o1, "model=alpha quant=Q4 rung=none:sample"), why)
local rc, tok = outcome{ "token", "abc", "done" }
T:arm("8 the delegate-outcome token is unchanged", rc == 0 and tok == "delegate-outcome:abc:done", tok)
-- 9 (2427-ldrr): aggregate with no --repo reads TILLANDSIAS_REPO_ROOT, so the
-- script must declare it; undeclared, env.get raised and the bare form never ran.
local function bare(env_)
    local r = proc.run{ argv = { PLAN, "script", "run", ROOT .. "/scripts/lua/local-delegate-ladder.lua", "--", "aggregate" }, cwd = ROOT,
        env_unset = { "TILLANDSIAS_*" }, env = env_, timeout_ms = 60000 }
    return r.code, (r.stdout or ""):gsub("\r", ""), "rc=" .. tostring(r.code) .. " " .. (r.stdout or "") .. (r.stderr or "")
end
fs.mkdir(d.rel .. "/repo/plan/index.d")
fs.write(d.rel .. "/repo/plan/index.yaml", gen("alpha", "Q4", "A", 0, "r"))
fs.write(d.rel .. "/repo/plan/index.d/a.yaml", gen("alpha", "Q4", "A", 0, "s"))
local rc9, o9, why9 = bare{ PATH = env.get("PATH"), HOME = env.get("HOME"), TILLANDSIAS_REPO_ROOT = d.abs .. "/repo" }
T:arm("9a aggregate with no --repo reads TILLANDSIAS_REPO_ROOT's ledger and fragments", rc9 == 0
    and text.contains(o9, "model=alpha quant=Q4 ") and text.contains(o9, "outcomes=2"), why9)
local rc9b, o9b, why9b = bare{ PATH = env.get("PATH"), HOME = env.get("HOME") }
T:arm("9b aggregate with neither --repo nor TILLANDSIAS_REPO_ROOT reads this checkout", rc9b == 0
    and text.contains(o9b, "ok:local-delegate-ladder:"), why9b)
T:finish()
