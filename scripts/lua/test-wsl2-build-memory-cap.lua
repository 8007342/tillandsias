-- @env TILLANDSIAS_WSL2_BUILD_MEMORY_HIGH
-- @trace order:667-kfyn
--
-- scripts/wsl2-build-memory-cap.sh against a constructed cgroup-v2 tree (the
-- TILLANDSIAS_WSL2_CGROUP_ROOT seam), so it runs on any host:
--   1 JOIN      a tree with the memory controller: the controller is enabled
--               for children, the group gets memory.high, the pid is written
--               to the group's cgroup.procs, and the verdict names the cap
--   2 DEFAULT   no argument and no env: the cap is 3G (the measured value)
--   3 OFF       "off" touches nothing (NEGATIVE CONTROL: no group created)
--   4 NO-MEM    a tree whose controllers lack memory: skip, exit 0, no group
--   5 WIRED     with-wsl2-builder.sh runs it in the guest prefix, before the build
--   6 NESTED    wsl-guest-session.sh nests its teardown cgroup inside the cap
-- Lua from the start (the 667-kfyn change pays its shell-to-lua carry, so it
-- adds no shell fixture).

local SUBJECT = "scripts/wsl2-build-memory-cap.sh"
local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.code ~= 0 or ROOT == "" then verdict.emit("could-not-run:wsl2-build-memory-cap:no-repo-root", 3) end

local REL = "target/plan-scratch/wsl2-memory-cap-" .. time.iso_utc():gsub("[^%w]", "") .. "-" .. tostring(math.random(100000, 999999))
local W = ROOT .. "/" .. REL

local pass, failed = 0, {}
local function arm(name, cond, got)
    if cond then out.line("ok   " .. name); pass = pass + 1 else
        out.line("FAIL " .. name .. " — got: " .. tostring(got):gsub("\n", " | "))
        failed[#failed + 1] = name
    end
end

local function tree(name, controllers)
    fs.mkdir(REL .. "/" .. name)
    fs.write(REL .. "/" .. name .. "/cgroup.controllers", controllers .. "\n")
    fs.write(REL .. "/" .. name .. "/cgroup.subtree_control", "")
    return REL .. "/" .. name
end
local function read(rel)
    if not fs.exists(rel) then return nil end
    return text.trim(fs.read(rel))
end
-- cap(tree, args...) -> rc, output; runs the subject with pid 4242. The caller's
-- TILLANDSIAS_WSL2_BUILD_MEMORY_HIGH is blanked (the base env passes every
-- TILLANDSIAS_ variable through), so arm 2 measures the script's own default.
local function cap(t, ...)
    local argv = { "bash", ROOT .. "/" .. SUBJECT }
    for _, a in ipairs({ ... }) do argv[#argv + 1] = a end
    local r = proc.run({ argv = argv, timeout_ms = 30000, env = {
        TILLANDSIAS_WSL2_BUILD_MEMORY_HIGH = "",
        TILLANDSIAS_WSL2_CGROUP_ROOT = ROOT .. "/" .. t,
        TILLANDSIAS_WSL2_CGROUP_PID = "4242" } })
    return r.code or -1, text.trim((r.stdout or "") .. (r.stderr or ""))
end

local T = tree("join", "cpuset cpu io memory pids")
local rc, o = cap(T, "2G")
arm("1 JOIN the controller is enabled, the cap written and the pid joined",
    rc == 0 and read(T .. "/cgroup.subtree_control") == "+memory"
    and read(T .. "/tillandsias-build/memory.high") == "2G"
    and read(T .. "/tillandsias-build/cgroup.procs") == "4242"
    and o == "ok:wsl2-build-memory-cap:tillandsias-build:high=2G",
    "rc=" .. rc .. " '" .. o .. "' high=" .. tostring(read(T .. "/tillandsias-build/memory.high")))

T = tree("default", "memory")
rc, o = cap(T)
arm("2 DEFAULT with no argument and no env the cap is 3G",
    rc == 0 and read(T .. "/tillandsias-build/memory.high") == "3G", "rc=" .. rc .. " '" .. o .. "'")

T = tree("off", "memory")
rc, o = cap(T, "off")
arm("3 OFF touches nothing",
    rc == 0 and o == "skip:wsl2-build-memory-cap:off" and not fs.exists(T .. "/tillandsias-build")
    and read(T .. "/cgroup.subtree_control") == "", "rc=" .. rc .. " '" .. o .. "'")

T = tree("nomem", "cpuset cpu io pids")
rc, o = cap(T)
arm("4 NO-MEM a tree without the memory controller is a named skip, exit 0",
    rc == 0 and o == "skip:wsl2-build-memory-cap:no-memory-controller" and not fs.exists(T .. "/tillandsias-build"),
    "rc=" .. rc .. " '" .. o .. "'")

-- Whole lines, so a commented-out copy does not satisfy them.
local function has_line(path, line)
    return ("\n" .. fs.read(path) .. "\n"):find("\n" .. line .. "\n", 1, true) ~= nil
end
arm("5 WIRED with-wsl2-builder.sh runs the cap in the guest prefix",
    has_line("scripts/with-wsl2-builder.sh", '_ENV_PREFIX="$_ENV_PREFIX bash scripts/wsl2-build-memory-cap.sh >&2 || true;"'),
    "with-wsl2-builder.sh no longer runs scripts/wsl2-build-memory-cap.sh in _ENV_PREFIX")

-- The session supervisor makes a cgroup of its own for teardown (1567-9fgi). At
-- the root it escaped the cap: measured 2026-10-17, Windows fell to 1.2 GB free
-- with the build outside tillandsias-build. It must nest under its own cgroup.
-- (Verified live in tillandsias-build: 0::/tillandsias-build/tillandsias-session-<pid>.)
arm("6 NESTED the guest session cgroup is created under the supervisor's own cgroup, inside the cap",
    has_line("scripts/wsl-guest-session.sh", [[    _gs_base="$_gs_root$(sed -n 's/^0:://p' /proc/$$/cgroup 2>/dev/null)"]])
    and has_line("scripts/wsl-guest-session.sh", [[    _gs_cg="$_gs_base/tillandsias-session-$$"]]),
    "wsl-guest-session.sh creates its cgroup outside the supervisor's own — the build escapes the memory cap")

proc.run({ argv = { "rm", "-rf", W }, timeout_ms = 30000 })
local total = pass + #failed
if #failed == 0 then verdict.emit("ok:wsl2-build-memory-cap:" .. total, 0) end
verdict.emit("refused:wsl2-build-memory-cap:" .. #failed .. "-of-" .. total, 1)
