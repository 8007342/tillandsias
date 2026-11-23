-- @trace order:1843-dex5, order:2080-zcur
--
-- test-builder-toolbox-exists.lua — _toolbox_exists in with-tillandsias-builder.sh
-- must not answer "absent" for a container that exists just because
-- `toolbox list` failed this once. A false "absent" sends the caller into
-- `toolbox create`, which dies "container tillandsias-builder already exists"
-- (land queue, macuahuitl 2026-10-23: #612 evicted with the builder up 43 h).
--
-- The function is cut from the script by name (it execs on load, so it cannot
-- be sourced whole) and run against stub toolbox/podman on PATH.
--   arm1  toolbox list FAILS, podman says it exists   -> exists.  PRE-FIX: absent.
--   arm2  toolbox list FAILS, podman says it does not -> absent (negative control).
--   arm3  podman unavailable, toolbox lists it         -> exists (fallback kept).
-- Ported from scripts/test-builder-toolbox-exists.sh onto common.fixture.
--
-- Usage: tillandsias-plan script run scripts/lua/test-builder-toolbox-exists.lua
-- Verdict: ok:builder-toolbox-exists:<n> arms | violation:builder-toolbox-exists:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("builder-toolbox-exists")
local W = T:scratch()

local buf, inside = {}, false
for _, l in ipairs(text.lines(fs.read("scripts/with-tillandsias-builder.sh") or "")) do
    if not inside and l == "_toolbox_exists() {" then inside = true end
    if inside then
        buf[#buf + 1] = l
        if l == "}" then break end
    end
end
if #buf == 0 then T:refuse("function-not-found", "_toolbox_exists not found in scripts/with-tillandsias-builder.sh") end
fs.write(W.rel .. "/fn.sh", table.concat(buf, "\n") .. "\n")
fs.write(W.rel .. "/probe.sh", '. "$1"\n_toolbox_exists && echo exists || echo absent\n')

local function which(t)
    return fixture.which(t) or T:refuse("no-tool", t .. " is not on PATH")
end
local BASH = which("bash")
local TOOLS = {}
for _, t in ipairs{ "awk", "grep", "sh" } do TOOLS[t] = which(t) end

local STUB = {
    fail = "#!/bin/sh\nexit 1\n",
    list = '#!/bin/sh\nprintf "CONTAINER ID  CONTAINER NAME  CREATED  STATUS  IMAGE\\nefe9  tillandsias-builder  5d  running  fedora\\n"\n',
    yes = "#!/bin/sh\nexit 0\n",
    no = "#!/bin/sh\nexit 1\n",
}
local function probe(name, toolbox, podman)
    local d = W.rel .. "/" .. name
    fs.mkdir(d)
    fs.write(d .. "/toolbox", STUB[toolbox])
    if STUB[podman] then fs.write(d .. "/podman", STUB[podman]) end
    T:must{ "chmod", "-R", "+x", W.abs .. "/" .. name }
    for t, p in pairs(TOOLS) do T:must{ "ln", "-sf", p, W.abs .. "/" .. name .. "/" .. t } end
    local r = T:run{ BASH, W.abs .. "/probe.sh", W.abs .. "/fn.sh",
        env = { PATH = W.abs .. "/" .. name, TOOLBOX_NAME = "tillandsias-builder" } }
    return text.trim(r.stdout or "")
end

local r = probe("a1", "fail", "yes")
T:arm("arm1 failed toolbox list does not hide an existing container", r == "exists", r)
r = probe("a2", "fail", "no")
T:arm("arm2 absent container still reads absent", r == "absent", r)
r = probe("a3", "list", "absent")
T:arm("arm3 toolbox list fallback still finds it", r == "exists", r)

T:finish()
