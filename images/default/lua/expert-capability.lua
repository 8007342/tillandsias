-- @trace order:569, order:984-i4k2, order:2396-x2x9, spec:default-image
-- @class observing
--
-- expert-capability.lua — the core of images/default/lib-expert-capability.sh, run by
-- `tillandsias-plan script run --helper` (openspec change forge-lua-helpers D3.6, task 1.7).
-- It asks the RUNNING expert binary what it can do and which sources it was built from, reads
-- the checkout's manifest, and decides the skew. The awk | sort, tr | sed, sed | head and
-- timeout chains (18 of the 21 processes, measured in the forge image) become the binary's own
-- three answers and two file reads. The spec-index and embed halves stay shell (D3.6).
--
-- Arguments: <binary> <checkout> <build-state-dir> <build-budget-secs>
-- Output, five lines in this order:
--   now        csv of the binary's capabilities, `stale-binary` (present, no manifest), or none
--   after      csv of the checkout's manifest, or none
--   skew       none | pending-build | relaunch-required | relaunch-regresses | rebuild-required
--              | unknown-currency                                   (the CLOSED vocabulary)
--   blocked    csv the checkout offers and the binary lacks, or -
--   lost       csv the binary has and the checkout does not, or - (always - when after is none)
-- It never errors: a missing, crashing or pre-569 binary and an unreadable checkout each land
-- inside the grammar (the expert lane is optional, order 486).

local bin, checkout = arg[1] or "", arg[2] or ""
local state_dir = (arg[3] and arg[3] ~= "") and arg[3] or "/dev/shm/tillandsias-experts"
local budget = tonumber(arg[4] or "") or 300
local MANIFEST_REL = "crates/tillandsias-plan/capabilities.txt"

local function run(argv, timeout_ms)
    local r = proc.run{ argv = argv, stdin = "", timeout_ms = timeout_ms or 5000 }
    return r, (r.status == "exited" and r.code == 0) and (r.stdout or "") or nil
end
local function first_line(s) return ((s or "") .. "\n"):match("^([^\n]*)") end
local function read(path) local _, o = run({ "cat", path }, 5000); return o end

-- Sorted unique bare tokens: `awk '{sub(/#.*/,"")} {gsub(/[ \t\r]+/,"")} /^[a-z][a-z0-9-]*$/' | sort -u`.
local function clean(s)
    local seen, set = {}, {}
    for l in ((s or "") .. "\n"):gmatch("([^\n]*)\n") do
        l = l:gsub("#.*", ""):gsub("[ \t\r]+", "")
        if l:match("^[a-z][a-z0-9%-]*$") and not seen[l] then seen[l] = true; set[#set + 1] = l end
    end
    table.sort(set)
    return set, seen
end
local function join(t, empty) return #t > 0 and table.concat(t, ",") or empty end

local now_v, after_v, skew = "none", "none", "none"
local now, now_has, after, after_has = {}, {}, {}, {}

if bin ~= "" then
    local r, o = run({ bin, "capabilities" }, 5000)
    if r.status ~= "spawn_failed" and (r.status or ""):sub(1, 7) ~= "policy_" then
        now, now_has = clean(o or "")
        now_v = #now == 0 and "stale-binary" or join(now, "none")
    end
end
if checkout ~= "" then
    local m = read(checkout .. "/" .. MANIFEST_REL)
    if m then
        after, after_has = clean(m)
        after_v = join(after, "none")
    end
end

local missing, lost = {}, {}
for _, t in ipairs(after) do if not now_has[t] then missing[#missing + 1] = t end end
for _, t in ipairs(now) do if not after_has[t] then lost[#lost + 1] = t end end
local blocked = join(missing, "-")
local lost_v = after_v == "none" and "-" or join(lost, "-")

-- A build is in flight when the state file says `building` and it started within the budget.
local function build_in_flight()
    local st = read(state_dir .. "/state")
    if not st or st:gsub("\n+$", "") ~= "building" then return false end
    local started = tonumber(((read(state_dir .. "/started_at") or ""):gsub("\n+$", "")):match("^%d+$") or "") or 0
    local elapsed = math.floor(time.now_ms() / 1000) - started
    if elapsed < 0 then elapsed = 0 end
    return elapsed <= budget
end

if blocked ~= "-" then
    skew = build_in_flight() and "pending-build" or "relaunch-required"
elseif lost_v ~= "-" and after_v ~= "none" then
    skew = "relaunch-regresses"
end

-- Same capabilities, different sources (984-i4k2): compare the build-id with the checkout's
-- source revision. A binary that cannot say where it came from is unknown-currency.
if skew == "none" and bin ~= "" then
    local _, id = run({ bin, "build-id" }, 5000)
    local running = first_line(id or "")
    local co = ""
    if checkout ~= "" and run({ "test", "-f", checkout .. "/crates/tillandsias-plan/src/main.rs" }, 5000).code == 0 then
        local _, rev = run({ bin, "source-revision", checkout .. "/crates/tillandsias-plan" }, 10000)
        co = first_line(rev or "")
    end
    if running:find("+", 1, true) then
        if co ~= "" and running ~= co then skew = "rebuild-required" end
    else
        skew = "unknown-currency"
    end
end

out.line(now_v); out.line(after_v); out.line(skew); out.line(blocked); out.line(lost_v)
