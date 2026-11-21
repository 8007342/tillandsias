-- @trace order:1356-u6xe, spec:git-mirror-service, order:2168-dqph
-- @env PATH HOME XDG_RUNTIME_DIR
--
-- test-bare-metal-lane-command-is-runnable.lua — the substrate checker's
-- mirror todo: line prints a command a worker COPIES AND RUNS; it must be the
-- cloud form `tillandsias --cloud <owner>/<repo> --bash` (776-jcf3 retired path
-- launches; 1356-u6xe was the bare project name the binary refused). Ported from
-- the .sh of the same name (order 2168-dqph); same verdicts.
--
-- It asserts the SHAPE of the printed command, never the binary's behaviour: it
-- runs no lane and starts no container.
--
-- Usage: tillandsias-plan script run scripts/lua/test-bare-metal-lane-command-is-runnable.lua
-- Verdicts:
--   ok:bare-metal-lane-command-is-runnable:cloud=<owner>/<repo>      exit 0
--   skip:bare-metal-lane-command:no-podman | :enclave-down           exit 0
--   violation:bare-metal-lane-command:<why>                          exit 1

local CHECKER = "scripts/check-bare-metal-host-initialized.sh"
local function bad(why) verdict.emit("violation:bare-metal-lane-command:" .. why, 1) end

local x = proc.run({ argv = { "test", "-x", CHECKER }, timeout_ms = 10000 })
if x.code ~= 0 then bad("checker-not-executable:" .. CHECKER) end

-- Name a project no container serves: the ONLY branch that prints the lane
-- command, and it prints it without touching anything.
local r = proc.run({ argv = { "bash", CHECKER }, timeout_ms = 120000, env = {
    PATH = env.get("PATH"), HOME = env.get("HOME"), XDG_RUNTIME_DIR = env.get("XDG_RUNTIME_DIR"),
    TILLANDSIAS_PROJECT = "definitely-no-such-project-1356u6xe" } })
local line = text.lines(r.stdout or "")[1] or ""

local MIRROR = "todo:initialize-bare-metal-host:mirror:"
if line == "skip:bare-metal-host:no-podman" then verdict.emit("skip:bare-metal-lane-command:no-podman", 0) end
if text.starts_with(line, "todo:initialize-bare-metal-host:vault:")
    or text.starts_with(line, "todo:initialize-bare-metal-host:proxy:") then
    -- The enclave is down, so the run never reaches the mirror probe: a
    -- substrate state, not a failure of this property.
    verdict.emit("skip:bare-metal-lane-command:enclave-down", 0)
end
if not text.starts_with(line, MIRROR) then bad("unexpected-verdict:" .. (line ~= "" and line or "<empty>")) end

local cmd = line:sub(#MIRROR + 1)
if text.contains(cmd, "TILLANDSIAS_HOST_PROJECT_ROOT") then bad("names-retired-project-root:" .. cmd) end
local nwo = cmd:match("^tillandsias %-%-cloud (.*) %-%-bash$")
if not nwo then bad("not-the-cloud-lane-form:" .. cmd) end
if not text.contains(nwo, "/") then bad("cloud-argument-is-not-owner-repo:" .. nwo) end
if nwo:sub(1, 1) == "/" or nwo:match("/.*/") or text.contains(nwo, " ") then bad("cloud-argument-is-a-path:" .. nwo) end
verdict.emit("ok:bare-metal-lane-command-is-runnable:cloud=" .. nwo, 0)
