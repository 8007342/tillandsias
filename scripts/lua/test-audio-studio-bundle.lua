-- @env PATH HOME XDG_RUNTIME_DIR TILLANDSIAS_PLAN_BIN
-- @trace order:2055-grzz
--
-- test-audio-studio-bundle.lua — pins scripts/lua/check-audio-studio-bundle.lua:
-- a bundle whose text merely SAYS rubberband and sox (as the Containerfile and
-- audio-tool.py do) passes; a file named sox, a file carrying either binary
-- marker, the same inside a .tar.gz, and an empty bundle are each refused.
-- REAL-DATA CONTROL: when the audio-studio image is in the store, its own
-- /usr/bin/rubberband and /usr/bin/sox, copied out under neutral names, are
-- refused by content, so the markers are the binaries' and not a guess.
-- Real tree: the repo's own images/audio-studio text passes.
--
-- PRE-FIX: with no check-audio-studio-bundle.lua the fixture refuses at once.

local GUARD = "scripts/lua/check-audio-studio-bundle.lua"
if not fs.exists(GUARD) then verdict.emit("violation:audio-studio-bundle-fixture:no-guard", 1, GUARD .. " does not exist") end

local PLAN = env.get("TILLANDSIAS_PLAN_BIN") or ""
if PLAN == "" then
    local top = text.trim(proc.run{ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 }.stdout or "")
    PLAN = top .. "/target/release/tillandsias-plan"
    if not fs.exists("target/release/tillandsias-plan") then PLAN = "tillandsias-plan" end
end

local REL = "target/plan-scratch/audio-studio-bundle-fixture-" .. time.iso_utc():gsub("[^%w]", "") .. "-" .. math.random(100000, 999999)
local function dir(name) local d = REL .. "/" .. name; fs.mkdir(d); return d end
fs.mkdir(REL)

local function guard(args)
    local argv = { PLAN, "script", "run", GUARD, "--" }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local r = proc.run{ argv = argv, timeout_ms = 300000 }
    local last = text.trim(r.stdout or ""):match("([^\n]*)$") or ""
    return r.code, last
end

local passes, fails = 0, 0
local function arm(name, cond, got)
    if cond then passes = passes + 1; out.line("ok: " .. name)
    else fails = fails + 1; out.line("FAIL: " .. name .. (got and (" — got: " .. got) or "")) end
end

local RB, SX = "RubberBand" .. "Stretcher", "lib" .. "SoX"

local clean = dir("clean")
fs.write(clean .. "/tillandsias", "\127ELF...apt-get install rubberband-cli sox ... rubberband -t 1.5 ... sox in out rate")
local c, v = guard({ clean })
arm("text that names rubberband and sox passes", c == 0 and v:match("^ok:audio%-studio%-bundle:files=1$") ~= nil, v)

local named = dir("named"); fs.write(named .. "/tillandsias", "x"); fs.write(named .. "/sox", "x")
c, v = guard({ named })
arm("a file named sox is refused", c == 1 and v:find("named%-sox") ~= nil, v)

local lib = dir("lib"); fs.write(lib .. "/librubberband.so.2", "x")
c, v = guard({ lib })
arm("a librubberband library is refused by name", c == 1 and v:find("named%-librubberband") ~= nil, v)

local emb = dir("embedded"); fs.write(emb .. "/tillandsias", "\127ELF" .. string.rep("\0", 64) .. RB .. "::process")
c, v = guard({ emb })
arm("a binary carrying the rubberband marker is refused", c == 1 and v:find("carries%-RubberBand") ~= nil, v)

local emb2 = dir("embedded2"); fs.write(emb2 .. "/tray.exe", "MZ" .. string.rep("\0", 64) .. SX .. " v14.4.2")
c, v = guard({ emb2 })
arm("a binary carrying the sox marker is refused", c == 1 and v:find("carries%-libSoX") ~= nil, v)

local tdir = dir("tarsrc"); fs.write(tdir .. "/sox", "x")
local tgz = REL .. "/bundle.tar.gz"
local t = proc.run{ argv = { "tar", "-czf", tgz, "-C", tdir, "sox" }, timeout_ms = 60000 }
if t.ok then
    c, v = guard({ tgz })
    arm("a sox inside a .tar.gz is refused", c == 1 and v:find("named%-sox") ~= nil, v)
else
    arm("tar can build the archive arm's premise", false, text.trim(t.stderr or ""))
end

local empty = dir("empty")
c, v = guard({ empty })
arm("NEGATIVE CONTROL: an empty bundle is could-not-run, never ok", c ~= 0 and v:match("^ok:") == nil, v)

-- REAL-DATA CONTROL: the image's own binaries.
local IMG = "localhost/tillandsias-audio-studio:glitch-fixture"
local have = proc.run{ argv = { "podman", "image", "exists", IMG }, timeout_ms = 30000 }
if have.ok then
    local real = dir("real")
    local top = text.trim(proc.run{ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 }.stdout or "")
    local id = text.trim(proc.run{ argv = { "podman", "create", IMG }, timeout_ms = 60000 }.stdout or "")
    local ok1 = proc.run{ argv = { "podman", "cp", id .. ":/usr/bin/rubberband", top .. "/" .. real .. "/blob-a" }, timeout_ms = 60000 }.ok
    local ok2 = proc.run{ argv = { "podman", "cp", id .. ":/usr/bin/sox", top .. "/" .. real .. "/blob-b" }, timeout_ms = 60000 }.ok
    proc.run{ argv = { "podman", "rm", "-f", id }, timeout_ms = 60000 }
    if ok1 and ok2 then
        c, v = guard({ real .. "/blob-a" })
        arm("REAL: the image's rubberband, renamed, is refused by content", c == 1 and v:find("carries%-RubberBand") ~= nil, v)
        c, v = guard({ real .. "/blob-b" })
        arm("REAL: the image's sox, renamed, is refused by content", c == 1 and v:find("carries%-libSoX") ~= nil, v)
    else
        arm("REAL: podman cp out of the audio-studio image", false)
    end
else
    out.line("skip: REAL-DATA control (" .. IMG .. " not in the store; test-audio-studio-glitches.lua builds it)")
end

c, v = guard({ "images/audio-studio" })
arm("real tree: images/audio-studio's own text passes", c == 0 and v:match("^ok:") ~= nil, v)

out.line("audio-studio bundle fixture: " .. passes .. " passed, " .. fails .. " failed")
if fails == 0 then verdict.emit("ok:audio-studio-bundle-fixture:" .. passes .. "-arms", 0) end
verdict.emit("violation:audio-studio-bundle-fixture:failed=" .. fails, 1)
