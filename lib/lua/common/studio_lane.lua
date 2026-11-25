-- @trace order:2347-dufz
-- common.studio_lane — what the studio lane fixtures (decap, tina, puck) share: build
-- images/studio/Containerfile.<id> on the local forge image, as the launcher builds it
-- on first use, and run it with its registry entry and --network none on a throwaway
-- checkout. The studio front answers on :4096 INSIDE the container.
--
--   lane.run(T, "decap", { files = { ["hugo.toml"] = "..." }, wait_s = 60 }, function(L) ... end)
--   L:js("fetch(...)...")   -- node in the running container: its output, trimmed
--   L:git("log", "-1")      -- git in the checkout: its stdout, trimmed
--
-- lane.run removes the container and the test image whatever the body does, then T:finish().
-- No podman, no local forge image, or a build that cannot reach the npm registry is
-- could-not-run:studio-<id>:<why> (exit 3), never a pass.
local fixture = require "common.fixture"
local M = {}
local L = {}
L.__index = L

local function both(r) return (r.stdout or "") .. (r.stderr or "") end

-- The forge image for this VERSION, else any local tag of it (as test-studio-front.lua).
local function forge_image(T)
    local want = env.get("TILLANDSIAS_TEST_FORGE_IMAGE")
    if not want or want == "" then want = "localhost/tillandsias-forge:v" .. text.trim(fs.read("VERSION")) end
    if T:run{ "podman", "image", "exists", want }.code == 0 then return want end
    local r = T:run{ "podman", "images", "--format", "{{.Repository}}:{{.Tag}}", "--filter", "reference=localhost/tillandsias-forge" }
    for l in (r.stdout or ""):gmatch("[^\n]+") do if not l:find("<none>", 1, true) then return l end end
end

function L:close()
    if self.started then self.T:run{ "podman", "rm", "-f", self.name }; self.started = nil end
    if self.built then self.T:run{ "podman", "rmi", "-f", self.tag }; self.built = nil end
end

function L:stop(line, code)
    self:close()
    self.T:cleanup()
    verdict.emit(line, code)
end

function L:js(src)
    return text.trim(both(self.T:run{ "podman", "exec", self.name, "node", "-e", src, timeout_ms = 60000 }))
end

-- fetch on the front: `init` is a JS literal or nil, `out` a JS expression over r (the
-- response) and t (its text).
function L:fetch(path, init, out)
    return self:js('fetch("http://127.0.0.1:4096' .. path .. '"' .. (init and "," .. init or "")
        .. ").then(async r=>{const t=await r.text();console.log(" .. (out or "r.status,t") .. ")})")
end

function L:post(path, body)
    return self:fetch(path, '{method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify(' .. body .. ")}")
end

function L:egress(url)
    return self:js('fetch("' .. url .. '").then(()=>console.log("reached"),()=>console.log("blocked"))')
end

function L:git(...)
    local argv = { "git", "-C", self.abs }
    for _, a in ipairs({ ... }) do argv[#argv + 1] = a end
    return text.trim(self.T:run(argv).stdout or "")
end

function L:logs() return both(self.T:run{ "podman", "logs", self.name }) end

-- What `keep(port)` listens on, from the kernel: hex ip:port rows in state LISTEN (0A).
-- Returns the rows and the ones beyond loopback (0100007F, or ::1).
function L:listeners(keep)
    local r = self.T:run{ "podman", "exec", self.name, "cat", "/proc/net/tcp", "/proc/net/tcp6" }
    local rows, leaks = {}, {}
    for l in (r.stdout or ""):gmatch("[^\n]+") do
        local ip, port, st = l:match("^%s*%d+:%s+(%x+):(%x+)%s+%x+:%x+%s+(%x+)")
        if st == "0A" and keep(port) then
            rows[#rows + 1] = ip .. ":" .. port
            if ip ~= "0100007F" and ip ~= "00000000000000000000000001000000" then leaks[#leaks + 1] = ip .. ":" .. port end
        end
    end
    return rows, leaks
end

function M.open(T, id, opts)
    local self = setmetatable({ T = T, id = id }, L)
    if not fixture.which("podman") then self:stop("could-not-run:studio-" .. id .. ":no-podman", 3) end
    self.forge = forge_image(T)
    if not self.forge then self:stop("could-not-run:studio-" .. id .. ":no-local-forge-image", 3) end
    local W = T:scratch()
    self.name = "studio-" .. id .. "-test-" .. W.leaf:match("(%d+)%-") .. "-" .. math.random(1000, 9999)
    self.tag = "localhost/tillandsias-studio-" .. id .. ":test-" .. self.name:match("test%-(.*)$")
    local root = fixture.repo_root()

    self.built = true -- a build cut short can leave the tag
    local r = T:run{ "podman", "build", "-q", "-t", self.tag, "--build-arg", "FORGE_IMAGE=" .. self.forge,
        "-f", root .. "/images/studio/Containerfile." .. id, root .. "/images/studio", timeout_ms = 700000 }
    if r.code ~= 0 then
        local e = both(r)
        if e:find("fetch https://registry.npmjs.org", 1, true) or e:find("ENOTFOUND", 1, true) or e:find("EAI_AGAIN", 1, true) then
            self:stop("could-not-run:studio-" .. id .. ":registry-fetch-failed", 3)
        end
        out.line("FAIL: studio-" .. id .. " did not build on " .. self.forge .. " — got: " .. text.trim(e):sub(-800))
        self:stop("violation:studio-" .. id .. ":did-not-build", 1)
    end

    -- The launcher's argv for a studio lane (apply_web_lane) and the git identity it
    -- passes (configure_git_identity), without which the front cannot commit.
    self.rel, self.abs = W.rel .. "/site", W.abs .. "/site"
    fs.mkdir(self.rel)
    for p, s in pairs(opts.files) do
        local dir = p:match("^(.*)/")
        if dir then fs.mkdir(self.rel .. "/" .. dir) end
        fs.write(self.rel .. "/" .. p, s)
    end
    T:must{ "git", "-C", self.abs, "init", "-q" }
    T:must{ "git", "-C", self.abs, "add", "-A" }
    T:must{ "git", "-C", self.abs, "-c", "user.email=fixture@tillandsias.invalid", "-c", "user.name=fixture", "commit", "-q", "-m", "site" }
    self.base = self:git("rev-parse", "HEAD")
    self.started = true
    T:run{ "podman", "run", "-d", "--rm", "--name", self.name, "--network", "none", "--userns", "keep-id",
        "--entrypoint", "/usr/local/bin/studio-" .. id, "-e", "TILLANDSIAS_STUDIO=" .. id, "-e", "TILLANDSIAS_PROJECT=site",
        "-e", "TILLANDSIAS_PROJECT_HOST_MOUNT=1", "-e", "TILLANDSIAS_GIT_NAME=fixture",
        "-e", "TILLANDSIAS_GIT_EMAIL=fixture@tillandsias.invalid", "-v", self.abs .. ":/home/forge/src/site:Z", self.tag }
    local probe = 'fetch("http://127.0.0.1:4096/healthz").then(r=>process.exit(r.ok?0:1),()=>process.exit(1))'
    for _ = 1, opts.wait_s do
        if T:run{ "podman", "exec", self.name, "node", "-e", probe }.code == 0 then
            out.line("forge=" .. self.forge)
            return self
        end
        T:run{ "sleep", "1" }
    end
    out.line("FAIL: the studio front never answered on :4096 — got: " .. self:logs():sub(-1500))
    self:stop("violation:studio-" .. id .. ":front-never-answered", 1)
end

-- Open the lane, run body(L), and always remove the container and the image.
function M.run(T, id, opts, body)
    local self = M.open(T, id, opts)
    local ok, err = pcall(body, self)
    self:close()
    if not ok then error(err, 0) end
    T:finish()
end

return M
