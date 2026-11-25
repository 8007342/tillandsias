-- @env PATH HOME
-- @trace order:1011-d578, order:2367-wtse
--
-- test-capability-routing.lua — select-work-batch.sh spreads the fleet over the frontier by host,
-- withholds work a host cannot run, and never by what the host itself reported. Ported from the .sh
-- of the same name (2367-wtse). It reads this checkout's ledger; the cross-branch check is a stub.
--
--   1 eight identities, disjoint epics       2 the accelerator filter excludes, and accounts
--   3 one host walks every frontier slot     4 a host with no row: deterministic, no routing field
--   5 a low-end host routes or refuses, never drains generally   6 present-but-unusable hardware
--   enters bring-up, absent does not         7 what was filtered is named
--   8 a host's own capabilities do not move where it is pointed
--
-- Usage: tillandsias-plan script run scripts/lua/test-capability-routing.lua
-- Verdict: ok:capability-routing:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("capability-routing")
local SH, PLAN, ROOT = fixture.posix_shell(), fixture.plan_binary(), fixture.repo_root()
if PLAN == "" then T:refuse("no-plan-binary") end
local stub = T:scratch()
fs.write(stub.rel .. "/xbranch", "#!/usr/bin/env bash\nexit 0\n")
T:must{ "chmod", "+x", stub.abs .. "/xbranch" }
-- e: the selector's environment; args after "linux".
local function select(e, ...)
    local env_ = { PATH = env.get("PATH"), HOME = env.get("HOME"), TILLANDSIAS_PLAN_BIN = PLAN, TILLANDSIAS_XBRANCH_CHECK = stub.abs .. "/xbranch", TILLANDSIAS_HOST_TIER = "general" }
    for k, v in pairs(e) do env_[k] = v end
    local r = proc.run{ argv = { SH, ROOT .. "/scripts/select-work-batch.sh", "linux", ... }, cwd = ROOT, env = env_, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 300000 }
    local o = (r.stdout or ""):gsub("\r", "")
    local h = o:match("^[^\n]*") or ""
    return { rc = r.code, out = o, head = h, epic = h:match("^batch: epic=(%S*)"), width = tonumber(h:match("width=(%d+)")), triage = ("\n" .. o):match("\n(triage:[^\n]*)") or "",
        why = "rc=" .. tostring(r.code) .. " " .. o:sub(1, 300) .. (r.stderr or ""):sub(1, 300) }
end
local HOSTS = { "hilaptop1", "hilaptop2", "hilaptop3", "lowlap1", "lowlap2", "macuahuitl", "mstudio", "oldair" }
local CAPS = { "gpu-cuda\tgpu:amd:unusable,gpu:nvidia:usable", "cpu\tgpu:amd:unusable,npu:amd:usable", "gpu-rocm\tgpu:amd:usable,npu:amd:usable", "cpu\tnone", "cpu\tnpu:intel:usable",
    "gpu-cuda\tgpu:nvidia:usable,npu:intel:unusable", "metal\tgpu:apple:usable", "cpu\tnone" }
local function roster(mine)
    local l = {}
    for i, h in ipairs(HOSTS) do l[i] = h .. "\t" .. (h == "macuahuitl" and mine and "gpu-cuda\t" .. mine or CAPS[i]) end
    return table.concat(l, "\n")
end
local function routed(host, rot, mine) return select{ TILLANDSIAS_CAP_HOSTS = roster(mine), TILLANDSIAS_WORKSTATION = host, TILLANDSIAS_ROUTE_ROT = tostring(rot or 0) } end
local function distinct(l)
    local s, n = {}, 0
    for _, v in ipairs(l) do
        if not s[v] then s[v] = true; n = n + 1 end
    end
    return n
end
local epics, unranked, width, why = {}, {}, nil, ""
for _, h in ipairs(HOSTS) do
    local x = routed(h)
    if x.rc ~= 0 or not x.epic or not text.contains(x.head, "route=rank:") then unranked[#unranked + 1] = h; why = x.why end
    epics[#epics + 1] = x.epic or "-"
    width = x.width or width
end
T:arm("1a every host is routed by rank to an epic", #unranked == 0, table.concat(unranked, " ") .. " " .. why)
T:arm("1b as many distinct epics as the frontier has room for", width ~= nil and distinct(epics) == math.min(#HOSTS, width), "width=" .. tostring(width) .. " " .. table.concat(epics, " "))
local none, all = select{ TILLANDSIAS_CAP_HOSTS = "", TILLANDSIAS_HOST_ACCELS = "" }, select{ TILLANDSIAS_CAP_HOSTS = "", TILLANDSIAS_HOST_ACCELS = "cuda rocm npu metal" }
local function num(x, k) return tonumber(x.triage:match(k .. "=(%d+)")) end
T:arm("2a a fully accelerated host is withheld nothing", all.rc == 0 and all.triage ~= "" and not text.contains(all.triage, "accel_filtered="), all.triage)
T:arm("2b one with none is withheld something, and it accounts exactly", (num(none, "accel_filtered") or 0) > 0 and num(none, "eligible") + num(none, "accel_filtered") == num(all, "eligible"), none.triage .. " / " .. all.triage)
T:arm("7 what was filtered is named", none.triage:find("accel_filtered=%d+%([a-z]+:%d+") ~= nil, none.triage)
local walk = {}
for rot = 0, (width or 0) - 1 do walk[#walk + 1] = routed("macuahuitl", rot).epic or "-" end
T:arm("3 one host walks every frontier slot across rotations", (width or 0) >= 3 and distinct(walk) == width, "width=" .. tostring(width) .. " " .. table.concat(walk, " "))
local a, b = select({ TILLANDSIAS_CAP_HOSTS = "" }, "--seed", "fixture-ec4"), select({ TILLANDSIAS_CAP_HOSTS = "" }, "--seed", "fixture-ec4")
T:arm("4a a host with no row is deterministic under a seed", a.rc == 0 and a.out == b.out, a.why)
T:arm("4b it carries no route and keeps the seeded top-3 pick", not text.contains(a.head, "route=") and a.head:find("pick=%d+/3") ~= nil, a.head)
local low = select{ TILLANDSIAS_CAP_HOSTS = "", TILLANDSIAS_HOST_TIER = "low-end" }
if low.rc == 0 then T:arm("5a a low-end host is routed by its tier", text.contains(low.head, "route=tier:low-end"), low.head)
else T:arm("5a a low-end host with no work of its tier is refused by name", text.contains("\n" .. low.out, "\nrefused:no-tier-work:"), low.why) end
low = select{ TILLANDSIAS_CAP_HOSTS = "", TILLANDSIAS_HOST_TIER = "low-end", TILLANDSIAS_TIER_TAGS = "fixture-tier-tag-no-packet-carries" }
T:arm("5b an empty tier refuses rather than draining generally", low.rc ~= 0 and text.contains("\n" .. low.out, "\nrefused:no-tier-work:"), low.why)
local function bring(present) return select({ TILLANDSIAS_HOST_ACCELS = "", TILLANDSIAS_HOST_ACCELS_PRESENT = present, TILLANDSIAS_CAP_HOSTS = "" }, "--seed", "fixture-bringup") end
local here, absent = bring("npu"), bring("")
T:arm("6a present-but-unusable hardware enters the bring-up lane, absent does not", here.triage:find("accel_bringup=%S*npu") ~= nil and absent.triage ~= "" and not text.contains(absent.triage, "accel_bringup="), here.triage .. " / " .. absent.triage)
if absent.triage:find("accel_filtered=%d+%([^)]*npu") then T:arm("6b and the lane reaches the pool", num(here, "eligible") > num(absent, "eligible"), here.triage .. " / " .. absent.triage)
else out.line("skip: 6b the ledger carries no ready npu work") end
local at = {}
for _, mine in ipairs{ "gpu:nvidia:usable", "gpu:nvidia:usable,npu:intel:unusable", "gpu:nvidia:usable,npu:intel:usable", "none" } do at[#at + 1] = routed("macuahuitl", 0, mine).epic or "-" end
T:arm("8 a host's own capabilities do not move where it is pointed", at[1] ~= "-" and distinct(at) == 1, table.concat(at, " "))
T:finish()
