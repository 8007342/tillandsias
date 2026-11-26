-- @trace spec:git-mirror-service, order:2373-8vq6
--
-- common/gitimage.lua — run a script inside the git-mirror image, under the mirror's posture.
--
--   local G = require("common.gitimage").new(T)   -- skips T with no podman; builds the image
--   local r = G:run(script, { mounts = { ["images/git/x.sh"] = "/usr/local/bin/x" } })
--   r.out (stdout and stderr), r.rc
--
-- The script is a mounted file, never `bash -c`, so nothing is quoted twice.

local fixture = require "common.fixture"
local M, G = {}, {}
G.__index = G
M.TAG = "localhost/tillandsias-git:latest"
-- --read-only --cap-drop=ALL --user 1000, writable state on /tmp only (749-wv4d).
M.POSTURE = { "--read-only", "--cap-drop=ALL", "--user", "1000", "--tmpfs", "/tmp:rw,mode=1777" }

function M.new(T)
    if not fixture.which("podman") then T:skip("no-podman") end
    local root = fixture.repo_root()
    local r = T:run{ root .. "/scripts/build-image.sh", "git", cwd = root, timeout_ms = 600000 }
    if r.code ~= 0 then T:refuse("image-build-failed", ((r.stdout or "") .. (r.stderr or "")):sub(-1500)) end
    return setmetatable({ T = T, root = root, dir = T:scratch("inner"), n = 0 }, G)
end

-- opts: posture (default M.POSTURE), mounts {repo path = container path}, env, args (after the script),
-- shell (default /bin/bash), volumes (verbatim -v values), timeout_ms.
function G:run(script, opts)
    opts = opts or {}
    self.n = self.n + 1
    local leaf = "/inner-" .. self.n .. ".sh"
    fs.write(self.dir.rel .. leaf, script)
    local argv = { "podman", "run", "--rm" }
    for _, a in ipairs(opts.posture or M.POSTURE) do argv[#argv + 1] = a end
    for k, v in pairs(opts.env or {}) do argv[#argv + 1] = "--env"; argv[#argv + 1] = k .. "=" .. v end
    for _, v in ipairs(opts.volumes or {}) do argv[#argv + 1] = "-v"; argv[#argv + 1] = v end
    local function mount(host, inside) argv[#argv + 1] = "-v"; argv[#argv + 1] = host .. ":" .. inside .. ":ro,z" end
    for host, inside in pairs(opts.mounts or {}) do mount(host:sub(1, 1) == "/" and host or self.root .. "/" .. host, inside) end
    mount(self.dir.abs .. leaf, "/inner.sh")
    argv[#argv + 1] = "--entrypoint"; argv[#argv + 1] = opts.shell or "/bin/bash"
    argv[#argv + 1] = M.TAG; argv[#argv + 1] = "/inner.sh"
    for _, a in ipairs(opts.args or {}) do argv[#argv + 1] = a end
    local r = proc.run{ argv = argv, cwd = self.root, timeout_ms = opts.timeout_ms or 120000 }
    local o = ((r.stdout or "") .. (r.stderr or "")):gsub("\r", "")
    return { rc = r.code, out = o, why = "rc=" .. tostring(r.code) .. " " .. o:sub(-700) .. tostring(r.why or "") }
end

return M
