-- @env PATH HOME XDG_RUNTIME_DIR
-- @trace order:1860-auhm, order:2108-dptd, spec:web-studio-lane
--
-- test-studio-front.lua — the studio write-back guard and its front, run where
-- they run: inside a forge image (its node and git), --network none, never on
-- the host. The arms are images/studio/studio-front.selftest.js:
--   1 a save to ../../etc/x, .git/config, a nested .GIT, an absolute path, a
--     symlink out of the checkout, or a path off the allowlist is refused,
--     writes nothing, commits nothing, and is evented once each;
--   2 an allowlisted save is written, committed as studio(<id>): save <path>,
--     and evented;
--   3 the same bytes again commit nothing;
--   4 the real HTTP front refuses a traversal POST (403), commits an
--     allowlisted one, 404s a PWA path and 400s a malformed body;
--   5 an own-writer studio (decap): what a proxied write request wrote is
--     committed when allowlisted and removed when not, and an edit made
--     before the request (the agent's) is left untouched;
--   6 2120-sv7m: a save pushes the studio's work branch (never the default
--     branch) to origin, the project's git mirror, which relays it to the
--     cloud; an unreachable origin keeps the save, says pushed:false, events
--     studio.push_failed, and the next save pushes it.
-- Also checks the committed registry JSON is what registry.lua generates.
--
-- The verdict is the container's STDOUT alone (1926-pjn8): pull progress on
-- stderr must never decide it. The forge image is the local
-- tillandsias-forge:v<VERSION>, else any local forge tag (node and git are all
-- the arms need); with none present the test could not run.
-- Verdict: ok:studio-front:<n>-arms | violation:studio-front:<why> (1) |
--          could-not-run:studio-front:<why> (2)
-- 2108-dptd: then images/studio/grapesjs/grapesjs.selftest.mjs (5 arms) in the same image;
-- the ok line is ok:studio-front:<n>-arms+studio-grapesjs-page:<m>-arms+studio-puck-site:<k>-arms (2110-pk4s).

local function judge(ok, stdout)
    local out = text.trim(stdout or "")
    local last = out:match("([^\n]*)$") or ""
    if last:find("^ok:studio%-front:") and ok then return last, 0 end
    if not last:find("^refused:studio%-front:") then return nil, 2 end
    return "violation:" .. last:gsub("^refused:", ""), 1
end

-- ARM 0: noise on stderr after a passing stdout is still a pass.
local v0, c0 = judge(true, "ok:studio-front:4-arms\n")
if c0 ~= 0 or v0 ~= "ok:studio-front:4-arms" then
    verdict.emit("violation:studio-front:arm0-judge", 1)
end

local plan = proc.run{ argv = { "tillandsias-plan", "script", "run",
    "scripts/lua/build-studio-registry.lua", "--", "--check" }, timeout_ms = 60000 }
if not (plan.stdout or ""):find("ok:studio%-registry:fresh:") then
    verdict.emit("violation:studio-front:registry-json-stale:run-build-studio-registry.lua", 1)
end

local version = text.trim(fs.read("VERSION") or "")
local function exists(tag)
    return proc.run{ argv = { "podman", "image", "exists", tag }, timeout_ms = 15000 }.ok
end
local image = "localhost/tillandsias-forge:v" .. version
if not exists(image) then
    local tags = proc.run{ argv = { "podman", "images", "--format", "{{.Repository}}:{{.Tag}}",
        "--filter", "reference=localhost/tillandsias-forge" }, timeout_ms = 15000 }
    image = nil
    for line in (tags.stdout or ""):gmatch("[^\n]+") do
        if not line:find("<none>", 1, true) then image = line; break end
    end
end
if not image then
    verdict.emit("could-not-run:studio-front:no-local-forge-image", 2)
end

local here = text.trim(proc.run{ argv = { "pwd" }, timeout_ms = 5000 }.stdout or "")
local r = proc.run{ argv = { "podman", "run", "--rm", "--network=none", "--pull=never",
    "--security-opt=label=disable",
    "-v", here .. "/images/studio:/s:ro",
    "-v", here .. "/crates/tillandsias-headless/data:/d:ro",
    "--entrypoint", "node", image, "/s/studio-front.selftest.js", "/d/studios.json" },
    timeout_ms = 120000 }
log.raw(text.trim((r.stdout or "") .. "\n" .. (r.stderr or "")))

local v, code = judge(r.ok, r.stdout)
if code == 2 then
    verdict.emit("could-not-run:studio-front:podman:" .. tostring(r.status or "?"), 2)
end
if code ~= 0 then verdict.emit(v, code) end

-- 2108-dptd: the GrapesJS page arms (document root, lossless head, work
-- branch, vendored icons), images/studio/grapesjs/grapesjs.selftest.mjs.
local p = proc.run{ argv = { "podman", "run", "--rm", "--network=none", "--pull=never",
    "--security-opt=label=disable",
    "-v", here .. "/images/studio:/s:ro",
    "-v", here .. "/crates/tillandsias-headless/data:/d:ro",
    "-e", "STUDIO_FRONT=/s/studio-front.js",
    "--entrypoint", "node", image, "/s/grapesjs/grapesjs.selftest.mjs", "/d/studios.json" },
    timeout_ms = 120000 }
log.raw(text.trim((p.stdout or "") .. "\n" .. (p.stderr or "")))
local plast = (text.trim(p.stdout or "")):match("([^\n]*)$") or ""
if plast:find("^refused:studio%-grapesjs%-page:") then
    verdict.emit("violation:" .. plast:gsub("^refused:", ""), 1)
end
if not (p.ok and plast:find("^ok:studio%-grapesjs%-page:")) then
    verdict.emit("could-not-run:studio-grapesjs-page:podman:" .. tostring(p.status or "?"), 2)
end

-- 2110-pk4s: the Puck site-build and Save arms (site config found, cache
-- outside the checkout, Save is the only writer, the site's public/ served),
-- images/studio/puck/puck.selftest.mjs. No network: npm is stubbed.
local k = proc.run{ argv = { "podman", "run", "--rm", "--network=none", "--pull=never",
    "--security-opt=label=disable",
    "-v", here .. "/images/studio:/s:ro",
    "--entrypoint", "node", image, "/s/puck/puck.selftest.mjs" },
    timeout_ms = 120000 }
log.raw(text.trim((k.stdout or "") .. "\n" .. (k.stderr or "")))
local klast = (text.trim(k.stdout or "")):match("([^\n]*)$") or ""
if k.ok and klast:find("^ok:studio%-puck%-site:") then
    verdict.emit(v .. "+" .. plast:gsub("^ok:", "") .. "+" .. klast:gsub("^ok:", ""), 0)
end
if klast:find("^refused:studio%-puck%-site:") then
    verdict.emit("violation:" .. klast:gsub("^refused:", ""), 1)
end
verdict.emit("could-not-run:studio-puck-site:podman:" .. tostring(k.status or "?"), 2)
