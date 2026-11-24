-- @trace spec:vm-provisioning-lifecycle
-- @trace order:1253-gina, order:2293-vzod
-- @env TILLANDSIAS_TRAY_BIN HOME
--
-- test-macos-vz-orphan-diagnosis.lua — order 1253-gina. Ported from
-- scripts/test-macos-vz-orphan-diagnosis.sh (2293-vzod, shell-to-lua); the
-- arms, their order, the verdict lines and the subject/image clauses are
-- unchanged.
--
-- WHAT IT PROTECTS. A Virtualization.framework VM runs in an XPC child
-- (`com.apple.Virtualization.VirtualMachine`) that holds the image directory's
-- nvram.bin for as long as the guest lives. While one holds it, EVERY later
-- start dies as:
--
--     Invalid virtual machine configuration. The boot loader is invalid.
--
-- THE MESSAGE IS THE DEFECT, not the holder. That string describes a corrupt
-- EFI store and sends the reader at the disk; the actual state is a HEALTHY
-- image held open by a process the reader does not know exists. The obvious
-- response to a bad boot loader is `--reset-guest`, which DESTROYS the guest
-- disk and the in-VM vault to repair what one `kill` clears. A destructive
-- remedy suggested by a misleading diagnosis is worse than no diagnosis, so
-- what this fixture pins is the TEXT, not just the recovery.
--
-- MEASURED on tlatoanis-macbook-air 2026-09-20 against 56.9.20.1, both halves:
--   live run, helper present            -> lsof nvram.bin = pid 31650
--   SIGKILL the tray directly           -> helper reaped, second run OK
--   helper left alive, second start     -> "boot loader is invalid", and the
--                                          enriched branch named pid 31650
--   follow the printed `kill 31650`     -> identical command then SUCCEEDED
--
-- WHY ARM 2 EXISTS AND IS NOT OPTIONAL. Arm 1 alone — "SIGKILL, then a second
-- run works" — is green on any quiet host that never orphaned anything. It
-- proves a VM started twice, which is not the claim. Arm 2 leaves a live VM
-- holding nvram and requires the SAME assertion to RED, so the arm that passes
-- is known to discriminate. Without it this file measures nothing.
--
-- GRAMMAR — one line, or two on a could-not-run:
--   ^(ok:macos-vz-orphan-diagnosis:[0-9]+|violation:macos-vz-orphan-diagnosis:.*|unsupported:macos-vz-orphan-diagnosis:.*|skip:macos-vz-orphan-diagnosis:.*|refused:macos-vz-orphan-diagnosis:.*)$
-- EVERY verdict line ends with ` subject=[<tray --version line>] image=[...]
-- skew=undetermined-image-records-no-version` (1332-tdde): the whole version
-- line, because two builds can share a version number, and the image's own
-- provision.state, which records no version to compare against.
-- A COULD-NOT-RUN PRINTS TWO LINES, `unsupported:` (the detail) then `skip:`
-- (what the litmus runner scores from the last line; 1330-i4hu).
--
-- PORT NOTES. The live tray runs through proc.spawn of a wrapper that writes
-- its pid and then execs the tray with output to a log, because the .sh's
-- `&` + `grep running: live.log` needs the log while the process lives. The
-- runner confines fs.* to the checkout, so paths under $HOME are read with
-- `test`/`cat`, not fs.

local fixture = require "common.fixture"
local NAME = "macos-vz-orphan-diagnosis"
local SUBJECT = "unresolved"
local HOME = env.get("HOME") or ""

local function run(argv, ms)
    local r = proc.run({ argv = argv, timeout_ms = ms or 60000 })
    return (r.status == "exited") and r.code or -1, r.stdout or "", r.stderr or ""
end
local function pause(sec) proc.run({ argv = { "sleep", sec }, timeout_ms = 30000 }) end

-- WHAT THE IMAGE CAN SAY ABOUT ITSELF (1332-tdde): phase and guest binary hash
-- from provision.state. There is no version field, so skew stays undetermined.
local function image_identity()
    local st = HOME .. "/Library/Application Support/tillandsias/provision/provision.state"
    local rc, body = run({ "cat", st }, 5000)
    if rc ~= 0 then return "no-provision-state" end
    local phase, sha
    for _, l in ipairs(text.lines(body)) do
        phase = phase or l:match("^phase (.*)$")
        sha = sha or l:match("^guest_binary_sha256 (.*)$")
    end
    return "phase=" .. ((phase and phase ~= "") and phase or "unknown")
        .. " guest_binary_sha256=" .. ((sha and sha ~= "") and sha or "absent")
end
local function line(v)
    return v .. " subject=[" .. SUBJECT .. "] image=[" .. image_identity() .. "] skew=undetermined-image-records-no-version"
end

-- Cleanup state, so every exit path leaves the host as it found it.
local WORK_REL, LIVE_PID, LIVE_H
local holders -- defined once NVRAM is known
local function cleanup()
    if LIVE_PID then run({ "kill", "-9", LIVE_PID }, 5000) end
    if LIVE_H then pcall(function() LIVE_H:kill() end) end
    if holders then
        for p in (holders() or ""):gmatch("%d+") do run({ "kill", "-9", p }, 5000) end
    end
    if WORK_REL then run({ "rm", "-rf", WORK_REL }, 30000) end
end
local function finish(v, rc) cleanup(); verdict.emit(line(v), rc) end
local function cannot_run(why)
    out.line(line("unsupported:" .. NAME .. ":" .. why))
    finish("skip:" .. NAME .. ":" .. why, 0)
end

-- ROOT MUST BE A CHECKOUT BEFORE ANYTHING DERIVED FROM IT IS TRUSTED
-- (1332-tdde). A refusal, never a skip: a script that does not know where it
-- is cannot be trusted about anything else it reports.
local ROOT = fixture.repo_root()
if run({ "test", "-f", ROOT .. "/build.sh" }) ~= 0 or run({ "test", "-d", ROOT .. "/crates" }) ~= 0 then
    finish("refused:" .. NAME .. ":root-is-not-a-tillandsias-checkout-" .. ROOT, 1)
end
local ARMS = 0

-- --- Arm 0: the source guard, which needs no VM and no macOS --------------
local VZ = "crates/tillandsias-vm-layer/src/vz.rs"
if fs.exists(VZ) then
    local src = fs.read(VZ) or ""
    if not text.contains(src, "fn explain_start_failure") then
        finish("violation:" .. NAME .. ":explain-start-failure-gone", 1)
    end
    if not text.contains(src, "DO NOT --reset-guest") then
        finish("violation:" .. NAME .. ":branch-no-longer-steers-away-from-reset-guest", 1)
    end
    -- The helper is worthless if the failing path stops routing through it.
    if not text.contains(src, "map_err(|e| explain_start_failure(") then
        finish("violation:" .. NAME .. ":start-failure-site-not-wired-to-the-explainer", 1)
    end
    ARMS = ARMS + 1
end

-- The source arm above still ran; name the half that was skipped.
local _, uname = run({ "uname", "-s" })
if text.trim(uname) ~= "Darwin" then cannot_run("not-darwin-source-arm-only") end

local TRAY = env.get("TILLANDSIAS_TRAY_BIN") or ""
if TRAY == "" then TRAY = ROOT .. "/dist/Tillandsias.app/Contents/MacOS/tillandsias-tray" end
-- A bare target/release binary carries no virtualization entitlement and
-- cannot start a VM at all; name that rather than meet it as this file's bug.
local tray_ok = run({ "test", "-x", TRAY }) == 0
if tray_ok then
    local _, v = run({ TRAY, "--version" })
    local first = text.lines(v)[1] or ""
    SUBJECT = (first ~= "") and first or ("unreadable(" .. TRAY .. ")")
else
    SUBJECT = "absent(" .. TRAY .. ")"
end
if not tray_ok then cannot_run("no-app-bundle-run-scripts/build-macos-tray.sh") end

local NVRAM = HOME .. "/Library/Application Support/tillandsias/nvram.bin"
if run({ "test", "-f", NVRAM }) ~= 0 then cannot_run("no-provisioned-guest-image") end

-- Space-separated pids with no trailing separator.
holders = function()
    local _, o = run({ "/usr/sbin/lsof", "-t", NVRAM }, 15000)
    local t = {}
    for p in o:gmatch("%d+") do t[#t + 1] = p end
    return table.concat(t, " ")
end

-- PRECONDITION. A VM already running here (a live tray, another session) makes
-- arm 1 fail for a reason that is not the subject. Refuse rather than guess.
local PRE = holders()
if PRE ~= "" then
    holders = nil -- not ours: cleanup must not kill a pre-existing holder
    cannot_run("image-already-held-by-pid-" .. PRE:gsub(" ", ",") .. "-precondition-unmet")
end

WORK_REL = "target/plan-scratch/macos-vz-orphan." .. tostring(time.now_ms())
local WORK = ROOT .. "/" .. WORK_REL
fs.mkdir(WORK_REL)

local function exec_guest(cmd, log)
    local rc, o, e = run({ TRAY, "--exec-guest", cmd }, 900000)
    fs.write(WORK_REL .. "/" .. log, o .. e)
    return rc, o .. e
end

-- Start a guest and wait until the in-guest command is actually RUNNING. A
-- tray killed before the VM boots orphans nothing, and would score green for
-- the wrong reason.
-- THE LIVE TRAY IS SPAWNED WITH detach = true (2294-dtch). The runner reaps a
-- run's process group when its leader exits; a helper left in the tray's group
-- would die with the SIGKILLed tray, and arm 1 would read green on exactly the
-- leak it exists to catch (measured with a stub whose holder outlives the
-- tray: the .sh reds, an undetached port went green). detach leaves the group
-- unreaped on exit, and this file's cleanup kills every holder itself. The
-- wrapper only records the pid and sends the tray's output to a log the loop
-- below can read while the tray still runs; `exec` keeps the pid the tray's.
local function start_live_guest()
    fs.write(WORK_REL .. "/live.sh", 'echo "$$" > "$1/live.pid"\nexec "$2" --exec-guest "sleep 600" > "$1/live.log" 2>&1 </dev/null\n')
    LIVE_H = proc.spawn({ argv = { fixture.posix_shell(), WORK .. "/live.sh", WORK, TRAY }, timeout_ms = 900000, detach = true })
    for _ = 1, 60 do
        if not LIVE_PID and fs.exists(WORK_REL .. "/live.pid") then
            LIVE_PID = (fs.read(WORK_REL .. "/live.pid") or ""):match("(%d+)")
        end
        if fs.exists(WORK_REL .. "/live.log") and text.contains(fs.read(WORK_REL .. "/live.log") or "", "running:") then
            return true
        end
        if LIVE_PID and run({ "kill", "-0", LIVE_PID }, 5000) ~= 0 then return false end
        pause("2")
    end
    return false
end

if not start_live_guest() then finish("violation:" .. NAME .. ":guest-never-reached-a-running-command", 1) end
if holders() == "" then
    -- No holder while a guest is demonstrably running means lsof is not seeing
    -- what this fixture reads, so neither arm below would mean anything.
    finish("violation:" .. NAME .. ":live-guest-holds-no-nvram-probe-is-blind", 1)
end

-- --- Arm 2 (MUTATION, run first while the guest is live) -----------------
-- Leave the VM alive and make the SAME second-start assertion arm 1 makes. It
-- MUST fail, and the failure MUST name the holder without sending the reader
-- at --reset-guest.
local HELD_PID = holders():match("^(%d+)")
local mut_rc, mut = exec_guest("echo MUTATION_ARM", "mutation.log")
if mut_rc == 0 then
    finish("violation:" .. NAME .. ":second-start-succeeded-with-the-orphan-alive-arm1-cannot-discriminate", 1)
end
if not text.contains(mut, "pid " .. HELD_PID) then
    finish("violation:" .. NAME .. ":failure-text-does-not-name-holder-" .. HELD_PID, 1)
end
if not text.contains(mut, "DO NOT --reset-guest") then
    finish("violation:" .. NAME .. ":failure-text-does-not-steer-away-from-reset-guest", 1)
end
ARMS = ARMS + 1

-- --- Arm 1 (SUBJECT): SIGKILL the tray; the helper must not survive it ----
if LIVE_PID then run({ "kill", "-9", LIVE_PID }, 5000) end
LIVE_PID = nil
for _ = 1, 15 do
    if holders() == "" then break end
    pause("1")
end
local LEFT = holders()
if LEFT ~= "" then
    finish("violation:" .. NAME .. ":helper-" .. LEFT:gsub(" ", ",") .. "-outlived-a-sigkilled-tray-holding-nvram", 1)
end
ARMS = ARMS + 1

-- --- Arm 3: and the image is genuinely usable again, not merely unheld ---
local aft_rc, aft = exec_guest("echo AFTER_KILL_OK", "after.log")
if aft_rc ~= 0 or not text.contains(aft, "AFTER_KILL_OK") then
    finish("violation:" .. NAME .. ":second-start-failed-after-the-tray-was-sigkilled", 1)
end
ARMS = ARMS + 1

finish("ok:" .. NAME .. ":" .. ARMS, 0)
