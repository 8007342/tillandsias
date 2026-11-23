-- @env PATH HOME XDG_RUNTIME_DIR TEST_ROOT TILLANDSIAS_FORGE_IMAGE
-- @read-env TEST_ROOT TILLANDSIAS_FORGE_IMAGE
-- @trace spec:podman-idiomatic-patterns
--
-- litmus-helper-storage-isolation.lua — PORTED from
-- litmus-helper-storage-isolation.sh (2111-y8ch, lenovinha shell slice).
-- Two project containers: /src read-only, /workspace read-write and private
-- to its project, /tmp a tmpfs that a relaunch finds empty.
--
-- Faithful port (coordinator ruling 2026-11-19), with two changes the port
-- cannot avoid or that the .sh never actually ran past:
--   * TEST_ROOT defaulted to /tmp/tillandsias-litmus-storage-$$, a different
--     directory in every litmus step (each is its own process). create-dirs now
--     mints the root once and records it in target/litmus-scratch; later steps
--     read it. TEST_ROOT still overrides.
--   * the forge image grep ^tillandsias-forge: never matched podman's
--     localhost/tillandsias-forge:<tag> names, so the .sh died under pipefail
--     before printing anything; both spellings are accepted.
-- Every token, stdout/stderr split and exit code is otherwise the .sh's.
--
-- Usage: tillandsias-plan script run scripts/lua/litmus-helper-storage-isolation.lua -- <mode>

local SCRATCH = "target/litmus-scratch"
local STATE = SCRATCH .. "/storage-isolation.state"
local LABEL = "tillandsias-litmus-storage-test"

local function penv()
    return { PATH = env.get("PATH") or "", HOME = env.get("HOME") or "",
        XDG_RUNTIME_DIR = env.get("XDG_RUNTIME_DIR") }
end
local function run(argv, timeout_ms)
    return proc.run{ argv = argv, env = penv(), timeout_ms = timeout_ms or 60000 }
end
local function podman(args, timeout_ms)
    local argv = { "podman" }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    return run(argv, timeout_ms)
end
local function pause(sec) run({ "sleep", sec }, 30000) end
local function ok_exit(r) return r.status == "exited" and r.code == 0 end
local function first_line(s) local l = text.lines(s or ""); return l[1] or "" end
local function done(token) out.line(token); verdict.emit("ok:storage-isolation", 0) end
local function quiet_ok() verdict.emit("ok:storage-isolation:no-token", 0) end
local function err_fail(lines)
    for _, l in ipairs(lines) do log.raw(l) end
    verdict.emit("violation:storage-isolation", 1)
end

local function test_root(mint)
    local e = env.get("TEST_ROOT")
    if e and e ~= "" then return e end
    if fs.exists(STATE) then
        local r = (fs.read(STATE) or ""):match("root=([^\n]+)")
        if r then return r end
    end
    if not mint then return nil end
    fs.mkdir(SCRATCH)
    local id = time.iso_utc():gsub("[^%w]", "") .. "-" .. math.random(100000, 999999)
    local root = "/tmp/tillandsias-litmus-storage-" .. id
    fs.write(STATE, "root=" .. root .. "\n")
    return root
end

local function need_root()
    local r = test_root(false)
    if not r then
        out.line("FAIL: no storage-isolation run state at " .. STATE .. " (create-dirs has not run)")
        verdict.emit("could-not-run:storage-isolation:no-run-state", 1)
    end
    return r
end

local function forge_image()
    local img = env.get("TILLANDSIAS_FORGE_IMAGE")
    if img and img ~= "" then return img end
    for _, l in ipairs(text.lines(podman({ "images", "--format", "{{.Repository}}:{{.Tag}}" }).stdout or "")) do
        if l:sub(1, 18) == "tillandsias-forge:" or l:sub(1, 28) == "localhost/tillandsias-forge:" then return l end
    end
    return "docker.io/library/alpine:3.20"
end

local function launch(root, project, label_value)
    local r = podman({ "run", "-d", "--rm", "--label", LABEL .. "=" .. label_value,
        "--volume", root .. "/" .. project .. "/src:/src:ro",
        "--volume", root .. "/" .. project .. "/workspace:/workspace:rw",
        "--tmpfs", "/tmp:rw", forge_image(), "sleep", "120" }, 120000)
    return first_line((r.stdout or "") .. (r.stderr or ""))
end

local function running(project)
    return text.trim(first_line(podman({ "ps", "-q", "-f", "label=" .. LABEL .. "=" .. project }).stdout))
end

local function exec(cid, script)
    return podman({ "exec", cid, "bash", "-c", script })
end

local mode = arg[1] or "help"

if mode == "check-image" then
    local img = forge_image()
    out.line("FORGE_IMAGE=" .. img)
    if ok_exit(podman({ "inspect", img })) then done("FORGE_IMAGE_OK") end
    verdict.emit("violation:storage-isolation:no-image", 1)

elseif mode == "create-dirs" then
    local root = test_root(true)
    for _, p in ipairs({ "project-a", "project-b" }) do
        run({ "mkdir", "-p", root .. "/" .. p .. "/src", root .. "/" .. p .. "/workspace" })
    end
    -- fs.write is confined to the checkout; the root lives in /tmp as before,
    -- so the markers go through tee.
    local function marker(p)
        local r = proc.run{ argv = { "tee", root .. "/" .. p .. "/workspace/marker.txt" },
            stdin = p .. "-marker\n", env = penv(), timeout_ms = 5000 }
        return ok_exit(r)
    end
    marker("project-a"); marker("project-b")
    out.line("TEST_ROOT=" .. root)
    out.line(text.trim(run({ "ls", "-la", root }).stdout or ""))
    done("TEST_DIRS_CREATED")

elseif mode == "launch-project-a" or mode == "launch-project-b" then
    local root = need_root()
    local p = mode:sub(8)
    local cid = launch(root, p, p)
    local up = p == "project-a" and "A" or "B"
    out.line("CONTAINER_" .. up .. "=" .. cid)
    if cid ~= "" then done("PROJECT_" .. up .. "_LAUNCHED") end
    verdict.emit("violation:storage-isolation:launch", 1)

elseif mode == "verify-src-readonly" then
    -- severity:critical SECURITY CHECK: the token is emitted ONLY on the
    -- verified path, and both failure modes exit non-zero (calmecacpilli audit).
    local cid = running("project-a")
    if cid == "" then
        err_fail({ "FAIL: project-a container is not running; /src read-only was NOT verified" })
    end
    local r = exec(cid, "touch /src/test.txt 2>&1")
    local o = (r.stdout or "") .. (r.stderr or "")
    if o:find("Read-only file system", 1, true) or o:find("Permission denied", 1, true)
        or o:find("cannot touch", 1, true) then
        out.line("Read-only mount verified for /src in project-a")
        done("SRC_READONLY_VERIFIED")
    end
    local shown = text.trim(o) ~= "" and text.trim(o) or "<no output, i.e. the write SUCCEEDED>"
    err_fail({ "FAIL: /src ACCEPTED A WRITE — the :ro mount is not in effect.",
        "      touch reported: " .. shown })

elseif mode == "verify-workspace-rw" then
    local cid = running("project-a")
    if cid ~= "" and ok_exit(exec(cid, 'echo "project-a-test-file" > /workspace/test-a.txt')) then
        local r = podman({ "exec", cid, "cat", "/workspace/test-a.txt" })
        if (r.stdout or ""):find("project-a-test-file", 1, true) then done("WORKSPACE_RW_VERIFIED") end
        verdict.emit("violation:storage-isolation:workspace-rw", 1)
    end
    quiet_ok()

elseif mode == "verify-workspace-isolation" then
    local cid = running("project-b")
    if cid ~= "" then
        local o = text.trim((exec(cid, 'ls /workspace/test-a.txt 2>&1 || echo "file not found"').stdout or ""))
        if o:find("not found", 1, true) or o:find("No such file", 1, true) then
            done("WORKSPACE_ISOLATION_VERIFIED")
        end
        out.line("WARNING: Found unexpected file in project-b workspace: " .. o)
    end
    quiet_ok()

elseif mode == "verify-tmp-ephemeral" then
    local cid = running("project-a")
    if cid ~= "" then
        if not ok_exit(exec(cid, 'echo "ephemeral-marker-a" > /tmp/ephemeral.txt')) then
            verdict.emit("violation:storage-isolation:tmp-write", 1)
        end
        local r = podman({ "exec", cid, "cat", "/tmp/ephemeral.txt" })
        if (r.stdout or ""):find("ephemeral-marker-a", 1, true) then out.line("Ephemeral file written") end
        podman({ "stop", cid }, 60000)
        pause("1")
        done("TMP_EPHEMERAL_VERIFIED")
    end
    quiet_ok()

elseif mode == "verify-tmp-clean-relaunch" then
    local root = need_root()
    local cid = launch(root, "project-a", "project-a-relaunch")
    if cid ~= "" then
        local n = tonumber(text.trim(exec(cid, "ls /tmp/ 2>/dev/null | wc -l").stdout or "")) or -1
        if n == 0 or n == 1 then
            out.line("TMP_EPHEMERAL_CONFIRMED")
        else
            out.line("WARNING: /tmp not empty, has " .. n .. " items")
        end
        podman({ "stop", cid }, 60000)
    end
    quiet_ok()

elseif mode == "verify-workspace-persistence" then
    local root = need_root()
    local r = run({ "cat", root .. "/project-a/workspace/test-a.txt" })
    if ok_exit(r) and (r.stdout or ""):find("project-a-test-file", 1, true) then
        done("WORKSPACE_PERSISTENCE_VERIFIED")
    end
    quiet_ok()

elseif mode == "cleanup" then
    local ids = text.lines(podman({ "ps", "-a", "-q", "-f", "label=" .. LABEL }).stdout or "")
    if #ids > 0 then
        local args = { "rm", "-f" }
        for _, id in ipairs(ids) do args[#args + 1] = text.trim(id) end
        podman(args, 60000)
    end
    local root = test_root(false)
    if root and root:match("^/tmp/tillandsias%-litmus%-storage%-") then
        run({ "find", root, "-delete" })
    end
    run({ "find", STATE, "-maxdepth", "0", "-type", "f", "-delete" }, 5000)
    done("CLEANUP_COMPLETE")

else
    out.line("Usage: litmus-helper-storage-isolation.lua -- {check-image|create-dirs|launch-project-a|"
        .. "launch-project-b|verify-src-readonly|verify-workspace-rw|verify-workspace-isolation|"
        .. "verify-tmp-ephemeral|verify-tmp-clean-relaunch|verify-workspace-persistence|cleanup}")
    verdict.emit("could-not-run:storage-isolation:usage", 2)
end
