-- @trace order:2067-dwqd
-- @env PATH HOME XDG_RUNTIME_DIR TILLANDSIAS_HEADLESS_BIN
--
-- test-memory-stall-named.lua — a container held at its memory.high is NAMED
-- by the tray's watch, and an idle one beside it is not (2067-dwqd).
--
-- The demon_attack forge sat at memory.high for about two hours with nothing
-- on the tray: memory.high throttles instead of killing, by the operator's
-- choice, so the stall was silent. This drives the real binary's
-- `--memory-stall`, the same pass the tray's resident watch runs, against two
-- real containers in tillandsias.slice (where 1913-ebv8 puts every forge):
--   HOG   memory.high 64 MiB, memory.max 512 MiB, no swap, running
--         `tail /dev/zero` (its buffer grows without end), so it is pinned
--         at high: throttled, never OOM-killed
--   IDLE  the same budget running `sleep` (NEGATIVE CONTROL)
-- Before any verdict the fixture asserts its premise from the kernel: the
-- HOG's scope reads full avg60 >= 10 with high events, and the IDLE's does
-- not. The image is the forge base (the forge's own userland), at a versioned tag.
--
-- PRE-FIX: the binary has no --memory-stall and answers Unsupported option.
-- The binary is TILLANDSIAS_HEADLESS_BIN, else target/debug/tillandsias.
-- Verdict: ok:memory-stall-named:<arms>; refused:...; could-not-run:...
-- Usage: tillandsias-plan script run scripts/lua/test-memory-stall-named.lua

local NAME = "memory-stall-named"
local REPO = "localhost/tillandsias-forge-base"
local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.code ~= 0 or ROOT == "" then verdict.could_not_run(NAME, "git rev-parse --show-toplevel did not answer") end
local BIN = env.get("TILLANDSIAS_HEADLESS_BIN")
if not BIN or BIN == "" then BIN = ROOT .. "/target/debug/tillandsias" end
if proc.run({ argv = { "test", "-x", BIN }, timeout_ms = 10000 }).code ~= 0 then
    verdict.skip(NAME, "no-headless-binary", "no headless binary at " .. BIN .. " (cargo build -p tillandsias-headless, or set TILLANDSIAS_HEADLESS_BIN)")
end
-- A VERSIONED tag, never the mutable one (check-container-bases): the newest
-- v<version> tag of the forge base in this store.
local tags = proc.run({ argv = { "podman", "images", "--filter", "reference=" .. REPO, "--format", "{{.Tag}}" }, timeout_ms = 30000 })
local IMG
for _, t in ipairs(text.lines(tags.stdout or "")) do
    if t:match("^v%d") then IMG = REPO .. ":" .. t; break end
end
if not IMG then
    verdict.could_not_run(NAME, "no versioned " .. REPO .. " tag in the store (tillandsias --init builds it)")
end

local tag = tostring(math.random(100000, 999999))
local HOG = "tillandsias-stallfixture-" .. tag .. "-hog"
local IDLE = "tillandsias-stallfixture-" .. tag .. "-idle"
local function start(name, cmd)
    return proc.run({ argv = { "podman", "run", "-d", "--rm", "--name", name, "--pull=never",
        "--cgroup-parent=tillandsias.slice", "--network=none", "--cap-drop=ALL",
        "--security-opt=no-new-privileges", "--memory=512m",
        "--cgroup-conf=memory.high=67108864", "--cgroup-conf=memory.swap.max=0",
        "--entrypoint", "/bin/sh", IMG, "-c", cmd }, timeout_ms = 120000 })
end
local function cleanup()
    proc.run({ argv = { "podman", "rm", "-f", "-t", "0", HOG, IDLE }, timeout_ms = 60000 })
end

local h, i = start(HOG, "tail /dev/zero"), start(IDLE, "sleep 600")
if not (h.ok and i.ok) then
    log.raw(text.trim((h.stderr or "") .. "\n" .. (i.stderr or "")))
    cleanup()
    verdict.could_not_run(NAME, "podman could not start the fixture containers in tillandsias.slice")
end

-- full avg60 is a one-minute average: let it build (measured on yoga
-- 2026-11-10: 6.9 at 15 s, 17.9 at 30 s, 36.3 at 60 s).
proc.run({ argv = { "sleep", "35" }, timeout_ms = 60000 })

-- The runner admits no shell and reads only inside the repository, so the
-- scope path is spelled exactly: rootless user@<uid>.service/tillandsias.slice,
-- else rootful /tillandsias.slice.
local UID = text.trim(proc.run({ argv = { "id", "-u" }, timeout_ms = 10000 }).stdout or "")
local function scope_file(name, file)
    local id = text.trim(proc.run({ argv = { "podman", "inspect", "--format", "{{.Id}}", name }, timeout_ms = 30000 }).stdout or "")
    for _, parent in ipairs({
        "/sys/fs/cgroup/user.slice/user-" .. UID .. ".slice/user@" .. UID .. ".service/tillandsias.slice",
        "/sys/fs/cgroup/tillandsias.slice" }) do
        local g = proc.run({ argv = { "cat", parent .. "/libpod-" .. id .. ".scope/" .. file }, timeout_ms = 10000 })
        if g.code == 0 then return g.stdout or "" end
    end
    return ""
end
local function full60(name) return tonumber((scope_file(name, "memory.pressure"):match("full avg10=[%d.]+ avg60=([%d.]+)"))) or -1 end
local function high(name) return tonumber((scope_file(name, "memory.events"):match("\nhigh (%d+)") or scope_file(name, "memory.events"):match("^high (%d+)"))) or -1 end

local hp, ip, hh = full60(HOG), full60(IDLE), high(HOG)
if not (hp >= 10 and hh > 0 and ip >= 0 and ip < 2) then
    cleanup()
    verdict.emit("refused:" .. NAME .. ":premise", 1,
        string.format("the kernel does not show the planted stall: hog full avg60=%s high=%s, idle full avg60=%s", hp, hh, ip))
end
out.line(string.format("premise: hog full avg60=%.2f high=%d; idle full avg60=%.2f", hp, hh, ip))

local r = proc.run({ argv = { BIN, "--memory-stall", "--for", "10" }, timeout_ms = 120000 })
cleanup()
local o = (r.stdout or "") .. (r.stderr or "")

local failed, passes = {}, 0
local function arm(name, cond, got)
    if cond then passes = passes + 1; out.line("ok:   " .. name) else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got):gsub("\n", " | "))
        failed[#failed + 1] = name
    end
end
arm("1 HOG the container pinned at memory.high is named, by name",
    o:find("warn:memory-stall: " .. HOG .. " is stalled on memory", 1, true) ~= nil, o)
arm("2 EXIT --memory-stall exits 1 when it names a stall", r.code == 1, r.code)
arm("3 IDLE the idle container beside it is not named (negative control)",
    o:find(IDLE .. " is stalled", 1, true) == nil, o)
arm("4 BUDGET the message names the 64 MiB memory.high it is held at",
    o:find("against a 64 MiB memory.high", 1, true) ~= nil, o)

if #failed > 0 then verdict.emit("refused:" .. NAME .. ":" .. #failed .. "-of-4", 1) end
verdict.emit("ok:" .. NAME .. ":" .. passes, 0)
