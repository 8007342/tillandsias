-- @trace order:2399-vsok
--
-- test-relay-preflight-vm-fixture-opt-in.lua — the relay preflight never runs a
-- fixture that drives the macOS VM unless the run opts in (2399-vsok).
--
-- On 2026-11-26 a relay preflight selected test-macos-vsock-inference-closure.sh
-- because it names a path the diff touched, and it drove the operator's VM through
-- an installed dev tray for ~300 s. A fixture that drives the VM now says so in its
-- header (`# drives-vm: <why>`), and relay-preflight.sh names it skipped unless
-- TILLANDSIAS_RELAY_DRIVE_VM=1.
--
-- Arms
--   1 MARKED       the decider block, extracted, skips a marked fixture by default
--   2 OPT-IN       ... and runs it under TILLANDSIAS_RELAY_DRIVE_VM=1
--   3 UNMARKED     an unmarked fixture always runs
--   4 REASONLESS   `# drives-vm:` with no reason is not a declaration: it runs
--   5 WIRED        the fixture loop asks the decider BEFORE it runs the fixture,
--                  and names the skip with the opt-in that lifts it
--   6 CENSUS       every scripts/test-*.sh that starts the installed tray or execs
--                  in the guest carries the marker (the closure fixture among them)
--
-- Nothing here runs relay-preflight.sh or any VM-driving fixture: the decider is
-- extracted and run against scratch files.
--
-- Usage: tillandsias-plan script run scripts/lua/test-relay-preflight-vm-fixture-opt-in.lua

local fixture = require "common.fixture"
local T = fixture.new("relay-preflight-vm-fixture-opt-in")
local SH = fixture.posix_shell()
local SUBJECT = "scripts/relay-preflight.sh"
local src = fs.read(SUBJECT)
if not src then T:refuse("subject-absent", SUBJECT) end

-- The decider lives between markers so it can be run alone.
local block = src:match("# BEGIN%-DRIVES%-VM\n(.-)# END%-DRIVES%-VM")
local W = T:scratch("vm")
local function plant(name, header)
    fs.write(W.rel .. "/" .. name, "#!/usr/bin/env bash\n" .. header .. "echo ran\n")
    return W.abs .. "/" .. name
end
local marked = plant("test-marked.sh", "# drives-vm: boots the guest through the installed tray\n")
local unmarked = plant("test-plain.sh", "# an ordinary fixture\n")
local reasonless = plant("test-reasonless.sh", "# drives-vm:\n")

local function decide(path, optin)
    if not block then return "no-decider" end
    fs.write(W.rel .. "/decide.sh", block .. '\nif _drives_vm "$1"; then echo skip; else echo run; fi\n')
    local argv = { SH, W.abs .. "/decide.sh", path }
    if optin then argv.env = { TILLANDSIAS_RELAY_DRIVE_VM = "1" }
    else argv.env_unset = { "TILLANDSIAS_RELAY_DRIVE_VM" } end
    return text.trim(T:run(argv).stdout or "")
end

local d1 = decide(marked, false)
T:arm("1 MARKED a fixture declaring drives-vm is skipped by default", d1 == "skip", d1)
local d2 = decide(marked, true)
T:arm("2 OPT-IN TILLANDSIAS_RELAY_DRIVE_VM=1 runs it", d2 == "run", d2)
local d3 = decide(unmarked, false)
T:arm("3 UNMARKED an ordinary fixture runs", d3 == "run", d3)
local d4 = decide(reasonless, false)
T:arm("4 REASONLESS a declaration with no reason is not honoured", d4 == "run", d4)

-- 5 the loop: the decider is asked before _cap runs the fixture, and the skip is named.
local loop = src:match("_fx_ran=0\n(.-)done <<FXEOF2") or ""
local ask = loop:find('_drives_vm "$_fx"', 1, true)
-- 2415-ea3h: the run call is `_cap "${_fx_cmd[@]}"` (bash for .sh, the runner for .lua).
local cap = loop:find('_cap "${_fx_cmd[@]}"', 1, true)
T:arm("5 WIRED the fixture loop asks _drives_vm before it runs a fixture, and names the opt-in",
    ask ~= nil and cap ~= nil and ask < cap and text.contains(loop, "TILLANDSIAS_RELAY_DRIVE_VM=1"),
    "ask=" .. tostring(ask) .. " cap=" .. tostring(cap))

-- 6 census over the population relay-preflight selects from.
local ls = T:run{ "git", "ls-files", "scripts/test-*.sh" }
local missing = {}
local closure_marked = false
for _, f in ipairs(text.lines(ls.stdout or "")) do
    local body = fs.read(f) or ""
    local drives = body:find("Tillandsias.app/Contents/MacOS/tillandsias-tray", 1, true) or body:find("--exec-guest", 1, true)
    local declared = body:match("\n# drives%-vm: %S") ~= nil
    if drives and not declared then missing[#missing + 1] = f end
    if f == "scripts/test-macos-vsock-inference-closure.sh" then closure_marked = declared end
end
T:arm("6 CENSUS every test-*.sh that starts the tray or execs in the guest declares drives-vm",
    #missing == 0 and closure_marked, "undeclared: " .. table.concat(missing, " ") .. " closure_marked=" .. tostring(closure_marked))

T:finish()
