-- @trace order:2118-98dq
-- @env TILLANDSIAS_PICKUP_ROLE_INPUT TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- check-pickup-role-grammar.lua — PORTED from check-pickup-role-grammar.sh
-- (2118-98dq, check-[n-z] batch 3). Is every pickup_role a canonical token, and
-- does any prose role SEQUENCE hosts ("linux ...; macos replicate later")?
-- Rules are the .sh's, unchanged:
--   canonical  linux|macos|windows|any|forge|linux_mutable|linux_immutable|coordinator|tlatoani
--              (whole value, case-insensitive);
--   multi-host a non-canonical value naming two or more of linux/macos/windows.
--              Its owner is the host named FIRST, the rest are claimable-as;
--   sequenced  a multi-host value containing later|verif|replicate|support|
--              afterward|follow|then (case-insensitive), else co-owned.
--
-- INPUT. TILLANDSIAS_PICKUP_ROLE_INPUT names a file of values, one per line
-- (fixtures; it must be inside the checkout, because the lua fs is
-- checkout-confined). Otherwise the folded ledger is read through the plan
-- binary the caller NAMES (TILLANDSIAS_PLAN_BIN, else
-- TILLANDSIAS_SCRIPT_RUNNER_BIN, which build.sh sets): `query --limit 0 --json`,
-- decoded as JSON rather than split with awk and sed.
--
-- Grammar (stdout), unchanged:
--   pickup-role: total=N canonical=N prose=N multi_host=N sequenced=0 verdict=ok:canonical-roles      exit 0
--   pickup-role: ... sequenced=N verdict=attention:sequenced-prose                                   exit 1
--   pickup-role: refused:<reason>                                                                    exit 2
-- --detail prints one `<kind>\t<value>\towner=<h>\tclaimable-as=<h,...>` line
-- per multi-host value first.
--
-- Usage: tillandsias-plan script run scripts/lua/check-pickup-role-grammar.lua [-- --detail]

local DETAIL = arg and arg[1] == "--detail"
local CANON = {}
for t in ("linux|macos|windows|any|forge|linux_mutable|linux_immutable|coordinator|tlatoani"):gmatch("[^|]+") do CANON[t] = true end
local HOSTS = { "linux", "macos", "windows" }
local SEQ = { "later", "verif", "replicate", "support", "afterward", "follow", "then" }

local function refuse(reason)
    out.line("pickup-role: refused:" .. reason)
    verdict.emit("refused:pickup-role:" .. (reason:match("^[^:]+") or "refused"), 2)
end
local function nonempty(v) return v ~= nil and v ~= "" end

local values = {}
local input = env.get("TILLANDSIAS_PICKUP_ROLE_INPUT")
if nonempty(input) then
    -- fs.exists raises for a path outside the checkout; that is "no such
    -- input" here too, exit 2 as before.
    local okx, present = pcall(fs.exists, input)
    if not okx or not present then refuse("no-such-input:" .. input) end
    for l in ((fs.read(input) or "") .. "\n"):gmatch("([^\n]*)\n") do
        if not l:match("^ *$") then values[#values + 1] = l end
    end
else
    local bin = env.get("TILLANDSIAS_PLAN_BIN")
    if not nonempty(bin) then bin = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") end
    if not nonempty(bin) then
        refuse("no-plan-binary:cannot read the folded ledger (build with cargo build --release -p tillandsias-plan)")
    end
    local r = proc.run({ argv = { bin, "query", "--limit", "0", "--json" }, timeout_ms = 120000 })
    local ok, rows = pcall(json.parse, r.stdout or "")
    if ok and type(rows) == "table" then
        for _, row in ipairs(rows) do
            local v = type(row) == "table" and row.pickup_role or nil
            if type(v) == "string" and not v:match("^ *$") then values[#values + 1] = v end
        end
    end
    if #values == 0 then refuse("empty-projection:the plan binary returned no pickup_role values") end
end
if #values == 0 then refuse("empty-projection:no pickup_role values to inspect") end

local total, canonical, multi, sequenced = #values, 0, 0, 0
local detail = {}
for _, v in ipairs(values) do
    local lower = v:lower()
    if CANON[lower] then
        canonical = canonical + 1
    else
        local named = {}
        for _, h in ipairs(HOSTS) do
            local p = lower:find(h, 1, true)
            if p then named[#named + 1] = { h = h, p = p } end
        end
        if #named >= 2 then
            -- owner: the host whose name appears first in the value
            table.sort(named, function(a, b) return a.p < b.p end)
            local owner = named[1].h
            local claim = {}
            for _, h in ipairs(HOSTS) do
                if h ~= owner and lower:find(h, 1, true) then claim[#claim + 1] = h end
            end
            multi = multi + 1
            local kind = "co-owned"
            for _, w in ipairs(SEQ) do
                if lower:find(w, 1, true) then kind = "sequenced"; break end
            end
            if kind == "sequenced" then sequenced = sequenced + 1 end
            detail[#detail + 1] = kind .. "\t" .. v .. "\towner=" .. owner .. "\tclaimable-as=" .. table.concat(claim, ",")
        end
    end
end

if DETAIL then for _, d in ipairs(detail) do out.line(d) end end
local head = ("pickup-role: total=%d canonical=%d prose=%d multi_host=%d sequenced=%d"):format(
    total, canonical, total - canonical, multi, sequenced)
if sequenced == 0 then
    out.line(head .. " verdict=ok:canonical-roles")
    verdict.emit("ok:pickup-role:canonical-roles", 0)
end
out.line(head .. " verdict=attention:sequenced-prose")
verdict.emit("violation:pickup-role:sequenced-prose", 1)
