-- @trace order:2007-rtky
-- @env PATH HOME XDG_RUNTIME_DIR
--
-- test-router-key-home-absent.lua — against the REAL running tillandsias-router:
--   1 MOUNTS  no bind source is $XDG_RUNTIME_DIR/tillandsias or an ancestor of it,
--             and the router's /run/host/tillandsias source is the control/ subdir
--   2 INSIDE  /run/host/tillandsias holds no keys/, secrets/ or ca-key-pass entry
--   3 SOCKET  /run/host/tillandsias/control.sock is present (the router still works)
-- Reads names only (podman inspect, ls); never reads a file's contents.
-- could-not-run when no router container is running on this host.
-- Pre-fix: arms 1 and 2 FAIL, the router bound the whole runtime dir rw.
--
-- Usage: tillandsias-plan script run scripts/lua/test-router-key-home-absent.lua

local function base_env()
    return {
        PATH = env.get("PATH") or "/usr/bin:/bin",
        HOME = env.get("HOME") or "",
        XDG_RUNTIME_DIR = env.get("XDG_RUNTIME_DIR") or "",
    }
end
local RT = (env.get("XDG_RUNTIME_DIR") or "") .. "/tillandsias"
local function podman(argv)
    local a = { "podman" }
    for _, x in ipairs(argv) do a[#a + 1] = x end
    local r = proc.run({ argv = a, env = base_env(), timeout_ms = 60000 })
    return r.code, r.stdout or "", r.stderr or ""
end

local c, o = podman({ "inspect", "-f", "{{.State.Running}}", "tillandsias-router" })
if c ~= 0 or text.trim(o) ~= "true" then
    verdict.could_not_run("router-key-home-absent", "no running tillandsias-router on this host")
end

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

local _, mounts = podman({ "inspect", "-f", "{{range .Mounts}}{{.Source}}|{{.Destination}}\n{{end}}", "tillandsias-router" })
local bad, host_src = {}, nil
for line in mounts:gmatch("[^\n]+") do
    local src, dst = line:match("^(.-)|(.*)$")
    if src then
        local s = src:gsub("/+$", "")
        if s == RT or RT:sub(1, #s + 1) == s .. "/" or s:find(RT .. "/keys", 1, true) then
            bad[#bad + 1] = src
        end
        if dst == "/run/host/tillandsias" then host_src = s end
    end
end
arm("1 MOUNTS no bind of the runtime dir or its ancestors; host dir is control/",
    #bad == 0 and host_src == RT .. "/control", "bad=" .. table.concat(bad, ",") .. " host=" .. tostring(host_src))

local _, ls = podman({ "exec", "tillandsias-router", "ls", "-A", "/run/host/tillandsias" })
local names = {}
for n in ls:gmatch("[^\n]+") do names[n] = true end
arm("2 INSIDE no keys/, secrets/ or ca-key-pass under /run/host/tillandsias",
    not names["keys"] and not names["secrets"] and not names["ca-key-pass"], ls)
arm("3 SOCKET control.sock is present", names["control.sock"] == true, ls)

if #failed > 0 then
    verdict.emit("violation:router-key-home-absent:" .. table.concat(failed, ","), 1, passed .. " passed")
end
verdict.ok("router-key-home-absent", passed .. " arms")
