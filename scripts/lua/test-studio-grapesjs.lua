-- @env TILLANDSIAS_TEST_FORGE_IMAGE TILLANDSIAS_TEST_CHROMIUM_IMAGE PATH HOME XDG_RUNTIME_DIR
-- @trace order:1861-nmpp, order:1860-auhm, order:2108-dptd
--
-- test-studio-grapesjs.lua (ported from scripts/test-studio-grapesjs.sh, the
-- shell-to-lua item 2108-dptd owed). The GrapesJS studio LANE:
-- studio-grapesjs is built from images/studio/Containerfile.grapesjs on the
-- local forge image, as the launcher builds it on first use, and run with its
-- registry entry and --network none on a throwaway git checkout. Through the
-- studio front (:4096) it must serve the vendored core (no CDN) and the
-- project's page. A save posted to /__studio/save must land in index.html as
-- one commit, a path off the allowlist must be refused and write nothing, and
-- the studio must not reach the network. The browser arm drives the real
-- editor in headless chromium (#selftest makes one edit and saves it).
--
-- Lines: "FAIL: …" per failed check, then
-- ok:studio-grapesjs:lane (0) | violation:studio-grapesjs:<n>-failed (1) |
-- could-not-run:studio-grapesjs:<why> (2).
local function run(argv, ms) return proc.run{ argv = argv, timeout_ms = ms or 60000 } end
local function sleep(s) run({ "sleep", tostring(s) }, (s + 5) * 1000) end
local function out(r) return text.trim(r.stdout or "") end

if not run({ "podman", "--version" }, 15000).ok then
    verdict.emit("could-not-run:studio-grapesjs:no-podman", 2)
end
local version = text.trim(fs.read("VERSION") or "")
local function exists(tag) return tag ~= nil and tag ~= "" and run({ "podman", "image", "exists", tag }, 15000).ok end
local function local_tag(ref)
    local r = run({ "podman", "images", "--format", "{{.Repository}}:{{.Tag}}", "--filter", "reference=" .. ref }, 15000)
    for line in (r.stdout or ""):gmatch("[^\n]+") do
        if not line:find("<none>", 1, true) then return line end
    end
    return nil
end
local forge = env.get("TILLANDSIAS_TEST_FORGE_IMAGE")
if forge == nil or forge == "" then forge = "localhost/tillandsias-forge:v" .. version end
if not exists(forge) then forge = local_tag("localhost/tillandsias-forge") end
if not exists(forge) then verdict.emit("could-not-run:studio-grapesjs:no-local-forge-image", 2) end

local here = out(run({ "git", "rev-parse", "--show-toplevel" }, 5000))
local stamp = time.iso_utc():gsub("%W", "") .. "-" .. tostring(math.random(100000, 999999))
local work = here .. "/target/plan-scratch/studio-grapesjs-" .. stamp
local tag = "localhost/tillandsias-studio-grapesjs:test-" .. stamp:lower()
local name = "studio-grapesjs-test-" .. stamp:lower()
local pod = "studio-grapesjs-pod-" .. stamp:lower()
local function cleanup()
    run({ "podman", "pod", "rm", "-f", pod }, 30000)
    run({ "podman", "rm", "-f", name }, 30000)
    run({ "podman", "rmi", "-f", tag }, 30000)
    run({ "rm", "-rf", work }, 30000)
end
local function finish(line, code) cleanup(); verdict.emit(line, code) end

local b = run({ "podman", "build", "-q", "-t", tag, "--build-arg", "FORGE_IMAGE=" .. forge,
    "-f", here .. "/images/studio/Containerfile.grapesjs", here .. "/images/studio" }, 900000)
if not b.ok then
    if text.contains(b.stderr or "", "fetch https://registry.npmjs.org") then
        finish("could-not-run:studio-grapesjs:tarball-fetch-failed", 2)
    end
    log.raw(b.stderr or "")
    finish("violation:studio-grapesjs:did-not-build-on:" .. forge, 1)
end

local site = work .. "/site"
fs.mkdir(site)
local function g(args) local a = { "git", "-C", site }; for _, x in ipairs(args) do a[#a + 1] = x end; return run(a, 30000) end
g({ "init", "-q" })
fs.write(site .. "/index.html", "<!doctype html>\n<html><body>\n<h1>Before</h1>\n</body></html>\n")
g({ "add", "-A" })
g({ "-c", "user.email=fixture@tillandsias.invalid", "-c", "user.name=fixture", "commit", "-q", "-m", "site" })
local base = out(g({ "rev-parse", "HEAD" }))

-- The launcher's argv for a studio lane: the registry entry as entrypoint,
-- TILLANDSIAS_STUDIO naming it (apply_web_lane), and the git identity the
-- launcher passes (configure_git_identity), without which the front cannot commit.
local lane_env = { "-e", "TILLANDSIAS_STUDIO=grapesjs", "-e", "TILLANDSIAS_PROJECT=site",
    "-e", "TILLANDSIAS_PROJECT_HOST_MOUNT=1", "-e", "TILLANDSIAS_GIT_NAME=fixture",
    "-e", "TILLANDSIAS_GIT_EMAIL=fixture@tillandsias.invalid", "-v", site .. ":/home/forge/src/site:Z" }
local function lane_argv(extra)
    local a = { "podman", "run", "-d", "--rm" }
    for _, x in ipairs(extra) do a[#a + 1] = x end
    for _, x in ipairs({ "--userns", "keep-id", "--entrypoint", "/usr/local/bin/studio-grapesjs" }) do a[#a + 1] = x end
    for _, x in ipairs(lane_env) do a[#a + 1] = x end
    a[#a + 1] = tag
    return a
end
run(lane_argv({ "--name", name, "--network", "none" }), 60000)
local function probe(js) local r = run({ "podman", "exec", name, "node", "-e", js }, 30000); return out(r), r.ok end
local up = false
for _ = 1, 60 do
    local _, ok = probe('fetch("http://127.0.0.1:4096/healthz").then(r=>process.exit(r.ok?0:1),()=>process.exit(1))')
    if ok then up = true; break end
    sleep(1)
end
if not up then
    log.raw(out(run({ "podman", "logs", name }, 15000)))
    finish("violation:studio-grapesjs:front-never-answered-on-4096", 1)
end

local function js(s) return '"' .. s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub("\n", "\\n") .. '"' end
local function save(p, c)
    return (probe('fetch("http://127.0.0.1:4096/__studio/save",{method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify({path:'
        .. js(p) .. ',content:' .. js(c) .. '})}).then(async r=>console.log(r.status))'))
end
local vendor = probe('fetch("http://127.0.0.1:4096/vendor/dist/grapes.min.js").then(async r=>console.log(r.status,(await r.text()).length>100000?"big":"small"))')
local editor = probe('fetch("http://127.0.0.1:4096/").then(async r=>{const t=await r.text();console.log(r.status,/https?:\\/\\//.test(t.replace(/<!--[\\s\\S]*?-->/g,""))?"external-url":"self-contained")})')
local loaded = probe('fetch("http://127.0.0.1:4096/load").then(async r=>console.log(JSON.stringify(await r.json())))')
local stored = save("index.html", "<!doctype html><html><body><h1>After</h1></body></html>\n")
local refused = save("notes.txt", "outside the allowlist")
local egress = probe('fetch("https://registry.npmjs.org/").then(()=>console.log("reached"),()=>console.log("blocked"))')
for _, kv in ipairs({ { "forge", forge }, { "vendor", vendor }, { "editor", editor }, { "load", loaded },
    { "save", stored }, { "refused-save", refused }, { "egress", egress } }) do
    log.raw(kv[1] .. "=" .. kv[2])
end

local failures = 0
local function check(cond, msg) if not cond then log.raw("FAIL: " .. msg); failures = failures + 1 end end
check(vendor == "200 big", "vendored grapes.min.js not served through the front")
check(editor == "200 self-contained", "editor page references an external URL")
check(text.contains(loaded, "Before"), "/load did not return the project's page")
check(stored == "200", "the shared endpoint refused index.html")
local page = fs.read(site .. "/index.html") or ""
check(text.contains(page, "After") and not text.contains(page, "Before"), "the save did not reach index.html")
local subject = out(g({ "log", "-1", "--format=%s" }))
local changed = out(g({ "diff", "--name-only", base, "HEAD" }))
log.raw("commit=" .. subject); log.raw("changed=" .. changed)
-- 2108-dptd: the front saves on the studio's work branch, never the default.
check(subject == "studio(grapesjs): save index.html", "the save was not committed by the front")
check(changed == "index.html", "the commit touched more than index.html")
check(refused ~= "" and refused ~= "200", "a path outside the allowlist was accepted")
check(not fs.exists(site .. "/notes.txt"), "the refused save wrote notes.txt")
check(egress == "blocked", "the studio reached the network")
run({ "podman", "rm", "-f", name }, 30000)

-- Browser arm: the real editor in headless chromium, in a pod with no
-- network, makes one edit (#selftest) that its own Save stores through the front.
local chromium = env.get("TILLANDSIAS_TEST_CHROMIUM_IMAGE")
if chromium == nil or chromium == "" then chromium = "localhost/tillandsias-chromium-framework:v" .. version end
if not exists(chromium) then chromium = local_tag("localhost/tillandsias-chromium-framework") end
if exists(chromium) then
    run({ "podman", "pod", "create", "--name", pod, "--network", "none", "--userns", "keep-id" }, 30000)
    local a = { "podman", "run", "-d", "--rm", "--pod", pod, "--entrypoint", "/usr/local/bin/studio-grapesjs" }
    for _, x in ipairs(lane_env) do a[#a + 1] = x end
    a[#a + 1] = tag
    run(a, 60000)
    sleep(5)
    local dom = run({ "podman", "run", "--rm", "--pod", pod, "--entrypoint", "chromium-browser", chromium,
        "--headless=new", "--no-sandbox", "--disable-gpu", "--virtual-time-budget=15000", "--dump-dom",
        "http://127.0.0.1:4096/#selftest" }, 120000)
    sleep(2)
    local stored_page = fs.read(site .. "/index.html") or ""
    if text.contains(stored_page, "studio-selftest") then log.raw("browser-arm=stored")
    else log.raw("browser-arm=not-stored"); check(false, "the editor in a browser did not save its edit") end
    check(fs.exists(site .. "/.tillandsias/studio/grapesjs/project.json"), "project data not saved under .tillandsias/studio/grapesjs")
    check(text.contains(dom.stdout or "", "gjs-editor"), "GrapesJS did not initialise in the browser")
else
    log.raw("browser-arm=could-not-run:no-chromium-image:" .. tostring(chromium))
end

if failures == 0 then finish("ok:studio-grapesjs:lane", 0) end
finish("violation:studio-grapesjs:" .. failures .. "-failed", 1)
