-- @env PATH
-- @trace order:1968-2wpe, order:307, spec:default-image
--
-- test-agy-install-cached.lua — the forge installs the agy CLI once, onto the
-- persistent tool-cache volume, and a warm launch neither downloads it nor
-- runs `agy update` (1968-2wpe).
--
-- MEASURED on yoga 2026-11-02: require_antigravity installed agy into
-- /usr/local/bin, which dies with the --rm container, so every warm launch
-- downloaded it again — "tools | agy install attempt 1/3", 5.7 / 6.2 s.
--
-- The arms EXECUTE the real require_antigravity, cut out of
-- images/default/lib-common.sh by name, with a scratch HARNESS_CURL_ROOT, a
-- stub curl that counts downloads and hands back an installer, and a stub agy
-- that counts `update` calls. PATH holds only the stubs and the system dirs.
--   1 FRESH   no agy anywhere: ONE download, agy lands under the tool cache,
--             the refresh stamp is written
--   2 WARM    a second launch: zero downloads, zero updates, one "agy cached"
--             lifecycle line (pre-fix: a fresh container re-downloads)
--   3 STALE   the stamp is older than the refresh window: one `agy update`,
--             still zero downloads
--
-- Usage: tillandsias-plan script run scripts/lua/test-agy-install-cached.lua
-- Verdict: ok:agy-install-cached:<n> arms | violation:agy-install-cached:<n>-failed

local NAME = "agy-install-cached"
local LIB = "images/default/lib-common.sh"
local passed, failed = 0, {}
local function arm(name, cond, got)
    if cond then
        passed = passed + 1
        out.line("ok:   " .. name)
    else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got))
        failed[#failed + 1] = name
    end
end
local function readf(p) return fs.exists(p) and (fs.read(p) or "") or "" end
local function count(p)
    local n = 0
    for _ in readf(p):gmatch("[^\n]+") do n = n + 1 end
    return n
end

local lines = text.lines(fs.read(LIB) or "")
local buf, inside = {}, false
for _, l in ipairs(lines) do
    if not inside and l:find("^require_antigravity%(%)%s*{") then inside = true end
    if inside then
        buf[#buf + 1] = l
        if l == "}" then break end
    end
end
local fn = table.concat(buf, "\n") .. "\n"

local root = text.trim(proc.run{ argv = { "pwd", "-P" } }.stdout or "")
local REL = "target/plan-scratch/agy-cached-" .. tostring(time.now_ms())
local ABS = root .. "/" .. REL
fs.mkdir(REL .. "/stub")
fs.mkdir(REL .. "/home")
fs.write(REL .. "/fn.sh", fn)
-- the stub agy the installer drops: counts `update`
fs.write(REL .. "/agy.payload", table.concat({
    "#!/usr/bin/env bash",
    '[ "$1" = update ] && echo update >> "' .. ABS .. '/updates"',
    "exit 0",
}, "\n") .. "\n")
-- the stub curl: counts downloads and writes an installer that copies the payload
fs.write(REL .. "/stub/curl", table.concat({
    "#!/usr/bin/env bash",
    'echo "$*" >> "' .. ABS .. '/downloads"',
    'out=""; while [ $# -gt 0 ]; do [ "$1" = -o ] && out="$2"; shift; done',
    'printf \'%s\\n\' \'d=""; while [ $# -gt 0 ]; do [ "$1" = --dir ] && d="$2"; shift; done\' \'install -m 0755 "' .. ABS .. '/agy.payload" "$d/agy"\' > "$out"',
}, "\n") .. "\n")
proc.run{ argv = { "chmod", "+x", ABS .. "/stub/curl" } }

local CACHE = ABS .. "/home/.cache/tillandsias-project/harness-curl"
local function launch()
    fs.write(REL .. "/run.sh", table.concat({
        'trace_lifecycle() { echo "$1 | $2" >> "' .. ABS .. '/lifecycle"; }',
        "HARNESS_CURL_ROOT=" .. CACHE,
        ". " .. ABS .. "/fn.sh",
        "require_antigravity",
    }, "\n") .. "\n")
    return proc.run{ argv = { "bash", ABS .. "/run.sh" }, timeout_ms = 60000,
        env = { PATH = ABS .. "/stub:/usr/bin:/bin", HOME = ABS .. "/home" } }
end

arm("0 premise: require_antigravity was cut from lib-common.sh",
    fn:find("^require_antigravity%(%)") ~= nil, #fn)

local r = launch()
arm("1 FRESH: one download, agy installed under the tool cache, stamp written",
    r.code == 0 and count(REL .. "/downloads") == 1
        and fs.exists(CACHE .. "/agy/bin/agy") and fs.exists(CACHE .. "/agy/last-refresh.epoch"),
    "rc=" .. tostring(r.code) .. " downloads=" .. count(REL .. "/downloads")
        .. " agy=" .. tostring(fs.exists(CACHE .. "/agy/bin/agy")))

proc.run{ argv = { "rm", "-f", ABS .. "/lifecycle" } }
r = launch()
local life = readf(REL .. "/lifecycle")
arm("2 WARM: zero downloads, zero updates, one cached line",
    r.code == 0 and count(REL .. "/downloads") == 1 and count(REL .. "/updates") == 0
        and select(2, life:gsub("agy cached", "")) == 1 and not life:find("install attempt", 1, true),
    "rc=" .. tostring(r.code) .. " downloads=" .. count(REL .. "/downloads")
        .. " updates=" .. count(REL .. "/updates") .. " life=" .. life:sub(1, 200))

fs.mkdir(CACHE:sub(#root + 2) .. "/agy")
fs.write(CACHE:sub(#root + 2) .. "/agy/last-refresh.epoch", "0\n")
r = launch()
arm("3 STALE: one agy update, still no download",
    r.code == 0 and count(REL .. "/updates") == 1 and count(REL .. "/downloads") == 1,
    "rc=" .. tostring(r.code) .. " updates=" .. count(REL .. "/updates")
        .. " downloads=" .. count(REL .. "/downloads"))

proc.run{ argv = { "rm", "-rf", ABS } }
if #failed > 0 then
    verdict.emit("violation:" .. NAME .. ":" .. #failed .. "-failed", 1)
end
verdict.emit("ok:" .. NAME .. ":" .. passed .. " arms", 0)
