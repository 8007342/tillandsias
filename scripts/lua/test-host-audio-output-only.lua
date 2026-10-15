-- @trace order:1722-2haw
-- @env PATH XDG_RUNTIME_DIR
--
-- test-host-audio-output-only.lua — the output-only audio server a browser
-- window is given (crates/tillandsias-headless/src/host_audio_pulse.conf)
-- plays and refuses everything else, on this host's REAL PipeWire session.
--
-- The shipped configuration is started on a scratch socket, exactly as the
-- tray renders it (only @SOCKET@ substituted), and attacked through that
-- socket the way a page or a process in the browser container could:
--   1 PLAY     a playback stream is accepted
--   2 MIC      recording the default source: refused, 0 bytes
--   3 MONITOR  recording the default sink's monitor (other apps' sound):
--              refused, 0 bytes
--   4 MODULE   load-module: refused
-- Each deny arm is then shown able to go RED: the same attack against a
-- mutant with its control removed must SUCCEED, or the arm proves nothing.
--   5 MIC-RED      without block-record-stream the mic records > 0 bytes
--   6 MONITOR-RED  without block-record-stream the monitor records > 0 bytes
--   7 MODULE-RED   with module loading allowed, load-module succeeds
-- client.access = "restricted" is kept in every mutant: it alone is NOT a
-- boundary (WirePlumber grants restricted clients RX everywhere; measured
-- 2026-10-15 on yoga, 131072 bytes of microphone through it).
--
-- Needs a desktop session (a PipeWire daemon and pipewire-pulse); elsewhere
-- it SKIPS by name. It plays only silence; nothing is audible.
--
-- Usage: tillandsias-plan script run scripts/lua/test-host-audio-output-only.lua

local NAME = "host-audio-output-only"
local CONF_PATH = "crates/tillandsias-headless/src/host_audio_pulse.conf"

local runtime = env.get("XDG_RUNTIME_DIR") or ""
if runtime == "" then verdict.skip(NAME, "no XDG_RUNTIME_DIR: not a desktop session") end
for _, tool in ipairs({ "pipewire", "pactl", "parecord", "pacat" }) do
    local w = proc.run({ argv = { tool, "--version" }, timeout_ms = 5000 })
    -- Only an absent tool is a skip; a refused probe must never read as one.
    if w.status == "policy_denied" then
        verdict.could_not_run(NAME, "the runtime refused to run " .. tool)
    end
    if w.status ~= "exited" or w.code ~= 0 then verdict.skip(NAME, tool .. " is not installed") end
end
local host = proc.run({ argv = { "pactl", "get-default-sink" }, timeout_ms = 10000,
    env = { XDG_RUNTIME_DIR = runtime, LC_ALL = "C" } })
local SINK = text.trim(host.stdout or "")
if host.status ~= "exited" or host.code ~= 0 or SINK == "" then
    verdict.skip(NAME, "no pulse server answers on this session")
end

local SHIPPED = fs.read(CONF_PATH)
if not SHIPPED:find("block%-record%-stream", 1) or not SHIPPED:find("pulse.allow-module-loading = false", 1, true) then
    verdict.could_not_run(NAME, CONF_PATH .. " no longer carries the controls this fixture mutates; update the fixture with the config")
end

-- sun_path is 108 bytes, so the scratch socket lives under the runtime dir.
local DIR = runtime .. "/tl-audio-fx-" .. tostring(math.random(100000, 999999))
proc.run({ argv = { "mkdir", "-m", "0700", DIR }, timeout_ms = 5000 })
local SOCKET = DIR .. "/native"
local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.status ~= "exited" or top.code ~= 0 or ROOT == "" then
    verdict.could_not_run(NAME, "git rev-parse --show-toplevel did not answer")
end
-- fs.* is confined to the repository: files there, only the socket outside.
local REL = "target/plan-scratch/audio-fx-" .. time.iso_utc() .. "-" .. tostring(math.random(100000, 999999))
fs.mkdir(REL)
local CLIENT_ENV = { XDG_RUNTIME_DIR = runtime, LC_ALL = "C", PULSE_SERVER = "unix:" .. SOCKET }

local function pause(sec) proc.run({ argv = { "sleep", sec }, timeout_ms = 30000 }) end

-- Start a server from `conf` text; returns its handle once the socket answers.
local function serve(conf)
    local file = REL .. "/pulse.conf"
    fs.write(file, (conf:gsub("@SOCKET@", SOCKET)))
    proc.run({ argv = { "rm", "-f", SOCKET }, timeout_ms = 5000 })
    local h = proc.spawn({ argv = { "pipewire", "-c", ROOT .. "/" .. file },
        env = { XDG_RUNTIME_DIR = runtime }, timeout_ms = 120000 })
    for _ = 1, 60 do
        local r = proc.run({ argv = { "pactl", "info" }, env = CLIENT_ENV, timeout_ms = 5000 })
        if r.status == "exited" and r.code == 0 then return h end
        pause("0.1")
    end
    h:kill()
    verdict.could_not_run(NAME, "the audio server never answered on " .. SOCKET)
end

-- 4 s: parecord writes in large blocks, and a 2 s capture that WAS accepted
-- left 0 bytes on disk (measured), which would read as a refusal.
local function record(device)
    local out = REL .. "/cap-" .. tostring(math.random(100000, 999999)) .. ".raw"
    local r = proc.run({ argv = { "timeout", "4", "parecord", "--device=" .. device, "--raw",
        "--format=s16le", "--rate=48000", "--channels=1", ROOT .. "/" .. out }, env = CLIENT_ENV, timeout_ms = 10000 })
    local ok, data = pcall(fs.read, out)
    local bytes = ok and #data or 0
    return bytes, text.trim((r.stderr or "") .. " rc=" .. tostring(r.code))
end

local function load_module()
    local r = proc.run({ argv = { "pactl", "load-module", "module-null-sink", "sink_name=tl_fx_probe" },
        env = CLIENT_ENV, timeout_ms = 10000 })
    local id = text.trim(r.stdout or "")
    if r.code == 0 and id:match("^%d+$") then
        proc.run({ argv = { "pactl", "unload-module", id }, env = CLIENT_ENV, timeout_ms = 10000 })
        return true, "loaded " .. id
    end
    return false, text.trim(r.stderr or "")
end

local MIC = "@DEFAULT_SOURCE@"
local MONITOR = SINK .. ".monitor"

local failed = {}
local function arm(name, cond, got)
    got = tostring(got):gsub("\n", " | ")
    if cond then out.line("ok:   " .. name .. " — " .. got) else
        out.line("FAIL: " .. name .. " — got: " .. got)
        failed[#failed + 1] = name
    end
end

-- The shipped configuration.
local h = serve(SHIPPED)
local silence = REL .. "/silence.raw"
fs.write(silence, string.rep("\0", 9600))
local play = proc.run({ argv = { "pacat", "--playback", "--raw", "--format=s16le", "--rate=48000",
    "--channels=1", ROOT .. "/" .. silence }, env = CLIENT_ENV, timeout_ms = 10000 })
arm("1 PLAY a playback stream is accepted", play.status == "exited" and play.code == 0,
    "rc=" .. tostring(play.code) .. " " .. text.trim(play.stderr or ""))
local b, why = record(MIC)
arm("2 MIC recording the default source is refused", b == 0 and why:find("Access denied", 1, true), b .. " bytes; " .. why)
b, why = record(MONITOR)
arm("3 MONITOR recording " .. MONITOR .. " is refused", b == 0 and why:find("Access denied", 1, true), b .. " bytes; " .. why)
local loaded, lwhy = load_module()
arm("4 MODULE load-module is refused", not loaded and lwhy:find("Access denied", 1, true), lwhy)
h:kill()

-- Mutant: no record block. The same two attacks must now succeed.
local no_block = SHIPPED:gsub("block%-record%-stream ", "")
if no_block == SHIPPED then verdict.could_not_run(NAME, "the record-block mutation changed nothing") end
h = serve(no_block)
b, why = record(MIC)
arm("5 MIC-RED without block-record-stream the mic records", b > 0, b .. " bytes; " .. why)
b, why = record(MONITOR)
arm("6 MONITOR-RED without block-record-stream the monitor records", b > 0, b .. " bytes; " .. why)
h:kill()

-- Mutant: module loading allowed.
local modules = SHIPPED:gsub("pulse.allow%-module%-loading = false", "pulse.allow-module-loading = true")
if modules == SHIPPED then verdict.could_not_run(NAME, "the module-loading mutation changed nothing") end
h = serve(modules)
loaded, lwhy = load_module()
arm("7 MODULE-RED with module loading allowed, load-module succeeds", loaded, lwhy)
h:kill()

proc.run({ argv = { "rm", "-rf", DIR, ROOT .. "/" .. REL }, timeout_ms = 5000 })
if #failed > 0 then
    verdict.emit("violation:" .. NAME .. ":" .. #failed .. "-failed", 1)
end
verdict.ok(NAME, "7 arms")
