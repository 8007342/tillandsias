-- @trace order:1834-ujsf, spec:local-coding-delegation
--
-- local-delegate-ladder.lua — the outcome-token grammar and the rung
-- aggregator behind scripts/local-delegate-ladder.sh and
-- `scripts/delegate-outcome.sh local-record` (openspec change
-- local-coding-experts-delegation-ladder, design §3).
--
--   tillandsias-plan script run scripts/lua/local-delegate-ladder.lua -- token
--       <model> <quant> <order> <accepted|rejected|reverted> <avoided> <retries>
--   tillandsias-plan script run scripts/lua/local-delegate-ladder.lua -- aggregate
--       [--repo <abs>] [--ledger <file>]...
--
-- TOKEN (rides an event summary; delegate-outcome:<id>:<disp> is untouched):
--   local-delegate:<model>:<quant>:<order>:<accepted|rejected|reverted>:<avoided>:<retries>
--   model, quant: [A-Za-z0-9._-]+ (no colon: write qwen3-coder-30b, not qwen3-coder:30b)
--   order: [A-Za-z0-9][A-Za-z0-9-]*   avoided: signed integer   retries: integer >= 0
--
-- AGGREGATE. Promotion is computed from the ledger, never asserted. Tokens are
-- read in ledger order (plan/index.yaml, then plan/index.d/*.yaml by name,
-- then position in file); a later token for the same (model, quant, order)
-- SUPERSEDES the earlier one in place, so `accepted` followed by `reverted`
-- is one outcome that ended reverted. Per (model, quant) the outcomes are
-- replayed in order. After each outcome the EARNED rung is evaluated on the
-- rolling window and the current rung becomes it (promote when higher, demote when lower):
--   R1  last 30 (>= 20 present): acceptance >= 70%, revert <= 5%
--   R2  last 30 (>= 20):         acceptance >= 80%, revert <= 3%
--   R3  last 30 (>= 20):         R2 and summed frontier_tokens_avoided > 0
--   R4  last 100 (>= 100):       revert <= 2%, and R3 over its own window
-- Rungs are cumulative. `reverted` is not accepted AND is a revert.
-- Percentages use integer arithmetic (n*100 compared), so thresholds are exact.
-- Output, one line per model+quant, sorted:
--   model=M quant=Q rung=<R0..R4|none:sample> verdict=<promote|hold|demote>
--   earned=R<n> outcomes=N window=W accepted=A rejected=J reverted=V
--   accept_pct=P revert_pct=P tokens_saved=T retries=K
-- verdict is the move made by the LATEST outcome's evaluation.

local PROG = "local-delegate-ladder"
local DISP = { accepted = true, rejected = true, reverted = true }

local function refuse(why, detail)
    log.error(detail or why)
    verdict.emit("refused:" .. PROG .. ":" .. why, 1)
end

local function seg_ok(s) return type(s) == "string" and s:match("^[%w%._%-]+$") ~= nil end

local function build_token(model, quant, order, disp, avoided, retries)
    if not seg_ok(model) then return nil, "bad-model" end
    if not seg_ok(quant) then return nil, "bad-quant" end
    if type(order) ~= "string" or not order:match("^%w[%w%-]*$") then return nil, "bad-order" end
    if not DISP[disp or ""] then return nil, "bad-disposition" end
    if type(avoided) ~= "string" or not avoided:match("^%-?%d+$") then return nil, "bad-tokens-avoided" end
    if type(retries) ~= "string" or not retries:match("^%d+$") then return nil, "bad-retries" end
    return table.concat({ "local-delegate", model, quant, order, disp, avoided, retries }, ":")
end

-- ----------------------------------------------------------------- aggregate
local function evaluate(list, upto)
    local function window(size)
        local from = upto - size + 1
        if from < 1 then from = 1 end
        local n, acc, rev, tok = 0, 0, 0, 0
        for i = from, upto do
            local o = list[i]
            n = n + 1
            if o.disp == "accepted" then acc = acc + 1 end
            if o.disp == "reverted" then rev = rev + 1 end
            tok = tok + o.avoided
        end
        return n, acc, rev, tok
    end
    local n, acc, rev, tok = window(30)
    local earned = 0
    if n >= 20 and acc * 100 >= 70 * n and rev * 100 <= 5 * n then
        earned = 1
        if acc * 100 >= 80 * n and rev * 100 <= 3 * n then
            earned = 2
            if tok > 0 then
                earned = 3
                if upto >= 100 then
                    local n4, _, rev4 = window(100)
                    if rev4 * 100 <= 2 * n4 then earned = 4 end
                end
            end
        end
    end
    return earned, n
end

local function pct(num, den)
    if den == 0 then return "0.0" end
    local t = math.floor(num * 1000 / den)
    return string.format("%d.%d", math.floor(t / 10), t % 10)
end

local function scan(files)
    local groups, keys = {}, {}
    for _, f in ipairs(files) do
        local okr, text = pcall(fs.read, f)
        if okr and type(text) == "string" then
            for line in (text .. "\n"):gmatch("([^\n]*)\n") do
                local pos = 1
                while true do
                    local s, e, model, quant, order, disp, avoided, retries =
                        line:find("local%-delegate:([%w%._%-]+):([%w%._%-]+):(%w[%w%-]*):(%a+):(%-?%d+):(%d+)", pos)
                    if not s then break end
                    pos = e + 1
                    local before = s > 1 and line:sub(s - 1, s - 1) or ""
                    if DISP[disp] and not before:match("[%w%-]") then
                        local k = model .. "\0" .. quant
                        local g = groups[k]
                        if not g then
                            g = { model = model, quant = quant, list = {}, byorder = {} }
                            groups[k] = g
                            keys[#keys + 1] = k
                        end
                        local rec = g.byorder[order]
                        if rec then
                            rec.disp, rec.avoided, rec.retries = disp, tonumber(avoided), tonumber(retries)
                        else
                            rec = { disp = disp, avoided = tonumber(avoided), retries = tonumber(retries) }
                            g.byorder[order] = rec
                            g.list[#g.list + 1] = rec
                        end
                    end
                end
            end
        end
    end
    table.sort(keys)
    return groups, keys
end

local function aggregate(files)
    local groups, keys = scan(files)
    for _, k in ipairs(keys) do
        local g = groups[k]
        local state, last, total = 0, "hold", #g.list
        for i = 1, total do
            last = "hold"
            local earned = evaluate(g.list, i)
            if i >= 20 then
                if earned > state then state = earned; last = "promote"
                elseif earned < state then state = earned; last = "demote" end
            end
        end
        local earned, wn = evaluate(g.list, total)
        local from = total - 29
        if from < 1 then from = 1 end
        local acc, rej, rev, tok, ret = 0, 0, 0, 0, 0
        for i = from, total do
            local o = g.list[i]
            if o.disp == "accepted" then acc = acc + 1
            elseif o.disp == "rejected" then rej = rej + 1
            else rev = rev + 1 end
            tok = tok + o.avoided
            ret = ret + o.retries
        end
        local rung = total < 20 and "none:sample" or ("R" .. state)
        print(string.format(
            "model=%s quant=%s rung=%s verdict=%s earned=R%d outcomes=%d window=%d accepted=%d rejected=%d reverted=%d accept_pct=%s revert_pct=%s tokens_saved=%d retries=%d",
            g.model, g.quant, rung, last, earned, total, wn, acc, rej, rev, pct(acc, wn), pct(rev, wn), tok, ret))
    end
    return #keys
end

-- ---------------------------------------------------------------------- main
local mode = arg[1]
if mode == "token" then
    local t, why = build_token(arg[2], arg[3], arg[4], arg[5], arg[6], arg[7])
    if not t then
        refuse(why, "usage: token <model> <quant> <order> <accepted|rejected|reverted> <tokens-avoided> <retries> (" .. why .. ")")
    end
    print(t)
    verdict.emit("ok:" .. PROG .. ":token", 0)
elseif mode == "aggregate" then
    local repo, files = nil, {}
    local i = 2
    while arg[i] ~= nil do
        if arg[i] == "--repo" then i = i + 1; repo = arg[i]
        elseif arg[i] == "--ledger" then i = i + 1; files[#files + 1] = arg[i]
        else refuse("usage", "usage: aggregate [--repo <abs>] [--ledger <file>]...") end
        i = i + 1
    end
    if #files == 0 then
        repo = repo or env.get("TILLANDSIAS_REPO_ROOT") or "."
        files[1] = repo .. "/plan/index.yaml"
        local names = {}
        local okl, ls = pcall(fs.list, repo .. "/plan/index.d")
        if okl then
            for _, f in ipairs(ls) do
                local base = f:match("([^/]+)$")
                if base and base:match("%.yaml$") then names[#names + 1] = base end
            end
        end
        table.sort(names)
        for _, b in ipairs(names) do files[#files + 1] = repo .. "/plan/index.d/" .. b end
    end
    local n = aggregate(files)
    verdict.emit(string.format("ok:%s:%d model(s)", PROG, n), 0)
else
    refuse("usage", "usage: local-delegate-ladder.lua token|aggregate ...")
end
