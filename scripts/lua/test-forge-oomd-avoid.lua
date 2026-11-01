-- @env PATH HOME XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS
-- @trace order:1913-ebv8
--
-- test-forge-oomd-avoid.lua — forges are the LAST systemd-oomd candidate in
-- tillandsias.slice (crates/tillandsias-headless/src/oom_posture.rs).
--
--   arm 1 (the contract this relies on): in a throwaway slice capped at
--         MemoryHigh=200M (throttled, never OOM-killed; nothing outside it
--         feels the pressure), two identical allocating containers, each its
--         own candidate (memory.oom.group=1). The one whose user-owned scope
--         carries user.oomd_avoid survives; oomd kills the other. Run twice
--         with the mark swapped, so the mark, not the order, decides.
--   arm 2 (the launcher does it): every running tillandsias forge is in
--         tillandsias.slice and its scope carries memory.oom.group=1 and
--         user.oomd_avoid=1. With no forge running it could not run.
--
-- Verdict: ok:forge-oomd-avoid:<arms> | violation:forge-oomd-avoid:<why> (1) |
--          could-not-run:forge-oomd-avoid:<why> (2)

local SLICE = "tillandsias-ebv8-litmus.slice"
local IMAGE = "registry.fedoraproject.org/fedora-minimal:44"

local function run(argv, ms)
    return proc.run{ argv = argv, timeout_ms = ms or 30000 }
end

local function scope_of(container)
    local pid = text.trim(run({ "podman", "inspect", "-f", "{{.State.Pid}}", container }).stdout or "")
    if pid == "" or pid == "0" then return nil end
    -- /proc and /sys are outside the repo, so they are read and written
    -- through cat and tee, never fs.*.
    local cg = run({ "cat", "/proc/" .. pid .. "/cgroup" }).stdout or ""
    local rel = cg:match("0::(%S+)")
    if not rel then return nil end
    rel = rel:gsub("/container$", "")
    return "/sys/fs/cgroup" .. rel
end

local function avoid_of(scope)
    local r = run({ "getfattr", "--only-values", "-n", "user.oomd_avoid", scope })
    return r.ok and text.trim(r.stdout or "") == "1"
end

local function running(name)
    local r = run({ "podman", "ps", "--format", "{{.Names}}", "--filter", "name=^" .. name .. "$" })
    return text.trim(r.stdout or "") == name
end

if not run({ "getfattr", "--version" }).ok then
    verdict.emit("could-not-run:forge-oomd-avoid:no-getfattr", 2)
end
local mgr = text.trim(run({ "podman", "info", "--format", "{{.Host.CgroupManager}}" }).stdout or "")
if mgr ~= "systemd" then
    verdict.emit("could-not-run:forge-oomd-avoid:cgroup-manager-" .. (mgr ~= "" and mgr or "unknown"), 2)
end
if not run({ "podman", "pull", "-q", IMAGE }, 600000).ok then
    verdict.emit("could-not-run:forge-oomd-avoid:pull", 2)
end

-- ARM 1: one pressure run per placement of the mark.
local set = run({ "systemctl", "--user", "--no-ask-password", "set-property", "--runtime", SLICE,
    "MemoryHigh=200M", "ManagedOOMMemoryPressure=kill",
    "ManagedOOMMemoryPressureLimit=20%", "ManagedOOMMemoryPressureDurationSec=5s" })
if not set.ok then
    verdict.emit("could-not-run:forge-oomd-avoid:set-property", 2)
end

local function pressure_run(marked)
    local names = { "ebv8-litmus-a", "ebv8-litmus-b" }
    for _, n in ipairs(names) do
        run({ "podman", "rm", "-f", "-t", "0", n })
        local r = run({ "podman", "run", "-d", "--rm", "--pull=never", "--name", n,
            "--cgroup-parent=" .. SLICE, "--userns=keep-id", IMAGE, "sh", "-c", "tail /dev/zero" })
        if not r.ok then return nil, "run:" .. n end
        local sc = scope_of(n)
        if not sc then return nil, "scope:" .. n end
        if not proc.run{ argv = { "tee", sc .. "/memory.oom.group" }, stdin = "1", timeout_ms = 10000 }.ok then
            return nil, "oom.group:" .. n
        end
        if n == marked then
            if not run({ "setfattr", "-n", "user.oomd_avoid", "-v", "1", sc }).ok then
                return nil, "setfattr"
            end
        end
    end
    -- Bounded wait for oomd's kill: 3 minutes in 5 s steps.
    local survivor
    for _ = 1, 36 do
        local a, b = running(names[1]), running(names[2])
        if not (a and b) then survivor = a and names[1] or (b and names[2] or "none"); break end
        run({ "sleep", "5" }, 10000)
    end
    for _, n in ipairs(names) do run({ "podman", "rm", "-f", "-t", "0", n }) end
    return survivor or "neither-killed"
end

local s1, e1 = pressure_run("ebv8-litmus-a")
local s2, e2 = pressure_run("ebv8-litmus-b")
run({ "systemctl", "--user", "stop", SLICE })
if not s1 or not s2 then
    verdict.emit("could-not-run:forge-oomd-avoid:" .. tostring(e1 or e2), 2)
end
out.line("arm 1: avoid on a -> survivor " .. s1 .. "; avoid on b -> survivor " .. s2)
if s1 ~= "ebv8-litmus-a" or s2 ~= "ebv8-litmus-b" then
    verdict.emit("violation:forge-oomd-avoid:the-avoid-mark-did-not-decide:" .. s1 .. ":" .. s2, 1)
end

-- ARM 2: the launched forges.
local ps = run({ "podman", "ps", "--format", "{{.Names}}" })
local forges = {}
for name in (ps.stdout or ""):gmatch("[^\n]+") do
    if name:match("^tillandsias%-.+%-forge") then forges[#forges + 1] = name end
end
if #forges == 0 then
    out.line("arm 2: no tillandsias forge is running; launch one and re-run")
    verdict.emit("could-not-run:forge-oomd-avoid:no-running-forge", 2)
end
for _, f in ipairs(forges) do
    local sc = scope_of(f)
    if not sc or not sc:find("/tillandsias.slice/", 1, true) then
        verdict.emit("violation:forge-oomd-avoid:" .. f .. ":not-in-tillandsias.slice", 1)
    end
    local group = text.trim(run({ "cat", sc .. "/memory.oom.group" }).stdout or "")
    if group ~= "1" or not avoid_of(sc) then
        verdict.emit("violation:forge-oomd-avoid:" .. f .. ":scope-not-marked:oom.group=" .. group, 1)
    end
    out.line("arm 2: " .. f .. " is in tillandsias.slice, oom.group=1, user.oomd_avoid=1")
end
verdict.emit("ok:forge-oomd-avoid:2-arms:" .. #forges .. "-forge(s)", 0)
