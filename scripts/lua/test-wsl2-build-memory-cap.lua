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
--   7-11        scripts/wsl2-build-target-prune.sh: under the limit untouched,
--               incremental/ first, then debug/, never release/, never a /mnt/
--               target (NEGATIVE CONTROL), and wired into the builder
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

-- ── scripts/wsl2-build-target-prune.sh (the same order's disk half) ─────────
-- Sizes in KB through TILLANDSIAS_WSL2_TARGET_PRUNE_UNIT_KB=1, so a limit of
-- 1000 is crossed with a few MB. The target must be absolute in bash's own
-- spelling: under MSYS `C:/x` is `/c/x` to the script's case pattern.
local function bash_abs(p)
    local d, rest = p:match("^(%a):(/.*)$")
    return d and ("/" .. d:lower() .. rest) or p
end
local function prune(name, layout, max, target_override)
    local base = REL .. "/prune-" .. name
    for _, spec in ipairs(layout) do
        local f, kb = spec[1], spec[2]
        fs.mkdir(base .. "/" .. f:match("^(.*)/[^/]+$"))
        fs.write(base .. "/" .. f, string.rep("x", kb * 1024))
    end
    local r = proc.run({ argv = { "bash", ROOT .. "/scripts/wsl2-build-target-prune.sh", max }, timeout_ms = 60000,
        env = { TILLANDSIAS_WSL2_TARGET_PRUNE_UNIT_KB = "1", TILLANDSIAS_WSL2_TARGET_DEBUG_MAX_GB = "",
            -- arms 7-9 may run from a checkout under /mnt/c (the in-tree gate);
            -- only arm 10 keeps the real Windows-drive prefix
            TILLANDSIAS_WSL2_TARGET_PRUNE_PROTECT = target_override and "" or "/nonexistent-protect/",
            CARGO_TARGET_DIR = target_override or bash_abs(W .. "/prune-" .. name .. "/t") } })
    local o = (r.stdout or "") .. (r.stderr or "") .. " rc=" .. tostring(r.code)
    for _, d in ipairs({ "t/debug/incremental", "t/debug/deps", "t/debug", "t/release" }) do
        if fs.exists(base .. "/" .. d) then o = o .. " has:" .. d end
    end
    return o
end
local function has(s, p) return s:find(p, 1, true) ~= nil end

o = prune("under", { { "t/debug/deps/a", 100 }, { "t/release/p", 50 } }, "1000")
arm("7 UNDER a debug/ under the limit is left alone",
    has(o, "ok:wsl2-build-target-prune:debug=") and has(o, "rc=0") and has(o, "has:t/debug/deps"), o)

o = prune("incr", { { "t/debug/incremental/s", 3000 }, { "t/debug/deps/a", 100 }, { "t/release/p", 50 } }, "1000")
arm("8 INCREMENTAL over the limit drops debug/incremental first and keeps deps/ and release/",
    has(o, "pruned:wsl2-build-target-prune:incremental:") and not has(o, "has:t/debug/incremental")
    and has(o, "has:t/debug/deps") and has(o, "has:t/release"), o)

o = prune("whole", { { "t/debug/deps/a", 3000 }, { "t/release/p", 50 } }, "1000")
arm("9 WHOLE still over after incremental: all of debug/ goes, release/ stays",
    has(o, "pruned:wsl2-build-target-prune:debug:") and not has(o, "has:t/debug") and has(o, "has:t/release"), o)

o = prune("windows", { { "t/debug/deps/a", 3000 } }, "1000", "/mnt/c/Users/someone/checkout/target")
arm("10 WINDOWS-DRIVE a target on /mnt/ is the operator's and is never pruned (NEGATIVE CONTROL)",
    has(o, "skip:wsl2-build-target-prune:target-on-windows-drive") and has(o, "has:t/debug/deps"), o)

arm("11 WIRED with-wsl2-builder.sh runs the prune in the guest prefix",
    has_line("scripts/with-wsl2-builder.sh", '_ENV_PREFIX="$_ENV_PREFIX bash scripts/wsl2-build-target-prune.sh >&2 || true;"'),
    "with-wsl2-builder.sh no longer runs scripts/wsl2-build-target-prune.sh in _ENV_PREFIX")

proc.run({ argv = { "rm", "-rf", W }, timeout_ms = 30000 })
local total = pass + #failed
if #failed == 0 then verdict.emit("ok:wsl2-build-memory-cap:" .. total, 0) end
verdict.emit("refused:wsl2-build-memory-cap:" .. #failed .. "-of-" .. total, 1)
