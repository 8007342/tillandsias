-- @env PATH
-- @trace order:851-gpb5, order:2356-d66j
--
-- test-derive-host-identity.lua — scripts/derive-host-identity.sh against KNOWN hardware
-- strings: lspci, nvidia-smi, hostname, uname and sysctl are stubs, and /dev/accel is the
-- SUT's root override. Every stub ANSWERS (an empty or failing one shadows the real tool;
-- deleting it would measure this machine). Ported from the .sh (2356-d66j).
--
-- The two traps, both seen on macuahuitl 2026-08-22: "VGA compatible controller" contains
-- ati, and "Non-VGA unclassified device" contains vga: substring matches on a sentence
-- that should have been a parsed field.
--
-- Verdict: ok:derive-host-identity:<n> | violation:derive-host-identity:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("derive-host-identity")
local SH = fixture.posix_shell()
local SUT = fixture.repo_root() .. "/scripts/derive-host-identity.sh"
local W = T:scratch()
fs.mkdir(W.rel .. "/bin"); fs.mkdir(W.rel .. "/none"); fs.mkdir(W.rel .. "/npu")
fs.write(W.rel .. "/npu/accel0", "")
local function stub(name, body)
    fs.write(W.rel .. "/bin/" .. name, "#!/usr/bin/env bash\n" .. body)
    T:must{ "chmod", "+x", W.abs .. "/bin/" .. name }
end
local function says(name, s) stub(name, "printf '%s\\n' '" .. s .. "'\n") end
-- lspci -mm emits quote-delimited fields: class, vendor, device.
local function lspci(...) stub("lspci", "cat <<'PCI'\n" .. table.concat({ ... }, "\n") .. "\nPCI\n") end
local function dev(class, vendor, name) return '01:00.0 "' .. class .. '" "' .. vendor .. '" "' .. name .. '" -r a1 "" ""' end
local function run(args, accel)
    local argv = { SH, SUT }
    for _, a in ipairs(args or {}) do argv[#argv + 1] = a end
    argv.env = { PATH = W.abs .. "/bin:" .. env.get("PATH"), TILLANDSIAS_ACCEL_DEV_ROOT = W.abs .. "/" .. (accel or "none") }
    argv.env_unset = { "TILLANDSIAS_*" }
    local r = T:run(argv)
    return r.stdout or "", r.code
end
local function slug(a) return text.trim((run(nil, a))) end
local function accel(a) return ("\n" .. (run({ "--explain" }, a))):match("\naccel\t([^\t\n]*)") end
local function ck(name, want, got) T:arm(name, want == got, "expected " .. tostring(want) .. ", " .. tostring(got)) end
local NVIDIA = dev("VGA compatible controller", "NVIDIA Corporation", "GA106M")
local AMD = "Advanced Micro Devices, Inc. [AMD/ATI]"

says("uname", "Linux"); says("sysctl", ""); says("hostname", "trapbox"); stub("nvidia-smi", "exit 1\n")
lspci(dev("VGA compatible controller", "NVIDIA Corporation", "GA102GL [RTX A5000]"), dev("Non-VGA unclassified device", "Intel Corporation", "Device 7f2f"))
ck("a pure-NVIDIA host does NOT report amd (comp-ATI-ble trap)", "nvidia", accel())
lspci(dev("Non-VGA unclassified device", "Intel Corporation", "Device 7f2f"))
ck("a Non-VGA line alone yields no GPU at all (Non-VGA trap)", "none", accel())
lspci(NVIDIA, dev("VGA compatible controller", AMD, "Rembrandt"))
ck("the dual-vendor Silverblue laptop reports both, sorted", "amd+nvidia", accel())
lspci(dev("VGA compatible controller", "Intel Corporation", "Alder Lake-N [UHD Graphics]"))
ck("the low-end Intel laptop reports intel only", "intel", accel())
lspci(dev("Display controller", AMD, "Raphael"))
ck("a Display-controller-class AMD part is still found", "amd", accel())
-- Both directions: a detector that never fires is invisible.
lspci(dev("VGA compatible controller", AMD, "Phoenix"))
ck("no accel device -> no npu token", "amd", accel())
ck("an accel device -> npu token, sorted into the set", "amd+npu", accel("npu"))

lspci(NVIDIA)
says("hostname", "alpha"); local a, again = slug(), slug()
says("hostname", "beta"); local b = slug()
T:arm("identical hardware, different hostname -> DIFFERENT slug", a ~= "" and a ~= b, a .. " / " .. b)
ck("the hostname is the trailing component", "beta", b:match("([^-]*)$"))
ck("deterministic across invocations", a, again)
says("hostname", "Yoga_ThinkPad")
T:arm("hostname is slugified, not passed through", slug():find("%-yoga%-thinkpad$"), slug())

says("hostname", "degraded"); lspci()
ck("lspci reporting no display device -> accel is 'none', not a crash", "none", accel())
local _, rc = run()
ck("a degraded probe still exits 0", 0, rc)

-- The macOS branch, on every host: the SUT docstring's own example shape.
says("uname", "Darwin"); says("sysctl", "Apple M5"); says("hostname", "airbook")
ck("the Darwin branch derives the documented macOS shape", "macos-m5-apple-airbook", slug())
says("uname", "Linux"); says("sysctl", "")

local o
o, rc = run{ "--help" }
ck("--help exits 0", 0, rc)
T:arm("--help prints usage", o:find("usage: derive-host-identity.sh", 1, true) == 1, o:sub(1, 200))
_, rc = run{ "--bogus" }
ck("an unknown argument exits 2", 2, rc)
o = run()
T:arm("a bare run prints exactly one line", o:find("^[^\n]+\n$"), o)
T:finish({ ok = function(n) return "ok:derive-host-identity:" .. n end })
