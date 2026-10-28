-- @trace spec:project-bootstrap-readme, order:1906-md6q
-- @env PATH
--
-- test-start-a-new-project-gcp.lua — order 1906-md6q.
--
-- The start-a-new-project scaffold's Google Cloud deploy targets render their
-- own files, filled in, without overwriting anything.
--
--   1 --deploy gcp-dockerfile (static, flutter) renders Dockerfile, nginx
--     template, .dockerignore, cloudbuild.yaml, service.yaml: no {{...}} left,
--     the slug and port filled in, a non-root base, $PORT honoured
--   2 --deploy gcp-buildpacks --runtime python --port 9000 renders
--     project.toml (GOOGLE_RUNTIME=python) and service.yaml (port 9000)
--   3 the runtime is read from the project's files (package.json -> node)
--   4 buildpacks for a static app exits 3 and creates NOTHING
--   5 a second run creates nothing; a user's own Dockerfile is kept
--   6 the skill states the billing requirement; the scaffold never calls gcloud
--
-- Asserts only its own files (the shared convention with the Cloudflare
-- target). Base scaffold files (README, plan, research) are 4 of the 9 in arm 1.
--
-- Usage: tillandsias-plan script run scripts/lua/test-start-a-new-project-gcp.lua

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.status ~= "exited" or top.code ~= 0 or ROOT == "" then
    verdict.could_not_run("start-a-new-project-gcp", "git rev-parse --show-toplevel did not answer")
end
local SKILL = ROOT .. "/skills/start-a-new-project"
local S = SKILL .. "/scaffold.sh"
if not fs.exists(S) then
    verdict.emit("violation:start-a-new-project-gcp:no-subject", 1, S .. " does not exist (1906-md6q)")
end
local W = ROOT .. "/target/plan-scratch/start-a-new-project-gcp-" .. time.iso_utc() .. "-" .. tostring(math.random(100000, 999999))
fs.mkdir(W)

local failed = {}
local function arm(name, cond, got)
    got = got and tostring(got):gsub("\n", " | ") or nil
    if cond then out.line("ok:   " .. name) else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got))
        failed[#failed + 1] = name
    end
end
local function scaffold(dir, args)
    local argv = { "bash", S, "--dir", dir }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local r = proc.run({ argv = argv, timeout_ms = 60000 })
    return r.code, (r.stdout or "") .. (r.stderr or "")
end
local function has(path, needle) return fs.exists(path) and (fs.read(path) or ""):find(needle, 1, true) ~= nil end
local function has_line(s, line) return ("\n" .. s .. "\n"):find("\n" .. line .. "\n", 1, true) ~= nil end
local function placeholders_left(dir)
    for _, f in ipairs(fs.list(dir) or {}) do
        if (fs.read(dir .. "/" .. f) or ""):find("{{", 1, true) then return f end
    end
    return nil
end

-- 1
local A = W .. "/a"; fs.mkdir(A)
local rc, o = scaffold(A, { "--name", "Pong Party", "--summary", "s", "--stack", "flutter", "--deploy", "gcp-dockerfile", "--no-specs" })
local left = placeholders_left(A)
arm("1 gcp-dockerfile renders five files for a Flutter web app, filled in, unprivileged nginx on $PORT",
    rc == 0 and fs.exists(A .. "/Dockerfile") and fs.exists(A .. "/nginx.conf.template") and fs.exists(A .. "/.dockerignore")
    and fs.exists(A .. "/cloudbuild.yaml") and fs.exists(A .. "/service.yaml") and not left
    and has(A .. "/service.yaml", "\n  name: pong-party\n") and has(A .. "/service.yaml", "containerPort: 8080")
    and has(A .. "/cloudbuild.yaml", "_SERVICE_NAME: pong-party")
    and has(A .. "/Dockerfile", "\nFROM docker.io/nginxinc/nginx-unprivileged:")
    and has(A .. "/nginx.conf.template", "listen ${PORT};") and has_line(text.trim(o), "ok:scaffold:9"),
    "rc=" .. tostring(rc) .. " left=" .. tostring(left) .. " out=" .. o)

-- 2
local B = W .. "/b"; fs.mkdir(B)
rc = scaffold(B, { "--name", "My API", "--summary", "s", "--deploy", "gcp-buildpacks", "--runtime", "python", "--port", "9000", "--no-specs" })
arm("2 gcp-buildpacks renders project.toml (python) and service.yaml (port 9000), no Dockerfile",
    rc == 0 and has(B .. "/project.toml", '\nvalue = "python"\n') and has(B .. "/service.yaml", "containerPort: 9000")
    and not fs.exists(B .. "/Dockerfile") and not placeholders_left(B), "rc=" .. tostring(rc))

-- 3
local C = W .. "/c"; fs.mkdir(C); fs.write(C .. "/package.json", '{"name":"c"}\n')
scaffold(C, { "--name", "C", "--summary", "s", "--deploy", "gcp-dockerfile", "--no-specs" })
arm("3 a package.json makes the runtime node, run as the image's non-root user",
    has(C .. "/Dockerfile", "\nFROM docker.io/library/node:") and has(C .. "/Dockerfile", "\nUSER node\n"),
    fs.exists(C .. "/Dockerfile") and fs.read(C .. "/Dockerfile"):match("FROM[^\n]*") or "no Dockerfile")

-- 4
local D = W .. "/d"; fs.mkdir(D)
rc, o = scaffold(D, { "--name", "D", "--summary", "s", "--stack", "flutter", "--deploy", "gcp-buildpacks" })
local dfiles = fs.list(D) or {}
arm("4 buildpacks for a Flutter web app exits 3, names the Dockerfile option, creates nothing",
    rc == 3 and #dfiles == 0 and o:find("gcp-dockerfile", 1, true) ~= nil,
    "rc=" .. tostring(rc) .. " files=" .. table.concat(dfiles, " "))

-- 5
local E = W .. "/e"; fs.mkdir(E)
local MINE = "FROM scratch\n"
fs.write(E .. "/Dockerfile", MINE)
scaffold(E, { "--name", "E", "--summary", "s", "--deploy", "gcp-dockerfile", "--runtime", "go", "--no-specs" })
local _, o2 = scaffold(E, { "--name", "E", "--summary", "s", "--deploy", "gcp-dockerfile", "--runtime", "go", "--no-specs" })
arm("5 the user's own Dockerfile is kept and a second run creates nothing",
    fs.read(E .. "/Dockerfile") == MINE and has_line(text.trim(o2), "ok:scaffold:0") and fs.exists(E .. "/service.yaml"), o2)

-- 6
local calls_gcloud = false
for line in ((fs.read(S) or "") .. "\n"):gmatch("([^\n]*)\n") do
    local code = line:match("^([^#]*)") or ""
    if code:find("%f[%w]gcloud%f[^%w]") then calls_gcloud = true end
end
arm("6 the skill and its note state the billing requirement; the scaffold runs no gcloud",
    has(SKILL .. "/SKILL.md", "needs a billing account") and has(SKILL .. "/deploy-google-cloud.md", "needs a billing account")
    and not calls_gcloud, "calls_gcloud=" .. tostring(calls_gcloud))

proc.run({ argv = { "rm", "-rf", W }, timeout_ms = 30000 })
if #failed > 0 then
    verdict.emit("violation:start-a-new-project-gcp:" .. #failed .. "-failed", 1)
end
verdict.ok("start-a-new-project-gcp", "6 arms")
