-- @trace spec:init-incremental-builds, order:1955-hq7k, order:2166-dbpx
-- @env PATH HOME
--
-- test-build-image-network-isolation.lua — a podman build argv never pairs
-- --isolation chroot with a network other than host. Ported from the .sh of the
-- same name (order 2166-dbpx); same three arms.
--
-- podman refuses that pair outright ("cannot set --network other than host with
-- --isolation chroot"), and chroot is build-image.sh's default, so 1955-hq7k's
-- unconditional --network=private failed every image build.
--
-- Arms:
--   1. chroot -> build_network_args prints nothing
--   2. oci    -> build_network_args prints --network=private (the 1955-hq7k fix kept)
--   3. STATIC -> build-image.sh adds no --network of its own outside the helper,
--                and resolves BUILD_ISOLATION before it asks the helper
--
-- The helper is a bash function, so arms 1-2 call it through a two-line driver
-- written under target/plan-scratch (proc.run takes argv, never a shell string).
--
-- Usage: tillandsias-plan script run scripts/lua/test-build-image-network-isolation.lua
-- Verdict: ok:build-network-isolation:3/3

local LIB, BI = "scripts/lib/build-network.sh", "scripts/build-image.sh"
local ROOT = text.trim(proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 }).stdout or "")
if ROOT == "" then verdict.could_not_run("build-network-isolation", "not inside a git checkout") end

local pass, fail = 0, 0
local function arm(name, cond, why)
    if cond then pass = pass + 1; out.line("ok:   " .. name)
    else fail = fail + 1; out.line("FAIL: " .. name .. " — " .. why) end
end

local REL = "target/plan-scratch/dbpx-" .. tostring(math.random(100000, 999999)) .. tostring(math.random(100000, 999999))
fs.mkdir(REL)
fs.write(REL .. "/driver.sh", '. "$1" || exit 9\ndeclare -F build_network_args >/dev/null || exit 8\nbuild_network_args "$2"\n')
local function helper(iso)
    local r = proc.run({ argv = { "bash", ROOT .. "/" .. REL .. "/driver.sh", ROOT .. "/" .. LIB, iso },
        env = { PATH = env.get("PATH"), HOME = env.get("HOME") }, timeout_ms = 30000 })
    return r.code, text.trim(r.stdout or "")
end

if fs.read(LIB) then
    local rc, o = helper("chroot")
    arm("ARM 1: chroot builds carry no --network", rc == 0 and o == "",
        "rc=" .. tostring(rc) .. " printed '" .. o .. "' (podman refuses it)")
    rc, o = helper("oci")
    arm("ARM 2: oci builds keep --network=private", rc == 0 and o == "--network=private",
        "rc=" .. tostring(rc) .. " printed '" .. o .. "', expected --network=private")
else
    arm("ARM 1: chroot builds carry no --network", false, "no " .. LIB)
    arm("ARM 2: oci builds keep --network=private", false, "no " .. LIB)
end

local iso_line, use_line, raw = nil, nil, {}
for i, l in ipairs(text.lines(fs.read(BI) or "")) do
    if not iso_line and l:sub(1, 16) == "BUILD_ISOLATION=" then iso_line = i end
    if not use_line and text.contains(l, 'build_network_args "$BUILD_ISOLATION"') then use_line = i end
    if text.contains(l, "--network") and not l:match("^%s*#") then raw[#raw + 1] = tostring(i) end
end
arm("ARM 3: build-image.sh takes its build network only from the helper, after BUILD_ISOLATION",
    iso_line ~= nil and use_line ~= nil and iso_line < use_line and #raw == 0,
    "iso=" .. tostring(iso_line) .. " use=" .. tostring(use_line) .. " raw=" .. (#raw > 0 and table.concat(raw, ",") or "none"))

proc.run({ argv = { "rm", "-rf", ROOT .. "/" .. REL }, timeout_ms = 30000 })
if fail > 0 then verdict.emit("violation:build-network-isolation:" .. pass .. "/" .. (pass + fail), 1) end
verdict.ok("build-network-isolation", pass .. "/" .. (pass + fail))
