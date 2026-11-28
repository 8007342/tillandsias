-- @env PATH HOME
-- @trace order:1238-b825, spec:ci-release, order:2301-4bgh
--
-- test-build-version-label.lua — fixture for scripts/lib-build-version.sh and the three
-- local build paths (1238-b825). Ported from the .sh of the same name (2301-4bgh); same
-- seven arms. Each path is asked what it would stamp (`<script> --print-version`) from a
-- scratch copy, under a stub clock (TILLANDSIAS_BUILD_DATE_OVERRIDE).
--
--   1 the measured case: VERSION 56.9.13.1 built on 56.9.17 prints 56.9.13.1+built.56.9.17
--     on all three paths, and each says so on stderr
--   2 a same-day VERSION is unchanged, and silent
--   3 two UTC days give two labels, hence two tray tarball names
--   4 VERSION is never written
--   5 the real clock: today's epoch CalVer (years since 1970) is unchanged
--   6 REPRESENTATION (source, since only a full build produces these): the tarball name
--     uses the label; Info.plist keeps VERSION (CFBundleVersion must be numeric-dotted)
--   7 a RELEASE build stamps VERSION verbatim on a later day, and release.yml sets it
--
-- PRE-FIX: no path had --print-version or a date check; a 2026-09-17 build shipped as 56.9.13.1.
--
-- Usage: tillandsias-plan script run scripts/lua/test-build-version-label.lua
-- Verdict: ok:build-version-label:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("build-version-label")
local SH = fixture.posix_shell()
local PATHS = { "build-macos-tray.sh", "build-image.sh", "build-guest-binaries.sh" }
local STALE, SAME = "56.9.13.1", "56.9.17.3"
local LABEL = STALE .. "+built.56.9.17"

local function root(version)
    local d = T:scratch()
    fs.mkdir(d.rel .. "/scripts")
    fs.write(d.rel .. "/scripts/lib-build-version.sh", fs.read("scripts/lib-build-version.sh"))
    for _, s in ipairs(PATHS) do fs.write(d.rel .. "/scripts/" .. s, fs.read("scripts/" .. s)) end
    fs.write(d.rel .. "/VERSION", version .. "\n")
    return d
end
-- "" and not nil: proc.run passes the caller's TILLANDSIAS_* through (2305-zm8j), and both
-- readers take "" as unset.
local function ask(d, s, date, release)
    local r = proc.run{ argv = { SH, d.abs .. "/scripts/" .. s, "--print-version" }, cwd = d.abs, timeout_ms = 60000,
        env = { PATH = env.get("PATH"), HOME = env.get("HOME"), TILLANDSIAS_BUILD_DATE_OVERRIDE = date or "", TILLANDSIAS_RELEASE_BUILD = release or "" } }
    return r.code, text.trim(r.stdout or ""), text.trim(r.stderr or "")
end
local function all(d, date, good)
    local off = {}
    for _, s in ipairs(PATHS) do
        local rc, o, e = ask(d, s, date)
        if not (rc == 0 and good(o, e)) then off[#off + 1] = s .. " rc=" .. tostring(rc) .. " [" .. o .. "] [" .. e .. "]" end
    end
    return #off == 0, table.concat(off, " ")
end

local NOTE = "note:build-version:stale-date:VERSION=56.9.13.1:built=56.9.17"
local ok, got = all(root(STALE), "56.9.17", function(o, e) return o == LABEL and text.contains(e, NOTE) end)
T:arm("1 all three paths label the measured case and note it", ok, got)
ok, got = all(root(SAME), "56.9.17", function(o, e) return o == SAME and e == "" end)
T:arm("2 a same-day VERSION is unchanged and silent on all three", ok, got)

local d = root(STALE)
local _, l1 = ask(d, PATHS[1], "56.9.17")
local _, l2 = ask(d, PATHS[1], "56.9.18")
T:arm("3 two UTC days give two labels", l1 == LABEL and l2 == STALE .. "+built.56.9.18", l1 .. " vs " .. l2)

d = root(STALE)
local ran = all(d, "56.9.17", function(o) return o == LABEL end)
T:arm("4 VERSION's bytes are identical after all three ran", ran and fs.read(d.rel .. "/VERSION") == STALE .. "\n", "ran=" .. tostring(ran) .. " " .. fs.read(d.rel .. "/VERSION"))

local ymd = text.trim(T:must{ "date", "-u", "+%Y %m %d" }.stdout)
local y, m, day = ymd:match("^(%d+) (%d+) (%d+)$")
local today = string.format("%d.%d.%d", tonumber(y, 10) - 1970, tonumber(m, 10), tonumber(day, 10))
local _, o = ask(root(today .. ".1"), PATHS[1])
T:arm("5 under the real clock today's VERSION is unchanged", o == today .. ".1", "want " .. today .. ".1 got " .. o)

local tar, plist = {}, {}
for _, l in ipairs(text.lines(fs.read("scripts/build-macos-tray.sh"))) do
    if l:find("^TAR_NAME=") then tar[#tar + 1] = l end
    if l:find("s/@VERSION@/", 1, true) then plist[#plist + 1] = l end
end
tar, plist = table.concat(tar, "\n"), table.concat(plist, "\n")
T:arm("6 the tarball name uses BUILD_LABEL and Info.plist keeps ${VERSION}",
    text.contains(tar, "BUILD_LABEL") and text.contains(plist, "${VERSION}") and not text.contains(plist, "LABEL"), tar .. " | " .. plist)

local _, rel = ask(root(STALE), PATHS[1], "56.9.17", "1")
local step = fs.read(".github/workflows/release.yml"):match("name: Build Tillandsias%.app %+ tarball.-run: scripts/build%-macos%-tray%.sh") or ""
T:arm("7 a release build is verbatim and release.yml's tray step says it is one",
    rel == STALE and text.contains(step, 'TILLANDSIAS_RELEASE_BUILD: "1"'), "[" .. rel .. "] step=" .. step)
T:finish()
