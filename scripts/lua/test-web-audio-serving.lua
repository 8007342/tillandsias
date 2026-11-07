-- @trace order:2007-hear
-- @env PATH HOME XDG_RUNTIME_DIR TILLANDSIAS_WEB_IMAGE
--
-- test-web-audio-serving.lua — in a BUILT static preview image (images/web,
-- busybox httpd), an untracked folder of audio candidates is served with the
-- right media types, and seeking is measured:
--   1 TYPES  .flac audio/flac, .mp3 audio/mpeg, .ogg and .opus audio/ogg,
--            .wav audio/wav, .m4a audio/mp4, index.html text/html
--   2 RANGE  `Range: bytes=1000-1999` on a .flac: REPORTS whether httpd answers
--            206 with a Content-Range (browsers seek with Range). A 200 is not
--            a failure here; it is printed as range=unsupported so the PR can
--            say what a person will see.
-- The image is $TILLANDSIAS_WEB_IMAGE, else the newest localhost/tillandsias-web;
-- could-not-run when neither exists. The container has no network.
--
-- Usage: tillandsias-plan script run scripts/lua/test-web-audio-serving.lua

local function base_env()
    return {
        PATH = env.get("PATH") or "/usr/bin:/bin",
        HOME = env.get("HOME") or "",
        XDG_RUNTIME_DIR = env.get("XDG_RUNTIME_DIR") or "",
    }
end
local function run(argv, t)
    local r = proc.run({ argv = argv, env = base_env(), timeout_ms = t or 60000 })
    return r.code or -1, r.stdout or "", r.stderr or "", r.status
end

local IMG = env.get("TILLANDSIAS_WEB_IMAGE")
if not IMG or IMG == "" then
    local c, o = run({ "podman", "images", "--format", "{{.Repository}}:{{.Tag}}",
        "--filter", "reference=localhost/tillandsias-web" })
    IMG = c == 0 and (o:match("([^\n]+)")) or nil
end
if not IMG or IMG == "" then
    verdict.could_not_run("web-audio-serving", "no localhost/tillandsias-web image is built on this host")
end

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
local REL = "target/plan-scratch/wa" .. tostring(math.random(100000, 999999))
local DIR = ROOT .. "/" .. REL
fs.mkdir(REL .. "/www")
local blob = string.rep("0123456789abcdef", 1024) -- 16 KiB
for _, n in ipairs({ "a.flac", "a.mp3", "a.ogg", "a.opus", "a.wav", "a.m4a" }) do
    fs.write(REL .. "/www/" .. n, blob)
end
fs.write(REL .. "/www/index.html", "<!doctype html><title>t</title>")

local PORT = tostring(math.random(20000, 29999))
local NAME = "tillandsias-web-audio-test-" .. PORT
local c, o, e = run({ "podman", "run", "-d", "--rm", "--name", NAME, "-p", "127.0.0.1:" .. PORT .. ":8080",
    "-v", DIR .. "/www:/var/www:ro,Z", IMG }, 120000)
if c ~= 0 then
    proc.run({ argv = { "rm", "-rf", DIR }, timeout_ms = 30000 })
    verdict.could_not_run("web-audio-serving", "podman run " .. IMG .. " failed: " .. e)
end
local function stop()
    run({ "podman", "rm", "-f", NAME })
    proc.run({ argv = { "rm", "-rf", DIR }, timeout_ms = 30000 })
end
local base = "http://127.0.0.1:" .. PORT .. "/"
local ready = false
for _ = 1, 30 do
    local cc = run({ "curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", base .. "index.html" }, 5000)
    if cc == 0 then ready = true; break end
    run({ "sleep", "1" })
end
if not ready then stop(); verdict.could_not_run("web-audio-serving", "the web container never answered") end

local function head(path, range)
    local argv = { "curl", "-s", "-o", "/dev/null", "-D", "-" }
    if range then argv[#argv + 1] = "-r"; argv[#argv + 1] = range end
    argv[#argv + 1] = base .. path
    local _, out = run(argv, 15000)
    return out:gsub("\r", "")
end
local function ctype(h) return (h:match("[Cc]ontent%-[Tt]ype: *([^\n;]+)") or ""):lower() end

local failed, passed = {}, 0
local function arm(name, cond, got)
    if cond then
        passed = passed + 1
        out.line("ok:   " .. name)
    else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got):gsub("\n", " | "))
        failed[#failed + 1] = name
    end
end

local want = { ["a.flac"] = "audio/flac", ["a.mp3"] = "audio/mpeg", ["a.ogg"] = "audio/ogg",
    ["a.opus"] = "audio/ogg", ["a.wav"] = "audio/wav", ["a.m4a"] = "audio/mp4", ["index.html"] = "text/html" }
local bad = {}
for f, t in pairs(want) do
    local got = ctype(head(f))
    if got ~= t then bad[#bad + 1] = f .. "=" .. got end
end
arm("1 TYPES every audio file and the page carry their media type", #bad == 0, table.concat(bad, ","))

local h = head("a.flac", "1000-1999")
local status = h:match("^HTTP/%S+ (%d+)") or "?"
local cr = h:match("[Cc]ontent%-[Rr]ange: *([^\n]+)")
if status == "206" and cr then
    out.line("ok:   2 RANGE range=supported status=206 content-range=" .. cr)
else
    out.line("note: 2 RANGE range=unsupported status=" .. status .. " (the whole file is sent; a browser plays it, and seeking depends on the browser buffering it)")
end
passed = passed + 1

stop()
if #failed > 0 then
    verdict.emit("violation:web-audio-serving:" .. table.concat(failed, ","), 1, passed .. " passed")
end
verdict.ok("web-audio-serving", passed .. " arms in " .. IMG .. " range=" .. ((status == "206" and cr) and "supported" or "unsupported"))
