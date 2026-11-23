-- @env PATH HOME XDG_RUNTIME_DIR
-- @trace spec:inference-container, spec:enclave-network
--
-- test-inference.lua — diagnostic: launch the inference container in
-- isolation, wait for its health check, and probe /api/version inside it.
-- Ported from scripts/test-inference.sh (order 2238-gpxz pays the carried
-- shell-to-lua item); same container, flags, mounts and probe.
--
-- Model cache: DELIBERATELY the real user cache, not a tempdir (order 438).
-- The cache holds multi-GB model blobs, so redirecting it would force a full
-- re-download on every run and the test would stop being run at all. A
-- simultaneous app run touching the same cache can race this test; accepted
-- because ollama's blob store is content-addressed and read-mostly.
--
-- Usage: tillandsias-plan script run scripts/lua/test-inference.lua [-- <image>]
-- Verdict: ok:inference-diagnostic:healthy | blocked:inference-diagnostic:<why>
--          | could-not-run:inference-diagnostic:no-podman

local NAME = "tillandsias-diagnostic-inference"
local function podman(args, ms)
    local argv = { "podman" }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    return proc.run({ argv = argv, timeout_ms = ms or 60000,
        env = { PATH = env.get("PATH"), HOME = env.get("HOME"), XDG_RUNTIME_DIR = env.get("XDG_RUNTIME_DIR") } })
end
local function cleanup() podman({ "rm", "-f", NAME }, 60000) end
local function tail_logs()
    local r = podman({ "logs", NAME }, 30000)
    local ls = text.lines((r.stdout or "") .. (r.stderr or ""))
    for i = math.max(1, #ls - 29), #ls do out.line(ls[i]) end
end
local function fail(why)
    tail_logs()
    cleanup()
    verdict.emit("blocked:inference-diagnostic:" .. why, 1)
end

if podman({ "--version" }, 15000).code ~= 0 then
    verdict.emit("could-not-run:inference-diagnostic:no-podman", 3)
end

local version = text.trim(fs.read("VERSION") or "")
local image = arg[1]
if image == nil or image == "" then image = "tillandsias-inference:v" .. version end
local cache = env.get("HOME") .. "/.cache/tillandsias/models"

out.line("[diagnostic] Starting inference container isolation test...")
out.line("[diagnostic] Image: " .. image)
out.line("[diagnostic] Container: " .. NAME)
cleanup()
proc.run({ argv = { "mkdir", "-p", cache }, timeout_ms = 10000 })

out.line("[diagnostic] Launching container with model cache at: " .. cache)
local r = podman({ "run", "--detach", "--name", NAME, "--hostname", "inference",
    "--cap-drop=ALL", "--security-opt=no-new-privileges", "--userns=keep-id",
    "--env", "OLLAMA_DEBUG=1",
    "-v", cache .. ":/home/ollama/.ollama/models:rw",
    image, "/usr/bin/ollama", "serve" }, 120000)
if r.code ~= 0 then
    out.line("[diagnostic] ERROR: failed to start inference container: " .. text.trim((r.stderr or "") .. (r.stdout or "")))
    cleanup()
    verdict.emit("blocked:inference-diagnostic:start-failed", 1)
end

out.line("[diagnostic] Waiting for container health...")
if podman({ "wait", "--condition=healthy", NAME }, 300000).code ~= 0 then
    out.line("[diagnostic] ERROR: inference container failed health check")
    fail("unhealthy")
end

out.line("[diagnostic] Verifying /api/version inside the container...")
if podman({ "exec", NAME, "sh", "-lc", "curl -fsS http://127.0.0.1:11434/api/version >/dev/null" }, 60000).code ~= 0 then
    out.line("[diagnostic] ERROR: inference API probe failed")
    fail("api-probe-failed")
end

out.line("[diagnostic] Inference container is healthy and serving /api/version")
cleanup()
verdict.emit("ok:inference-diagnostic:healthy", 0)
