-- @env TILLANDSIAS_WINHOST_PS_JSON_FILE
-- @read-env TILLANDSIAS_WINHOST_PS_JSON_FILE
-- @trace order:806-2r4s, order:809-7e4m, order:808-7yrd, order:2421-7wvs
--
-- windows-host-capability-probe.lua — PORTED from scripts/windows-host-capability-probe.sh (2421-7wvs).
-- Emit this Windows machine's capability contribution, observed from the WINDOWS HOST locus.
--
-- WHY THIS EXISTS AT ALL, because it looks like duplication of the in-guest probe and is not. On
-- Windows one machine is observed from two execution contexts and NEITHER sees the whole machine:
--   the WSL2 guest sees  cpu, and the paravirtual gpu via /dev/dxg
--   only Windows sees    the NPU, the true GPU name, and the real RAM
-- The NPU is STRUCTURALLY invisible in the guest: WSL2 passes through no PCI, so /dev/accel* is
-- absent and no device matches 1022:17f0 (809-7e4m). The RAM differs too: the guest reports its VM
-- slice, not the machine. A row assembled from one context is confidently wrong.
--
-- Output is a CapabilityDocument on stdout, or with --fragment a ready-to-file `capabilities:` row
-- carrying `locus: windows-host`, half of the matrix fold key: without it this contribution would
-- OVERWRITE the guest's row for the same host_id (808-7yrd). Not a replacement for the in-guest
-- probe; this one deliberately reports no CPU.
--
-- Usage: tillandsias-plan script run --helper scripts/lua/windows-host-capability-probe.lua -- [--fragment] [--host-id ID] [--ts ISO8601]
-- A --helper (2049-w2q6): stdout is the document alone, never a verdict line, so it can be
-- redirected straight into a fragment. Exit 0 with the document; any failure (usage, no
-- powershell.exe, the device query failed or returned nothing) raises, exit 1 with the reason on
-- stderr. The .sh distinguished 2/3/4; nothing branched on them (no caller in the tree).
-- Test seam: TILLANDSIAS_WINHOST_PS_JSON_FILE names a file holding the PowerShell JSON, so a fixture
-- runs every non-Windows step without a device query.
--
-- Differences from the .sh, all deliberate: no jq (the runner's json module); key order in the
-- emitted JSON follows serde's map order, not jq's insertion order, so compare parsed, not bytes;
-- the PowerShell query lives in scripts/windows-host-capability-query.ps1, run with -File.

local USAGE = [[
usage: windows-host-capability-probe.lua [--fragment] [--host-id ID] [--ts ISO8601]

  --fragment   emit a `capabilities:` ledger row instead of a bare document
  --host-id    override the derived machine name (default: short hostname,
               lowercased -- the same identifier that names
               plan/mo-full-attestations.d/<host>.md)
  --ts         override the timestamp (default: now, UTC)

Reads nothing and writes nothing; the document goes to stdout.]]

local fragment, host_id, ts = false, "", ""
HELP = false
local i = 1
while i <= #arg do
    local a = arg[i]
    if a == "--fragment" then fragment = true
    elseif a == "--host-id" then i = i + 1; host_id = arg[i] or ""
    elseif a == "--ts" then i = i + 1; ts = arg[i] or ""
    elseif a == "-h" or a == "--help" then out.line(USAGE); HELP = true
    else
        log.raw("error: unknown argument: " .. a); log.raw(USAGE)
        error("windows-host-capability-probe: usage: unknown argument " .. a, 0)
    end
    i = i + 1
end
if HELP then do return end end

-- The same chain as scripts/agent-identity.sh tillandsias_node_name: short hostname, domain
-- stripped, lowercased (the matrix fold key and the attestation filename must be one string).
if host_id == "" then
    for _, argv in ipairs({ { "hostname", "-s" }, { "hostname" }, { "uname", "-n" } }) do
        local r = proc.run({ argv = argv, timeout_ms = 10000 })
        local h = text.trim(r.ok and r.stdout or "")
        if h ~= "" then host_id = h; break end
    end
    host_id = (host_id:gsub("%..*$", "")):lower()
    if host_id == "" then host_id = "unknown" end
end
if ts == "" then ts = time.utc_iso and time.utc_iso() or os.date("!%Y-%m-%dT%H:%M:%SZ") end

-- One PowerShell invocation emitting JSON (each launch costs ~200 ms, and a partial failure across
-- several would leave the document half-observed). THE DEVICE FILTER IS A CLASS, NEVER A NAME
-- REGEX: /NPU/ matched four USB "I-npu-t" HID devices (2026-08-18). Class ComputeAccelerator is exact.
local PS_FILE = "scripts/windows-host-capability-query.ps1"
local seam = env.get("TILLANDSIAS_WINHOST_PS_JSON_FILE")
local ps_json
if seam and seam ~= "" then
    ps_json = fs.read(seam)
else
    -- -ExecutionPolicy Bypass is this one process's own setting (no machine or user policy changes):
    -- a checked-in, unsigned .ps1 would otherwise be refused under Windows' default policy.
    local r = proc.run({ argv = { "powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
        "-File", PS_FILE }, timeout_ms = 120000 })
    if r.status == "spawn_failed" then
        log.raw("error: powershell.exe is required and was not found on PATH")
        error("windows-host-capability-probe: no-powershell", 0)
    end
    if not r.ok then
        log.raw("error: the Windows device query failed")
        error("windows-host-capability-probe: query-failed (rc=" .. tostring(r.code) .. ") " .. (r.stderr or ""):sub(1, 300), 0)
    end
    ps_json = r.stdout or ""
end
if text.trim(ps_json or "") == "" then
    log.raw("error: the Windows device query returned nothing")
    error("windows-host-capability-probe: query-empty", 0)
end
local ok, q = pcall(json.parse, ps_json)
if not ok or type(q) ~= "table" then
    log.raw("error: the Windows device query returned no JSON object")
    error("windows-host-capability-probe: query-unparseable", 0)
end

-- STATUS=OK IS REPORTED, AND SEPARATELY FROM USABILITY. A device Windows calls healthy is still
-- unusable BY US: every engine runs inside the guest, which cannot reach it (806-2r4s). The two
-- reason strings are the fleet's existing vocabulary.
-- JSON null: json.null is nil in this runner (a key set to it vanishes), so take the sentinel that
-- json.parse itself returns for null, which json.encode writes back as null.
local NULL = json.parse("[null]")[1]
local function nz(v) if v == nil or v == NULL then return nil end return v end
local function vendor(id)
    id = nz(id) or ""
    if id:find("VEN_1022", 1, true) or id:find("VEN_1002", 1, true) then return "amd" end
    if id:find("VEN_8086", 1, true) then return "intel" end
    if id:find("VEN_10DE", 1, true) then return "nvidia" end
    return "unknown"
end
local function dev(d, class, reason)
    return {
        device_class = class, vendor = vendor(d.instance_id), name = nz(d.name) or "unknown",
        device_node = nz(d.instance_id) or NULL, fw_version = NULL, driver = nz(d.driver) or NULL,
        usable = false, unusable_reason = reason, lanes = json.array(),
        memory_bandwidth_gbps = NULL, memory_bandwidth_source = "unknown", cpu_flags = NULL,
        cpu_cores = NULL, system_ram_gb = NULL, os_status = nz(d.status) or "unknown",
    }
end
-- PowerShell's ConvertTo-Json renders a one-element array as that element (no [ ]), so a single
-- device arrives as an object; the .sh's `.npus[]` iterated an object's VALUES in that case. Here a
-- lone object is taken as the one device it is.
local function list(v)
    v = nz(v)
    if v == nil then return {} end
    if v.name ~= nil or v.instance_id ~= nil or v.status ~= nil then return { v } end
    return v
end
local devices = json.array()
for _, d in ipairs(list(q.npus)) do devices[#devices + 1] = dev(d, "npu", "wsl2-npu-not-exposed") end
for _, d in ipairs(list(q.gpus)) do devices[#devices + 1] = dev(d, "gpu", "wsl2-no-dri-render-node") end
local doc = {
    schema_version = 2, legacy_tier = "cpu", devices = devices,
    engines = json.array(), measurements = json.array(),
    host = {
        is_battery_present = true, kernel_release = nz(q.os_version) or "unknown", host_id = host_id,
        host_id_source = "node-name", host_kind = "windows",
        system_ram_gb = (tonumber(nz(q.ram_bytes)) or 0) / 1073741824,
    },
    timestamp = ts,
}
local pretty = json.encode(doc, { pretty = true })
if not fragment then
    out.line(pretty)
    do return end
end
-- A ledger row ready for plan/index.d/. `locus` is mandatory: without it the fold refuses the row
-- rather than letting it collide with the guest's contribution (808-7yrd).
out.line("# Ledger fragment -- append-only, IMMUTABLE once written.")
out.line("# Generated by scripts/lua/windows-host-capability-probe.lua at " .. ts .. ".")
out.line("#")
out.line("# The WINDOWS-HOST half of this machine's capability row. The guest half is")
out.line("# contributed separately with locus: in-guest; the two are keyed apart and a")
out.line("# consumer assembles them (809-7e4m).")
out.line("")
out.line("capabilities:")
out.line('  - ts: "' .. ts .. '"')
out.line("    host: windows")
out.line("    locus: windows-host")
out.line("    document:")
for _, l in ipairs(text.lines(pretty)) do out.line("      " .. l) end
