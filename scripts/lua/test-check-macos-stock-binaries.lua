-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
-- @trace spec:macos-native-tray, order:1420-umka, order:2109-umac
--
-- test-check-macos-stock-binaries.lua — fixture for
-- scripts/lua/check-macos-stock-binaries.lua. Ported from
-- scripts/test-check-macos-stock-binaries.sh (2109-umac) onto the scratch.*
-- door, with the same seven arms. Hermetic: each arm copies the checked sources
-- into a scratch root, mutates one thing in the COPY, and runs the lint as a
-- child with TILLANDSIAS_MACOS_STOCK_ROOT, so the checkout is never edited.
--
--   1  the current tree passes
--   2  MUTATION: an added Command::new("qemu-img") in vz.rs is refused, naming it
--   3  MUTATION: hdiutil back to a bare name is refused (the pre-fix state)
--   4  MUTATION: a bare name through the tray's spawn_bounded helper is refused
--   5  MUTATION: the installer's PATH pin removed is refused
--   6  MUTATION: a PATH pin that adds /opt/homebrew/bin is refused
--   7  CONTROL: an added absolute stock spawn (/usr/bin/true) still passes
-- Each mutation asserts it APPLIED, so an arm cannot pass on an unchanged copy.
--
-- USAGE   tillandsias-plan script run scripts/lua/test-check-macos-stock-binaries.lua
-- GRAMMAR ok:check-macos-stock-binaries:7 (exit 0) | violation:check-macos-stock-binaries:<n> (exit 1)

local fixture = require "common.fixture"
local T = fixture.new("check-macos-stock-binaries")

local ROOT = fixture.repo_root()
local PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN")
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_PLAN_BIN") end
-- Otherwise the checkout's own build, release first (what preflight runs).
for _, rel in ipairs({ "target/release/tillandsias-plan", "target/debug/tillandsias-plan" }) do
    if (not PLAN or PLAN == "") and fs.exists(rel) then PLAN = ROOT .. "/" .. rel end
end
if not PLAN or PLAN == "" then T:skip("no-plan-binary (TILLANDSIAS_SCRIPT_RUNNER_BIN, TILLANDSIAS_PLAN_BIN or target/*/tillandsias-plan)") end
local LINT = ROOT .. "/scripts/lua/check-macos-stock-binaries.lua"

-- What the lint reads: the tray's src tree, two vm-layer files, the installer.
local ls = proc.run{ argv = { "git", "-C", ROOT, "ls-files", "crates/tillandsias-macos-tray/src" } }
local SOURCES = text.lines(ls.stdout or "")
for _, p in ipairs({ "crates/tillandsias-vm-layer/src/vz.rs", "crates/tillandsias-vm-layer/src/materialize/macos.rs",
        "scripts/install-macos.sh" }) do
    SOURCES[#SOURCES + 1] = p
end
if #SOURCES < 4 then T:refuse("setup-failed", "git ls-files found no tray sources") end
local CONTENT = {}
for _, p in ipairs(SOURCES) do if p ~= "" then CONTENT[p] = fs.read(p) end end

local VZ = "crates/tillandsias-vm-layer/src/vz.rs"
local INST = "scripts/install-macos.sh"
local UUID = "crates/tillandsias-macos-tray/src/installation_uuid.rs"

-- A fresh scratch root holding exactly what the lint reads.
local function fresh(tag)
    local d = T:scratch(tag)
    for p, body in pairs(CONTENT) do
        local dir = p:match("^(.*)/[^/]+$")
        if dir then scratch.mkdir(d.leaf .. "/" .. dir) end
        scratch.write(d.leaf .. "/" .. p, body)
    end
    return d
end
local function lint(d)
    local r = proc.run{ argv = { PLAN, "script", "run", LINT }, cwd = ROOT, timeout_ms = 60000,
        env = { TILLANDSIAS_MACOS_STOCK_ROOT = d.abs, TILLANDSIAS_SCRIPT_RUNNER_BIN = PLAN } }
    return (r.status == "exited") and r.code or -1, (r.stdout or "") .. (r.stderr or "")
end
local function tail(o)
    local l = text.lines(o)
    return table.concat({ l[#l - 2] or "", l[#l - 1] or "", l[#l] or "" }, " | ")
end
-- Replace the first occurrence of `from` in the copy's file; returns whether it applied.
local function sub_once(d, p, from, to)
    local body = scratch.read(d.leaf .. "/" .. p)
    local s, e = body:find(from, 1, true)
    if not s then return false end
    scratch.write(d.leaf .. "/" .. p, body:sub(1, s - 1) .. to .. body:sub(e + 1))
    return true
end
local function append(d, p, s) scratch.write(d.leaf .. "/" .. p, scratch.read(d.leaf .. "/" .. p) .. s) end

local d, rc, o, applied

d = fresh("a1"); rc, o = lint(d)
T:arm("ARM 1: the current tree passes", rc == 0 and text.contains(o, "ok:macos-stock-binaries:"), "rc=" .. rc .. " " .. tail(o))

d = fresh("a2"); append(d, VZ, '\nfn regression() { let _ = std::process::Command::new("qemu-img"); }\n')
rc, o = lint(d)
T:arm("ARM 2: an added qemu-img spawn is refused and named",
    rc == 1 and text.contains(o, 'spawns "qemu-img"') and text.contains(o, "violation:macos-stock-binaries:1"),
    "rc=" .. rc .. " " .. tail(o))

d = fresh("a3"); applied = sub_once(d, VZ, 'Command::new("/usr/bin/hdiutil")', 'Command::new("hdiutil")')
rc, o = lint(d)
T:arm("ARM 3: a bare hdiutil is refused", applied and rc == 1 and text.contains(o, 'spawns "hdiutil"'),
    "applied=" .. tostring(applied) .. " rc=" .. rc .. " " .. tail(o))

d = fresh("a4"); applied = sub_once(d, UUID, 'spawn_bounded("/usr/bin/security",', 'spawn_bounded("security",')
rc, o = lint(d)
T:arm("ARM 4: a bare name through spawn_bounded is refused", applied and rc == 1 and text.contains(o, 'spawns "security"'),
    "applied=" .. tostring(applied) .. " rc=" .. rc .. " " .. tail(o))

local PIN = "export PATH=/usr/bin:/bin:/usr/sbin:/sbin\n"
d = fresh("a5"); applied = sub_once(d, INST, "\n" .. PIN, "\n")
rc, o = lint(d)
T:arm("ARM 5: removing the installer's PATH pin is refused",
    applied and rc == 1 and text.contains(o, "install-macos.sh: the first statement after"),
    "applied=" .. tostring(applied) .. " rc=" .. rc .. " " .. tail(o))

d = fresh("a6"); applied = sub_once(d, INST, "\n" .. PIN, "\nexport PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin\n")
rc, o = lint(d)
T:arm("ARM 6: a PATH pin that adds Homebrew is refused",
    applied and rc == 1 and text.contains(o, "install-macos.sh: the first statement after"),
    "applied=" .. tostring(applied) .. " rc=" .. rc .. " " .. tail(o))

d = fresh("a7"); append(d, VZ, '\nfn fine() { let _ = std::process::Command::new("/usr/bin/true"); }\n')
rc, o = lint(d)
T:arm("ARM 7 (control): an absolute stock spawn still passes", rc == 0 and text.contains(o, "ok:macos-stock-binaries:"),
    "rc=" .. rc .. " " .. tail(o))

T:finish()
