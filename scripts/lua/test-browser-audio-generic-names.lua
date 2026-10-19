-- @trace order:1769-9gna
-- @env PATH XDG_RUNTIME_DIR TILLANDSIAS_CHROMIUM_FRAMEWORK_IMAGE TILLANDSIAS_WEBKIT_IMAGE
--
-- test-browser-audio-generic-names.lua — a browser window sees only generic
-- audio devices ("Speakers", and the monitor of that sink), never a host
-- device name, and its sound still reaches the host (1769-9gna; operator
-- ruling 2026-10-17).
--
-- The shipped output-only server (crates/tillandsias-headless/src/
-- host_audio_pulse.conf) is started on a scratch socket, as the tray starts
-- it. The REAL chromium-framework image then runs the way a window runs (its
-- own launcher, read-only root, a tmpfs runtime dir, only that socket FILE
-- mounted, PULSE_SERVER pointing at it), with a probe mounted where the
-- launcher finds `chromium`. The probe reports the PULSE_SERVER the browser
-- would get and lists the devices it can see there.
--   1 PRIVATE     the browser's PULSE_SERVER is not the host-reachable socket
--   2 GENERIC     every device the browser can list is generic, and no name
--                 the host's server lists (measured here, through the same
--                 socket) reaches it
--   3 PLAYS       NEGATIVE CONTROL: the window's playback stream arrives on
--                 the output-only server, so sound still reaches the host
--   4 NO-UPSTREAM a window whose audio socket is missing gets NO pulse server,
--                 never a fallback to some other one
-- Red before 1769-9gna: the browser connects straight to the output-only
-- server, whose clients can list every host device (measured on lenovinha:
-- the TV's HDMI name, the Ryzen controller, a LAN AirPlay peer and its IP).
--
-- Needs a desktop session (PipeWire, pactl) and podman with the image; it
-- SKIPS by name elsewhere. It plays only silence.
-- The image is TILLANDSIAS_CHROMIUM_FRAMEWORK_IMAGE, else the versioned tag a
-- window runs (tillandsias-chromium-framework at v<VERSION>).
--
-- `-- --engine webkit` runs the same four arms against the tray's WebKit
-- window (1777-yhwr): its image (TILLANDSIAS_WEBKIT_IMAGE, else
-- tillandsias-webkit at v<VERSION>), its user-owned runtime tmpfs, and the
-- probe standing in for `node`, which its launcher runs.
--
-- Usage: tillandsias-plan script run scripts/lua/test-browser-audio-generic-names.lua

local ENGINE = "chromium"
for i = 1, #arg do
    if arg[i] == "--engine" then ENGINE = arg[i + 1] or "" end
end
local E = ({
    chromium = { name = "browser-audio-generic-names", image_env = "TILLANDSIAS_CHROMIUM_FRAMEWORK_IMAGE",
        repo = "tillandsias-chromium-framework", probe_at = "/usr/local/bin/chromium", runtime_mode = "mode=0755" },
    webkit = { name = "browser-audio-generic-names-webkit", image_env = "TILLANDSIAS_WEBKIT_IMAGE",
        repo = "tillandsias-webkit", probe_at = "/usr/local/bin/node", runtime_mode = "mode=0700,U" },
})[ENGINE]
if not E then verdict.could_not_run("browser-audio-generic-names", "unknown --engine " .. tostring(ENGINE) .. " (chromium or webkit)") end
local NAME = E.name
local CONF_PATH = "crates/tillandsias-headless/src/host_audio_pulse.conf"
local INSIDE_RUNTIME = "/run/user/browser"
local INSIDE_SOCKET = INSIDE_RUNTIME .. "/pulse-native"
local GENERIC = { ["Speakers"] = true, ["Monitor of Speakers"] = true, ["Microphone"] = true }

local runtime = env.get("XDG_RUNTIME_DIR") or ""
if runtime == "" then verdict.skip(NAME, "no XDG_RUNTIME_DIR: not a desktop session") end
for _, tool in ipairs({ "pipewire", "pactl", "podman" }) do
    local w = proc.run({ argv = { tool, "--version" }, timeout_ms = 10000 })
    if w.status == "policy_denied" then verdict.could_not_run(NAME, "the runtime refused to run " .. tool) end
    if w.status ~= "exited" or w.code ~= 0 then verdict.skip(NAME, tool .. " is not installed") end
end
local IMAGE = env.get(E.image_env)
if not IMAGE or IMAGE == "" then
    local ok, v = pcall(fs.read, "VERSION")
    IMAGE = "localhost/" .. E.repo .. ":v" .. text.trim(ok and v or "")
end
if proc.run({ argv = { "podman", "image", "exists", IMAGE }, timeout_ms = 30000 }).code ~= 0 then
    verdict.skip(NAME, "no image " .. IMAGE .. " (build it, or set " .. E.image_env .. ")")
end

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.status ~= "exited" or top.code ~= 0 or ROOT == "" then
    verdict.could_not_run(NAME, "git rev-parse --show-toplevel did not answer")
end
local REL = "target/plan-scratch/browser-audio-" .. time.iso_utc():gsub("[^%w]", "") .. "-" .. tostring(math.random(100000, 999999))
fs.mkdir(REL)
-- sun_path is 108 bytes, so the scratch socket lives under the runtime dir.
local DIR = runtime .. "/tl-baudio-" .. tostring(math.random(100000, 999999))
proc.run({ argv = { "mkdir", "-m", "0700", DIR }, timeout_ms = 5000 })
local SOCKET = DIR .. "/native"
local HOST_ENV = { XDG_RUNTIME_DIR = runtime, LC_ALL = "C", PULSE_SERVER = "unix:" .. SOCKET }
local function pause(sec) proc.run({ argv = { "sleep", sec }, timeout_ms = 30000 }) end

local failed = {}
local function arm(name, cond, got)
    got = tostring(got):gsub("\n", " | ")
    if cond then out.line("ok:   " .. name .. " — " .. got) else
        out.line("FAIL: " .. name .. " — got: " .. got)
        failed[#failed + 1] = name
    end
end

-- The output-only server, exactly as the tray renders it.
local conf = REL .. "/pulse.conf"
fs.write(conf, (fs.read(CONF_PATH):gsub("@SOCKET@", SOCKET)))
local server = proc.spawn({ argv = { "pipewire", "-c", ROOT .. "/" .. conf },
    env = { XDG_RUNTIME_DIR = runtime }, timeout_ms = 600000 })
local up = false
for _ = 1, 60 do
    local r = proc.run({ argv = { "pactl", "info" }, env = HOST_ENV, timeout_ms = 5000 })
    if r.status == "exited" and r.code == 0 then up = true; break end
    pause("0.1")
end
if not up then server:kill(); verdict.could_not_run(NAME, "the output-only server never answered on " .. SOCKET) end

-- What a client of the output-only server can list: the names that must not
-- reach the browser.
local function descriptions(listing)
    local names = {}
    for d in listing:gmatch("\n%s*Description: ([^\n]+)") do names[#names + 1] = text.trim(d) end
    return names
end
local host_list = ""
for _, what in ipairs({ "sinks", "sources" }) do
    local r = proc.run({ argv = { "pactl", "list", what }, env = HOST_ENV, timeout_ms = 10000 })
    host_list = host_list .. "\n" .. (r.stdout or "")
end
local HOST_NAMES = {}
for _, d in ipairs(descriptions(host_list)) do if not GENERIC[d] then HOST_NAMES[#HOST_NAMES + 1] = d end end
if #HOST_NAMES == 0 then
    server:kill()
    verdict.skip(NAME, "this host's server lists no device names, so there is nothing that could leak")
end

-- The probe stands in for chromium: the launcher finds it first on PATH.
local PROBE = [[#!/bin/sh
case " $* " in *" --version "*) echo probe; exit 0;; esac
echo "PULSE_SERVER=${PULSE_SERVER:-}"
if [ -n "${PULSE_SERVER:-}" ] && command -v pactl >/dev/null 2>&1; then
    echo "--- view"
    pactl list sinks
    pactl list sources
    echo "--- play"
    timeout 4 pacat --playback --raw --format=s16le --rate=48000 --channels=2 /dev/zero
    echo "pacat-rc=$?"
else
    echo "no-view"
fi
]]
fs.write(REL .. "/chromium", PROBE)
proc.run({ argv = { "chmod", "0755", ROOT .. "/" .. REL .. "/chromium" }, timeout_ms = 5000 })

local function window(mount_socket)
    local argv = { "podman", "run", "--rm", "--network=none", "--read-only", "--userns=keep-id",
        "--cap-drop=ALL", "--security-opt=no-new-privileges", "--security-opt=label=disable",
        "--tmpfs", "/tmp:size=256m", "--tmpfs", INSIDE_RUNTIME .. ":size=1m," .. E.runtime_mode,
        "-e", "HOME=/tmp", "-e", "XDG_RUNTIME_DIR=" .. INSIDE_RUNTIME,
        "-e", "PULSE_SERVER=unix:" .. INSIDE_SOCKET,
        "-v", ROOT .. "/" .. REL .. "/chromium:" .. E.probe_at .. ":ro" }
    if mount_socket then
        argv[#argv + 1] = "-v"; argv[#argv + 1] = SOCKET .. ":" .. INSIDE_SOCKET
    end
    argv[#argv + 1] = IMAGE
    return argv
end

-- Run the window while watching the output-only server for its stream.
local h = proc.spawn({ argv = window(true), timeout_ms = 120000 })
local stream_seen = false
for _ = 1, 80 do
    local r = proc.run({ argv = { "pactl", "list", "sink-inputs", "short" }, env = HOST_ENV, timeout_ms = 5000 })
    if text.trim(r.stdout or "") ~= "" then stream_seen = true; break end
    pause("0.1")
end
local res = h:wait()
local o = (res.stdout or "") .. (res.stderr or "")
local pulse = o:match("PULSE_SERVER=([^\n]*)") or "?"

arm("1 PRIVATE the browser's PULSE_SERVER is not the host-reachable output-only socket",
    pulse ~= "?" and pulse ~= "unix:" .. INSIDE_SOCKET and pulse ~= "", pulse)

local leaked = {}
local view
if pulse == "unix:" .. INSIDE_SOCKET then
    -- The browser IS a client of the output-only server: its view is the
    -- host's, measured above through the same socket.
    view = host_list
else
    view = o:match("%-%-%- view(.-)%-%-%- play") or ""
end
for _, d in ipairs(HOST_NAMES) do if view:find(d, 1, true) then leaked[#leaked + 1] = d end end
local foreign = {}
for _, d in ipairs(descriptions(view)) do if not GENERIC[d] then foreign[#foreign + 1] = d end end
local seen = descriptions(view)
arm("2 GENERIC the browser lists only generic devices and no host device name reaches it",
    #seen > 0 and #leaked == 0 and #foreign == 0,
    "sees [" .. table.concat(seen, "; ") .. "] leaked [" .. table.concat(leaked, "; ") .. "]")

arm("3 PLAYS NEGATIVE CONTROL: the window's stream arrives on the output-only server",
    stream_seen and o:find("pacat%-rc=124") ~= nil, "stream_seen=" .. tostring(stream_seen) .. " " .. (o:match("pacat%-rc=%d+") or "no pacat"))

res = proc.run({ argv = window(false), timeout_ms = 120000 })
o = (res.stdout or "") .. (res.stderr or "")
arm("4 NO-UPSTREAM a window without its audio socket gets no pulse server at all",
    o:find("PULSE_SERVER=\n", 1, true) ~= nil and o:find("no-view", 1, true) ~= nil, o)

server:kill()
proc.run({ argv = { "rm", "-rf", DIR }, timeout_ms = 10000 })
proc.run({ argv = { "rm", "-rf", ROOT .. "/" .. REL }, timeout_ms = 30000 })
if #failed > 0 then verdict.emit("refused:" .. NAME .. "-fixture:" .. #failed .. "-of-4", 1) end
verdict.emit("ok:" .. NAME .. "-fixture:4", 0)
