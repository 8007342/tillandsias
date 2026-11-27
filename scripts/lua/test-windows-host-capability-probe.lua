-- @env PATH HOME
-- @trace order:2421-7wvs
--
-- test-windows-host-capability-probe.lua — the Lua port answers exactly what
-- scripts/windows-host-capability-probe.sh answered, on the same PowerShell JSON.
--
--   1 canned JSON (one NPU, two GPUs)
--     gives the document's devices, vendors, reasons, nulls and RAM
--   2 PARITY: the pinned .sh blob (0f388bf, the last .sh) with a powershell.exe stub prints the same
--     document, compared parsed (jq's key order is not serde's). Skips by name without jq.
--   3 --fragment is a capabilities: row with locus windows-host that loads as YAML
--   4 an unknown argument fails (exit 1) and names it
--
-- Usage: tillandsias-plan script run scripts/lua/test-windows-host-capability-probe.lua
-- Verdict: ok:windows-host-capability-probe-fixture:<n> arms | violation:...:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("windows-host-capability-probe-fixture")
local PLAN, ROOT, SH = fixture.plan_binary(), fixture.repo_root(), fixture.posix_shell()
if PLAN == "" then T:refuse("no-plan-binary") end
if not fixture.is_abs(PLAN) then PLAN = ROOT .. "/" .. PLAN:gsub("^%./", "") end
local W = T:scratch()
local SH_BLOB = "0f388bfe9dec25bbe62b8a25ad9127afa9d953a7"

local PS_JSON = '{"ram_bytes":17179869184,"os_version":"10.0.26300",'
    .. '"npus":[{"name":"NPU Compute Accelerator Device","status":"OK","instance_id":"PCI\\\\VEN_1022&DEV_17F0","driver":"32.0.203.257"}],'
    .. '"gpus":[{"name":"AMD Radeon","status":"OK","instance_id":"PCI\\\\VEN_1002&DEV_150E","driver":null},'
    .. '{"name":"Intel UHD","status":"Error","instance_id":"PCI\\\\VEN_8086&DEV_1","driver":"1.0"}]}'
fs.write(W.rel .. "/ps.json", PS_JSON)

local function probe(args)
    local argv = { PLAN, "script", "run", "--helper", ROOT .. "/scripts/lua/windows-host-capability-probe.lua", "--" }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    argv.cwd, argv.env, argv.timeout_ms = ROOT, { TILLANDSIAS_WINHOST_PS_JSON_FILE = W.abs .. "/ps.json" }, 60000
    local r = T:run(argv)
    return r.code, r.stdout or "", r.stderr or ""
end
local FIX = { "--ts", "2026-11-26T00:00:00Z", "--host-id", "fixturehost" }

-- 1
local rc, o, e = probe(FIX)
local ok, d = pcall(json.parse, o)
local good = ok and type(d) == "table" and rc == 0
local why = "rc=" .. tostring(rc) .. " " .. e:sub(1, 200)
if good then
    local dv = d.devices or {}
    local n, g1, g2 = dv[1] or {}, dv[2] or {}, dv[3] or {}
    good = #dv == 3 and n.device_class == "npu" and n.vendor == "amd" and n.unusable_reason == "wsl2-npu-not-exposed"
        and g1.device_class == "gpu" and g1.vendor == "amd" and g1.unusable_reason == "wsl2-no-dri-render-node"
        and g2.vendor == "intel" and g2.os_status == "Error" and n.usable == false
        and type(g1.driver) == "userdata" and type(n.fw_version) == "userdata"
        and d.host.system_ram_gb == 16 and d.host.host_id == "fixturehost" and d.host.kernel_release == "10.0.26300"
        and d.timestamp == "2026-11-26T00:00:00Z" and d.schema_version == 2
    why = why .. " devices=" .. #dv
end
T:arm("1 canned JSON gives the document's devices, vendors, reasons, nulls and RAM", good, why)

-- 2 PARITY against the pinned .sh
local jq = fixture.which("jq")
if not jq then
    out.line("skip: 2 no jq on PATH; the .sh needs it for the parity run")
else
    T:must{ "git", "-C", ROOT, "cat-file", "-e", SH_BLOB }
    local shtext = T:run{ "git", "-C", ROOT, "cat-file", "-p", SH_BLOB }.stdout or ""
    fs.mkdir(W.rel .. "/old/scripts"); fs.mkdir(W.rel .. "/bin")
    fs.write(W.rel .. "/old/scripts/windows-host-capability-probe.sh", shtext)
    fs.write(W.rel .. "/bin/powershell.exe", '#!/bin/sh\ncat "' .. W.abs .. '/ps.json"\n')
    T:must{ "chmod", "+x", W.abs .. "/bin/powershell.exe" }
    local r = T:run{ SH, "-s", "--", W.abs, cwd = ROOT, stdin = [[
# A C:/ entry would split at its colon in an msys PATH, so spell the stub dir /c/... there.
b="$1/bin"; command -v cygpath >/dev/null 2>&1 && b="$(cygpath -u "$b")"
PATH="$b:$PATH"; export PATH
# the .sh's outer check is uname, so on Linux pretend to be Git Bash
uname() { echo MINGW64_NT-fixture; }; export -f uname 2>/dev/null || true
bash "$1/old/scripts/windows-host-capability-probe.sh" --ts 2026-11-26T00:00:00Z --host-id fixturehost
]] }
    local okp, sd = pcall(json.parse, r.stdout or "")
    local function deq(a, b)
        if type(a) ~= type(b) then return false end
        if type(a) ~= "table" then return a == b end
        for k, v in pairs(a) do if not deq(v, b[k]) then return false end end
        for k in pairs(b) do if a[k] == nil then return false end end
        return true
    end
    local same = okp and ok and deq(sd, d)
    T:arm("2 PARITY the pinned .sh prints the same document (parsed)", same,
        "sh rc=" .. tostring(r.code) .. " " .. (r.stderr or ""):sub(1, 200) .. " sh=" .. (r.stdout or ""):sub(1, 120))
end

-- 3
local rcf, of = probe({ "--fragment", table.unpack(FIX) })
fs.write(W.rel .. "/frag.yaml", of)
local vy = T:run{ PLAN, "validate-yaml", W.abs .. "/frag.yaml", timeout_ms = 30000 }
T:arm("3 --fragment is a capabilities: row with locus windows-host that loads as YAML",
    rcf == 0 and text.contains(of, "\ncapabilities:\n") and text.contains(of, "    locus: windows-host\n") and vy.code == 0,
    "rc=" .. tostring(rcf) .. " yaml=" .. tostring(vy.code) .. " " .. (vy.stdout or ""):sub(1, 200))

-- 4
local rcu, ou, eu = probe({ "--bogus" })
T:arm("4 an unknown argument fails (exit 1) and names it", rcu == 1 and text.contains(eu, "--bogus") and ou == "",
    "rc=" .. tostring(rcu) .. " " .. eu:sub(1, 200))
T:finish()
