-- @trace spec:local-web-preview, order:1874-pn3s
-- @env PATH
--
-- test-flutter-shim-fallback.lua — when the host cannot run Flutter, the forge's
-- `flutter` runs a cached SDK from the durable project cache, or refuses with a
-- typed reason and remedy instead of a bare exit 69 (1874-pn3s).
--
-- images/default/cli/flutter runs outside the image through its env seams,
-- with a stub lane client and a stub cached SDK that each print who they are:
--   1 STALE     dead lane, no cache: exit 69 and `refused:flutter:lane-stale
--               remedy=...`, and nothing ran
--   2 UNSET     no lane at all, no cache: `refused:flutter:lane-unset remedy=`
--   3 CACHED    dead lane, an SDK in the project cache: it runs with the
--               caller's args, exit 0, and stderr names the cache path
--   4 NOT-SRC   an "SDK" under the src tmpfs is no cache: refused, not run
--   5 READY     NEGATIVE CONTROL: a live lane runs the lane client, not the
--               cache, and its exit code (3) is the answer
--   6 HOST-DOWN a live lane whose client says 69 (host cannot run it) falls
--               back to the cached SDK
-- Red before 1874-pn3s: the shim was a Python client that exits a bare 69.
--
-- Usage: tillandsias-plan script run scripts/lua/test-flutter-shim-fallback.lua

local SHIM = "images/default/cli/flutter"
if not fs.exists(SHIM) then
    verdict.emit("violation:flutter-shim-fallback:no-subject", 1, SHIM .. " does not exist")
end

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.status ~= "exited" or top.code ~= 0 or ROOT == "" then
    verdict.could_not_run("flutter-shim-fallback", "git rev-parse --show-toplevel did not answer")
end
local REL = "target/plan-scratch/fs" .. tostring(math.random(1000, 9999))
fs.mkdir(REL)
local DIR = ROOT .. "/" .. REL

local failed, passed = {}, 0
local function arm(name, cond, got)
    got = got and tostring(got):gsub("\n", " | ") or nil
    if cond then
        passed = passed + 1
        out.line("ok:   " .. name .. (got and (" — " .. got) or ""))
    else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got))
        failed[#failed + 1] = name
    end
end
local function has(s, needle) return (s or ""):find(needle, 1, true) ~= nil end

-- A dead lane: bind, hard-link, close (the link outlives its listener).
local ok_b, bound = pcall(fs.listen_unix, REL .. "/b.s")
if not ok_b then
    if tostring(bound):find("unsupported", 1, true) then
        verdict.ok("flutter-shim-fallback", "skip: this runtime cannot create unix sockets")
    end
    verdict.emit("violation:flutter-shim-fallback:no-fixture-socket", 1, tostring(bound))
end
proc.run({ argv = { "ln", DIR .. "/b.s", DIR .. "/d.s" }, timeout_ms = 10000 })
bound:close()
local live = fs.listen_unix(REL .. "/l.s")

fs.mkdir(REL .. "/cache/flutter-sdk/bin")
fs.mkdir(REL .. "/src/cache/flutter-sdk/bin")
fs.mkdir(REL .. "/empty")
fs.write(REL .. "/cache/flutter-sdk/bin/flutter", "#!/bin/sh\necho \"cached-sdk $*\"\n")
fs.write(REL .. "/src/cache/flutter-sdk/bin/flutter", "#!/bin/sh\necho \"src-sdk $*\"\n")
fs.write(REL .. "/client-3", "#!/bin/sh\necho \"lane-client $*\"\nexit 3\n")
fs.write(REL .. "/client-69", "#!/bin/sh\necho 'flutter (tillandsias): the image failed to build' >&2\nexit 69\n")
proc.run({ argv = { "chmod", "+x", DIR .. "/cache/flutter-sdk/bin/flutter", DIR .. "/src/cache/flutter-sdk/bin/flutter",
    DIR .. "/client-3", DIR .. "/client-69" }, timeout_ms = 10000 })

local function run(sock, cache, client)
    local envt = {
        PATH = env.get("PATH") or "/usr/bin:/bin",
        TILLANDSIAS_FLUTTER_LIB_DIR = ROOT .. "/images/default",
        TILLANDSIAS_FLUTTER_LANE_CLIENT = client or (DIR .. "/client-3"),
        TILLANDSIAS_PROJECT_CACHE = cache,
        TILLANDSIAS_FLUTTER_SRC_DIR = DIR .. "/src",
    }
    if sock then envt.TILLANDSIAS_CONTROL_SOCKET = sock end
    local r = proc.run({ argv = { "bash", ROOT .. "/" .. SHIM, "build", "web" }, env = envt, timeout_ms = 30000 })
    return r.code, r.stdout or "", r.stderr or ""
end

local c, o, e = run(DIR .. "/d.s", DIR .. "/empty")
arm("1 STALE dead lane, no cache: a typed refusal with a remedy, exit 69, nothing ran",
    c == 69 and has(e, "refused:flutter:lane-stale remedy=") and o == "", "rc=" .. tostring(c) .. " " .. e)

c, o, e = run(nil, DIR .. "/empty")
arm("2 UNSET no lane: refused:flutter:lane-unset with a remedy",
    c == 69 and has(e, "refused:flutter:lane-unset remedy="), "rc=" .. tostring(c) .. " " .. e)

c, o, e = run(DIR .. "/d.s", DIR .. "/cache")
arm("3 CACHED dead lane: the cached SDK runs with the caller's args, from the cache path",
    c == 0 and has(o, "cached-sdk build web") and has(e, DIR .. "/cache/flutter-sdk"), "rc=" .. tostring(c) .. " " .. o .. " " .. e)

c, o, e = run(DIR .. "/d.s", DIR .. "/src/cache")
arm("4 NOT-SRC an SDK under the src tmpfs is not used",
    c == 69 and not has(o, "src-sdk") and has(e, "refused:flutter:lane-stale"), "rc=" .. tostring(c) .. " " .. o .. " " .. e)

c, o, e = run(DIR .. "/l.s", DIR .. "/cache")
arm("5 READY a live lane runs the lane client and returns its code, not the cache",
    c == 3 and has(o, "lane-client build web") and not has(o, "cached-sdk"), "rc=" .. tostring(c) .. " " .. o)

c, o, e = run(DIR .. "/l.s", DIR .. "/cache", DIR .. "/client-69")
arm("6 HOST-DOWN a live lane whose host cannot run flutter falls back to the cache",
    c == 0 and has(o, "cached-sdk build web") and has(e, "host-toolchain-unavailable"), "rc=" .. tostring(c) .. " " .. o .. " " .. e)

live:close()
proc.run({ argv = { "rm", "-rf", DIR }, timeout_ms = 30000 })
if #failed > 0 then
    verdict.emit("violation:flutter-shim-fallback:" .. #failed .. "-failed", 1)
end
verdict.ok("flutter-shim-fallback", passed .. " arms")
