-- @env TILLANDSIAS_ORDER_CITATIONS_ROOT
-- @read-env TILLANDSIAS_ORDER_CITATIONS_ROOT
-- @trace order:1234-zade, spec:spec-traceability
--
-- check-order-citations-resolve.lua — PORTED from check-order-citations-resolve.sh
-- (1118-fqfk carry). Every `@trace order:<id>` must name a packet that exists.
--
-- WHY THIS EXISTS. validate-traces.sh detects GHOST TRACES for `spec:` and does
-- not look at `order:` at all, although the documented annotation carries both.
-- Order UNIQUENESS is gated among filed packets; order EXISTENCE is not, so a
-- citation into the ledger, which is how a reader gets from code to the
-- reasoning behind it, would have no resolver.
--
-- An INVENTED SUFFIX on a real order reads as a legitimate sub-designation, so
-- a reader follows it and lands on nothing, or on the wrong packet. Ten such
-- citations landed in one night on 2026-09-16 and every gate passed them.
--
-- ARCHIVED PACKETS RESOLVE, deliberately: an order does not stop existing when
-- its row is archived.
--
-- RATCHET, not a sweep. The ids in DECLARED are reported without refusing.
-- Removing one after fixing it is the intended direction; adding one is not.
--
-- ORDER 1274-cbk7: the ledger value may be a QUOTED scalar (`order: "X"`), and
-- both spellings are read.
--
-- The tree is TILLANDSIAS_ORDER_CITATIONS_ROOT when set (the fixture's scratch
-- trees), else the repository root. `/usr/bin/grep` as in validate-traces.sh:
-- the shell `grep` may be a wrapper.
--
-- VERDICTS (one line, stdout):
--   ok:order-citations-resolve:<cited> checked, <declared> declared
--   violation:order-citations-unresolvable:<n>
--   blocked:order-citations-resolve:no-ledger-orders-found

-- Known-unresolvable, declared 2026-09-17. Remove an entry when it is fixed.
local DECLARED = { ["1184-u5mg"] = true, ["723-b9cn"] = true }

local root = env.get("TILLANDSIAS_ORDER_CITATIONS_ROOT")
if root == "" then root = nil end
local GREP = "/usr/bin/grep"
local CITE_ROOTS = { "scripts/", "crates/", "images/", "methodology/" }

local function grep(args)
    local argv = { GREP }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local r = proc.run{ argv = argv, cwd = root }
    return text.lines(r.stdout or "")
end

-- Top-level *.sh files, which the shell original reached as ./*.sh.
local function top_level_sh()
    local r = proc.run{ argv = { "find", ".", "-maxdepth", "1", "-name", "*.sh", "-type", "f" }, cwd = root }
    local out = {}
    for _, l in ipairs(text.lines(r.stdout or "")) do
        if l ~= "" then out[#out + 1] = l end
    end
    table.sort(out)
    return out
end

local DECL = '^[[:space:]]*-?[[:space:]]*order: "?[0-9]{3,4}-[a-z0-9]{4}"?'
local known = {}
local known_n = 0
for _, src in ipairs({ { "plan/index.yaml", "plan/index.d/" }, { "plan/archive/" } }) do
    local args = { "-rhoE", DECL }
    for _, p in ipairs(src) do args[#args + 1] = p end
    for _, l in ipairs(grep(args)) do
        local id = l:match('order: "?([0-9]+%-[a-z0-9]+)"?')
        if id and not known[id] then
            known[id] = true
            known_n = known_n + 1
        end
    end
end
if known_n == 0 then
    verdict.emit("blocked:order-citations-resolve:no-ledger-orders-found — the ledger read produced nothing, which is a broken instrument rather than a clean tree", 2)
end

local function cite_args(extra)
    local args = extra
    for _, d in ipairs(CITE_ROOTS) do args[#args + 1] = d end
    for _, f in ipairs(top_level_sh()) do args[#args + 1] = f end
    return args
end

local cited, cited_list = {}, {}
for _, l in ipairs(grep(cite_args({ "-rhoE", '@trace[^"]{0,60}order:[0-9]{3,4}-[a-z0-9]{4}' }))) do
    for id in l:gmatch("order:([0-9][0-9][0-9][0-9]?%-[a-z0-9][a-z0-9][a-z0-9][a-z0-9])") do
        if not cited[id] then
            cited[id] = true
            cited_list[#cited_list + 1] = id
        end
    end
end
table.sort(cited_list)

local declared_n, violations = 0, 0
for _, id in ipairs(cited_list) do
    if not known[id] then
        if DECLARED[id] then
            declared_n = declared_n + 1
        else
            violations = violations + 1
            log.raw("  unresolvable order citation: " .. id)
            for _, f in ipairs(grep(cite_args({ "-rln", "order:" .. id }))) do
                if f ~= "" then log.raw("    cited in: " .. f) end
            end
            log.raw("    No packet carries that order. If the suffix was invented on a real")
            log.raw("    order number, a reader following it lands on nothing or on the wrong")
            log.raw("    packet — mint a real id with `tillandsias-plan next-order` and file it,")
            log.raw("    or cite the order that actually exists.")
        end
    end
end

if violations > 0 then
    verdict.emit("violation:order-citations-unresolvable:" .. violations, 1)
end
verdict.emit("ok:order-citations-resolve:" .. #cited_list .. " checked, " .. declared_n .. " declared", 0)
