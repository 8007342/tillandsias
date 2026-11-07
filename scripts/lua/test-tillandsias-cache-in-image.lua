-- @trace order:2005-ccli
-- @env PATH HOME XDG_RUNTIME_DIR TILLANDSIAS_FORGE_IMAGE
--
-- test-tillandsias-cache-in-image.lua — 2005-ccli exit criterion, in a BUILT
-- forge image with no host checkout and no network:
--   1 HELP     `tillandsias-cache --help` answers the usage
--   2 PUT-GET  a put and a get for a "docs" stage (a project that is not
--              tillandsias) on a scratch project cache round-trip the file
--   3 NOCACHE  with no project cache it refuses no_project_cache, exit 2,
--              and prints nothing on stdout
-- The image is $TILLANDSIAS_FORGE_IMAGE, else the newest localhost/tillandsias-forge;
-- could-not-run when neither exists here.
--
-- Usage: tillandsias-plan script run scripts/lua/test-tillandsias-cache-in-image.lua

local function base_env()
    return {
        PATH = env.get("PATH") or "/usr/bin:/bin",
        HOME = env.get("HOME") or "",
        XDG_RUNTIME_DIR = env.get("XDG_RUNTIME_DIR") or "",
    }
end

local IMG = env.get("TILLANDSIAS_FORGE_IMAGE")
local imgs = IMG and { status = "exited", code = 0, stdout = IMG } or proc.run({
    argv = { "podman", "images", "--format", "{{.Repository}}:{{.Tag}}", "--filter", "reference=localhost/tillandsias-forge" },
    env = base_env(), timeout_ms = 60000,
})
if imgs.status ~= "exited" or imgs.code ~= 0 then
    verdict.could_not_run("tillandsias-cache-in-image", "podman images did not answer")
end
IMG = (imgs.stdout or ""):match("([^\n]+)")
if not IMG or IMG == "" then
    verdict.could_not_run("tillandsias-cache-in-image", "no localhost/tillandsias-forge image is built on this host")
end

local function in_image(script)
    local r = proc.run({
        argv = { "podman", "run", "--rm", "--network", "none", "--entrypoint", "/bin/sh", IMG, "-c", script },
        env = base_env(), timeout_ms = 120000,
    })
    return r.code, r.stdout or "", r.stderr or ""
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
local function has(s, needle) return (s or ""):find(needle, 1, true) ~= nil end

local c, o, e = in_image("tillandsias-cache --help")
arm("1 HELP answers the usage in " .. IMG, c == 0 and has(o, "Usage: tillandsias-cache"), c .. " " .. o .. e)

c, o, e = in_image([[
set -e
export TILLANDSIAS_PROJECT_CACHE="$(mktemp -d /tmp/pc.XXXXXX)"
printf '<h1>intro</h1>\n' > /tmp/intro.html
printf '{"page":"intro","lang":"en"}' > /tmp/in.json
tillandsias-cache put --stage docs --inputs /tmp/in.json --file /tmp/intro.html
tillandsias-cache get --stage docs --inputs /tmp/in.json --out-dir /tmp/out
cat /tmp/out/intro.html
]])
arm("2 PUT-GET round-trips a docs stage on a scratch project cache",
    c == 0 and has(o, '"stored": true') and has(o, '"hit": true') and has(o, "<h1>intro</h1>"), c .. " " .. o .. e)

c, o, e = in_image("TILLANDSIAS_PROJECT_CACHE=/nonexistent tillandsias-cache stats")
arm("3 NOCACHE refuses no_project_cache, exit 2, nothing on stdout",
    c == 2 and o == "" and has(e, "refused:tillandsias-cache:no_project_cache"), c .. " " .. o .. e)

if #failed > 0 then
    verdict.emit("violation:tillandsias-cache-in-image:" .. table.concat(failed, ","), 1, passed .. " passed")
end
verdict.ok("tillandsias-cache-in-image", passed .. " arms in " .. IMG)
