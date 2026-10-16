-- @trace order:1716-t2gi
-- @env PATH TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-image-pins.lua — 1716-t2gi's exit criteria, on CONSTRUCTED roots, for
-- scripts/lua/check-image-pins.lua:
--   1 RED      the measured single-platform pin (debian bookworm-slim's AMD64
--              entry, a4672c0cb26f…, recorded as an image manifest) is refused
--              as image-pin-single-platform, exit 1, naming file and line
--   2 CONTROLS the three live index pins (webkit ubuntu@534baea6a22c,
--              web-wrangler node@4a4884e8a448, flutter debian@7c7b2c966bc9),
--              with the committed record, pass: pinned=3, exit 0
--   3 UNRECORDED a digest the record does not hold is refused, exit 1
--   4 NO-ARM64 an index without linux/arm64 is refused as missing-arch
--   5 ARG      an ARG-substituted FROM is resolved from its file's default and
--              judged (the red digest via ${BASE} is refused); an unresolvable
--              one is NAMED on stderr, never skipped; a stage name is a stage
--   6 OFFLINE  the guard spawns nothing (no proc.run in its source), and it
--              passes with every proxy pointed at a closed port
--   7 NO RECORD fails closed: blocked, exit 2
--   8 LIVE     this checkout passes, every FROM under images/ and
--              observatorium/ counted (from=17 at the time of writing)
--
-- Usage: tillandsias-plan script run scripts/lua/test-image-pins.lua

local SUBJECT_REL = "scripts/lua/check-image-pins.lua"
local RECORD_REL = "images/image-pins.yaml"
if not fs.exists(SUBJECT_REL) then
    verdict.emit("violation:image-pins-fixture:no-subject", 1, SUBJECT_REL .. " does not exist (1716-t2gi)")
end
local PLAN = env.get("TILLANDSIAS_PLAN_BIN")
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") end
if not PLAN or PLAN == "" then
    verdict.could_not_run("image-pins-fixture", "no plan binary named (TILLANDSIAS_PLAN_BIN or TILLANDSIAS_SCRIPT_RUNNER_BIN)")
end

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.status ~= "exited" or top.code ~= 0 or ROOT == "" then
    verdict.could_not_run("image-pins-fixture", "git rev-parse --show-toplevel did not answer")
end
local REL = "target/plan-scratch/image-pins-" .. time.iso_utc() .. "-" .. tostring(math.random(100000, 999999))
fs.mkdir(REL)

local failed = {}
local function arm(name, cond, got)
    got = got and tostring(got):gsub("\n", " | ") or nil
    if cond then out.line("ok:   " .. name .. (got and (" — " .. got) or "")) else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got))
        failed[#failed + 1] = name
    end
end

local RED = "sha256:a4672c0cb26fbdde88e38fa2dfb6c681942306680e41e4378b28770b6e79ee91"
local DEBIAN_IDX = "sha256:7c7b2c966bc9ee8cedfeef67e0e279108992c77681fa595db4a9d65c06ccc587"
local NODE_IDX = "sha256:4a4884e8a44826194dff92ba316264f392056cbe243dcc9fd3551e71cea02b90"
local UBUNTU_IDX = "sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55"
local LIVE_RECORD = fs.read(RECORD_REL)

-- A root with images/<name>/Containerfile bodies and a record.
local function root_with(name, containerfiles, record)
    local d = REL .. "/" .. name
    fs.mkdir(d .. "/images")
    for sub, body in pairs(containerfiles) do
        fs.mkdir(d .. "/images/" .. sub)
        fs.write(d .. "/images/" .. sub .. "/Containerfile", body)
    end
    if record then fs.write(d .. "/" .. RECORD_REL, record) end
    return d
end
local function check(d, extra_env)
    local e = { TILLANDSIAS_IMAGE_PINS_SCAN_ROOT = ROOT .. "/" .. d }
    for k, v in pairs(extra_env or {}) do e[k] = v end
    local r = proc.run({ argv = { PLAN, "script", "run", SUBJECT_REL }, cwd = ROOT, timeout_ms = 60000, env = e })
    return r.code or -1, text.trim(r.stdout or ""), text.trim(r.stderr or "")
end

local RED_RECORD = LIVE_RECORD .. table.concat({
    "  - ref: docker.io/library/debian:bookworm-slim",
    "    digest: " .. RED,
    "    media_type: application/vnd.oci.image.manifest.v1+json",
    "    platforms: []",
    "  - ref: docker.io/library/debian:bookworm-slim",
    "    digest: sha256:" .. string.rep("1", 64),
    "    media_type: application/vnd.oci.image.index.v1+json",
    "    platforms:",
    "      - linux/amd64",
    "      - linux/386",
    "" }, "\n")

-- 1 RED
local d = root_with("red", { flutter = "FROM docker.io/library/debian:bookworm-slim@" .. RED .. "\nRUN true\n" }, RED_RECORD)
local rc, o, e = check(d)
arm("1 RED the measured single-platform pin is refused, naming file and line",
    rc == 1 and o:find("refused:image-pins:1", 1, true) ~= nil
    and e:find("refused:image-pin-single-platform:images/flutter/Containerfile:1:docker.io/library/debian:bookworm-slim@" .. RED, 1, true) ~= nil
    and e:find("pin the multi-arch INDEX digest", 1, true) ~= nil, rc .. " " .. o .. " " .. e)

-- 2 CONTROLS
d = root_with("controls", {
    webkit = "FROM docker.io/library/ubuntu:24.04@" .. UBUNTU_IDX .. "\n",
    ["web-wrangler"] = "FROM docker.io/library/node:22.19.0-bookworm-slim@" .. NODE_IDX .. "\n",
    flutter = "FROM docker.io/library/debian:bookworm-slim@" .. DEBIAN_IDX .. "\n",
}, LIVE_RECORD)
rc, o = check(d)
arm("2 CONTROLS the three live index pins pass with the committed record",
    rc == 0 and o == "ok:image-pins:from=3 pinned=3 tag=0 arg=0 stage=0", rc .. " " .. o)

-- 3 UNRECORDED
d = root_with("unrecorded", { x = "FROM docker.io/library/debian:bookworm-slim@sha256:" .. string.rep("2", 64) .. "\n" }, LIVE_RECORD)
rc, o, e = check(d)
arm("3 UNRECORDED a digest the record does not hold is refused, with the refresh remedy",
    rc == 1 and e:find("refused:image-pin-unrecorded:images/x/Containerfile:1:", 1, true) ~= nil
    and e:find("refresh-image-pins.lua", 1, true) ~= nil, rc .. " " .. e)

-- 4 NO-ARM64
d = root_with("noarm", { x = "FROM docker.io/library/debian:bookworm-slim@sha256:" .. string.rep("1", 64) .. "\n" }, RED_RECORD)
rc, o, e = check(d)
arm("4 NO-ARM64 an index without linux/arm64 is refused as missing-arch",
    rc == 1 and e:find("refused:image-pin-missing-arch:images/x/Containerfile:1:", 1, true) ~= nil
    and e:find(":linux/arm64", 1, true) ~= nil and e:find(":linux/amd64", 1, true) == nil, rc .. " " .. e)

-- 5 ARG
d = root_with("arg", {
    a = "ARG BASE=docker.io/library/debian:bookworm-slim@" .. RED .. "\nFROM ${BASE}\n",
    b = "FROM ${NOT_DEFAULTED}\n",
    c = "FROM docker.io/library/debian:bookworm-slim@" .. DEBIAN_IDX .. " AS build\nFROM build\n",
}, RED_RECORD)
rc, o, e = check(d)
arm("5 ARG resolved from its default and judged; an unresolvable one named; a stage is a stage",
    rc == 1 and e:find("refused:image-pin-single-platform:images/a/Containerfile:2:", 1, true) ~= nil
    and e:find("note:image-pins:arg-from:images/b/Containerfile:1:${NOT_DEFAULTED}", 1, true) ~= nil
    and e:find("note:image-pins:arg-from-resolved:images/a/Containerfile:2:${BASE}", 1, true) ~= nil
    and o:find("refused:image-pins:1", 1, true) ~= nil, rc .. " " .. o .. " " .. e)
local cr = proc.run({ argv = { PLAN, "script", "run", SUBJECT_REL }, cwd = ROOT, timeout_ms = 60000,
    env = { TILLANDSIAS_IMAGE_PINS_SCAN_ROOT = ROOT .. "/" .. root_with("stage", {
        c = "FROM docker.io/library/debian:bookworm-slim@" .. DEBIAN_IDX .. " AS build\nFROM build\n" }, LIVE_RECORD) } })
arm("5b STAGE a previous stage's name counts as a stage, not a tag",
    cr.code == 0 and text.trim(cr.stdout or "") == "ok:image-pins:from=2 pinned=1 tag=0 arg=0 stage=1",
    tostring(cr.code) .. " " .. tostring(cr.stdout))

-- 6 OFFLINE
local src = fs.read(SUBJECT_REL)
local spawns = src:find("proc%.run") or src:find("proc%.spawn") or src:find("curl") or src:find("http")
arm("6a OFFLINE the guard's source spawns nothing and names no network tool", spawns == nil,
    spawns and ("found at byte " .. spawns) or "no proc.run/proc.spawn/curl/http")
local dead = "http://127.0.0.1:9"
rc, o = check(REL .. "/controls", { HTTPS_PROXY = dead, HTTP_PROXY = dead, ALL_PROXY = dead,
    https_proxy = dead, http_proxy = dead, all_proxy = dead })
arm("6b OFFLINE it passes with every proxy pointed at a closed port", rc == 0 and o:find("^ok:image%-pins:") ~= nil, rc .. " " .. o)

-- 7 NO RECORD
d = root_with("norecord", { x = "FROM docker.io/library/alpine:3.22\n" }, nil)
rc, o = check(d)
arm("7 NO RECORD fails closed", rc == 2 and o == "blocked:image-pins:no-record", rc .. " " .. o)

-- 8 LIVE
local live = proc.run({ argv = { PLAN, "script", "run", SUBJECT_REL }, cwd = ROOT, timeout_ms = 60000 })
local lo = text.trim(live.stdout or "")
local from_n = tonumber(lo:match("from=(%d+)") or "")
arm("8 LIVE this checkout passes, every FROM counted",
    live.code == 0 and from_n ~= nil and from_n >= 17 and lo:find("pinned=3", 1, true) ~= nil, tostring(live.code) .. " " .. lo)

proc.run({ argv = { "rm", "-rf", ROOT .. "/" .. REL }, timeout_ms = 30000 })
if #failed > 0 then
    verdict.emit("violation:image-pins-fixture:" .. #failed .. "-failed", 1)
end
verdict.ok("image-pins-fixture", "8 arms")
