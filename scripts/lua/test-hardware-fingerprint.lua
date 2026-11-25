-- @trace order:805-r98w, order:1375-2x4e, order:2333-rqjn
--
-- test-hardware-fingerprint.lua — scripts/hardware-fingerprint.sh REFUSES a twin
-- claim that is not true. Ported from the .sh (2333-rqjn).
--
--   1 the same machine model with another kernel/hostname is a twin
--   2 two CPU parts are not twins though every other field, the GPU name included,
--     agrees, and the refusal names the field (AMD ships the 840M and 860M under
--     one PCI name). same-gpu-different-cpu.json is yoga's document with only the
--     CPU changed, a CONSTRUCTED variant, not any host's report
--   3 a document fingerprints the same from any directory
--   4 a document with no CPU device refuses (exit 2) in both modes: every such
--     document would otherwise hash alike
--   5 two unreadable documents are refused (exit 2), never twins
--   6 the JSON view carries every field the canonical string hashes
--   7 a cross-vantage pair is refused, not given a hardware verdict
--   8 no jq: an exit-127 jq stub first on PATH changes nothing and is never called
--     (a control call proves the stub is the jq that PATH resolves)
--
-- Verdict: ok:hardware-fingerprint:<n> arms | violation:hardware-fingerprint:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("hardware-fingerprint")
local ROOT = fixture.repo_root()
local SH = fixture.posix_shell()
local FP = ROOT .. "/scripts/hardware-fingerprint.sh"
local FIX = "scripts/fixtures/hardware-fingerprint/"
local YOGA, OTHER, SYN = ROOT .. "/" .. FIX .. "yoga-linux.json", ROOT .. "/" .. FIX .. "yoga-linux-other-install.json",
    ROOT .. "/" .. FIX .. "same-gpu-different-cpu.json"
local W = T:scratch()
local function fp(args, extra)
    local a = { SH, FP, timeout_ms = 60000 }
    for k, v in pairs(extra or {}) do a[k] = v end
    for _, x in ipairs(args) do a[#a + 1] = x end
    local r = T:run(a)
    return r.code, r.stdout or "", (r.stdout or "") .. (r.stderr or "")
end
local function has(s, w) return s:find(w, 1, true) ~= nil end

local c, o, all = fp{ "compare", YOGA, OTHER }
T:arm("1 another kernel and hostname is still a twin", c == 0 and o:sub(1, 5) == "twin:", all)

c, o, all = fp{ "compare", YOGA, SYN }
local doc, syn = json.parse(fs.read(FIX .. "yoga-linux.json")), json.parse(fs.read(FIX .. "same-gpu-different-cpu.json"))
local function gpu(x) for _, dev in ipairs(x.devices) do if dev.device_class == "gpu" then return dev.name end end end
T:arm("2 two CPU parts are NOT TWINS, naming cpu_model", c ~= 0 and has(all, "NOT TWINS") and has(all, "cpu_model"), "rc=" .. tostring(c) .. " " .. all)
T:arm("2 both documents share one GPU model string", gpu(doc) ~= nil and gpu(doc) == gpu(syn), tostring(gpu(doc)) .. " vs " .. tostring(gpu(syn)))

local ca, a = fp{ YOGA }
local cb, b = fp({ YOGA }, { cwd = "/" })
T:arm("3 one document, one fingerprint, from any directory", ca == 0 and cb == 0 and a ~= "" and a == b, a .. " vs " .. b)

local nocpu = json.parse(fs.read(FIX .. "yoga-linux.json"))
local kept = {}
for _, dev in ipairs(nocpu.devices) do if dev.device_class ~= "cpu" then kept[#kept + 1] = dev end end
nocpu.devices = kept
fs.write(W.rel .. "/nocpu.json", json.encode(nocpu))
T:arm("4 no CPU device: --json refuses with 2", #kept > 0 and fp{ "--json", W.abs .. "/nocpu.json" } == 2, "rc=" .. tostring((fp{ "--json", W.abs .. "/nocpu.json" })))
T:arm("4 no CPU device: the plain fingerprint refuses with 2", fp{ W.abs .. "/nocpu.json" } == 2, "rc=" .. tostring((fp{ W.abs .. "/nocpu.json" })))

c, o, all = fp{ "compare", "/nonexistent/a.json", "/nonexistent/b.json" }
T:arm("5 two unreadable documents are refused with 2 and said so", c == 2 and has(all:lower(), "cannot read"), "rc=" .. tostring(c) .. " " .. all)

c, o, all = fp{ "--json", YOGA }
local okv, view = pcall(json.parse, o)
local lost = {}
for _, f in ipairs({ "cpu_model", "cpu_physical", "cpu_logical", "gpu_model", "npu_vendor", "npu_node", "ram_class_gb" }) do
    if not okv or type(view) ~= "table" or not o:find('"' .. f .. '"%s*:') then lost[#lost + 1] = f end
end
T:arm("6 the JSON view carries every hashed field", c == 0 and #lost == 0, "lost " .. table.concat(lost, ",") .. " " .. all)

local cross = json.parse(fs.read(FIX .. "yoga-linux.json"))
cross.host.host_kind = "windows"
fs.write(W.rel .. "/cross.json", json.encode(cross))
c, o, all = fp{ "compare", YOGA, W.abs .. "/cross.json" }
T:arm("7 a cross-vantage pair is refused, with no hardware verdict", c == 2 and has(all, "refused:cross-vantage-comparison") and not has(all, "NOT TWINS"),
    "rc=" .. tostring(c) .. " " .. all)

fs.mkdir(W.rel .. "/stub")
fs.write(W.rel .. "/stub/jq", '#!/bin/sh\necho "jq $*" >> "${JQ_STUB_LOG:?}"\nexit 127\n')
T:must{ "chmod", "+x", W.abs .. "/stub/jq" }
fs.write(W.rel .. "/calls", "")
fs.write(W.rel .. "/under.sh", 'PATH="$STUB:$PATH"; export PATH\nif [ "$1" = --control ]; then jq --control; exit 0; fi\nexec "$BASH" "$@"\n')
local function under(args)
    local ar = { SH, W.abs .. "/under.sh", env = { STUB = W.abs .. "/stub", JQ_STUB_LOG = W.abs .. "/calls" }, timeout_ms = 60000 }
    for _, x in ipairs(args) do ar[#ar + 1] = x end
    return T:run(ar)
end
local function calls() local n = 0; for _ in fs.read(W.rel .. "/calls"):gmatch("\n") do n = n + 1 end; return n end
under{ "--control" }
T:arm("8 CONTROL the stub is the jq this PATH resolves", calls() == 1, calls() .. " calls")
local s = under{ FP, YOGA }
T:arm("8 the fingerprint is identical with jq shadowed", s.code == 0 and s.stdout == a, tostring(s.stdout) .. (s.stderr or "") .. " vs " .. a)
s = under{ FP, "--json", YOGA }
T:arm("8 --json works with jq shadowed", s.code == 0, s.stderr)
T:arm("8 jq was never called", calls() == 1, fs.read(W.rel .. "/calls"))
T:finish()
