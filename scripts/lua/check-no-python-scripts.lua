-- @trace order:1087-h2z9, order:1630-dwab
-- @env CARGO_TARGET_DIR
-- preflight: serial — cargo-builds the tillandsias-policy binary into the shared target/ that other guards execute
--
-- check-no-python-scripts.lua — no Python runtime in scripts/ or the harness
-- files. The question is the tillandsias-policy binary's
-- (`tillandsias-policy check-no-python-scripts`); this decider builds that
-- binary and asks it. Ported from scripts/check-no-python-scripts.sh (the
-- shell-to-lua carried obligation paid by 1630-dwab). The exit code is
-- unchanged, and every caller judges by it.
--
-- REDIRECTED TARGET DIRS (litmus:forge-policy-binary-discoverability). proc.run
-- children start from a scrubbed environment, so CARGO_TARGET_DIR is passed to
-- cargo as --target-dir and to the probe explicitly. Without that, cargo builds
-- into the checkout's target/ while the probe looks in the redirected dir.
--
-- RUN-DON'T-STAT (order 770-ifeg). On a shared Windows/WSL checkout the
-- extensionless target/ path can hold the OTHER platform's artifact, and an
-- existence check execs it into "Exec format error". So the binary is found
-- by scripts/plan-binary-probe.sh's resolve_target_binary, the one probe,
-- which returns a candidate only when it executes.
--
-- GRAMMAR (the binary's own lines are relayed above the verdict)
--   ok:no-python-scripts                                                 exit 0
--   violation:no-python-scripts:<rc>                                     exit <rc>
--   could-not-run:no-python-scripts:build-failed                         exit 3
--   refused:no-runnable-tillandsias-policy                               exit 1
--
-- Usage: tillandsias-plan script run scripts/lua/check-no-python-scripts.lua

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.status ~= "exited" or top.code ~= 0 or ROOT == "" then
    verdict.could_not_run("no-python-scripts", "git rev-parse --show-toplevel did not answer")
end
local target_dir = env.get("CARGO_TARGET_DIR") or ""

local argv = { "cargo", "build", "--quiet", "-p", "tillandsias-policy" }
if target_dir ~= "" then
    argv[#argv + 1] = "--target-dir"
    argv[#argv + 1] = target_dir
end
local b = proc.run({ argv = argv, cwd = ROOT, timeout_ms = 1800000 })
if b.status ~= "exited" or b.code ~= 0 then
    for _, l in ipairs(text.lines((b.stderr or "") .. "\n" .. (b.stdout or ""))) do
        if text.is_match(l, "^error|^  --> |could not compile") then log.raw(l) end
    end
    verdict.emit("could-not-run:no-python-scripts:build-failed", 3,
        "cargo build -p tillandsias-policy did not succeed, so the question was never asked")
end

local penv = {}
if target_dir ~= "" then penv.CARGO_TARGET_DIR = target_dir end
local probe = proc.run({ argv = { "bash", "-s" }, cwd = ROOT, env = penv, timeout_ms = 60000,
    stdin = '. scripts/plan-binary-probe.sh\nresolve_target_binary tillandsias-policy debug "$PWD"\n' })
local bin = text.trim(probe.stdout or "")
if probe.status ~= "exited" or probe.code ~= 0 or bin == "" then
    verdict.emit("refused:no-runnable-tillandsias-policy", 1,
        "probed target/debug and CARGO_TARGET_DIR by execution and nothing ran")
end

local r = proc.run({ argv = { bin, "check-no-python-scripts" }, cwd = ROOT, timeout_ms = 300000 })
for _, l in ipairs(text.lines(r.stdout or "")) do if l ~= "" then out.line(l) end end
for _, l in ipairs(text.lines(r.stderr or "")) do if l ~= "" then log.raw(l) end end
if r.status == "exited" and r.code == 0 then
    verdict.emit("ok:no-python-scripts", 0)
end
local rc = (r.status == "exited" and r.code ~= 0) and r.code or 1
verdict.emit("violation:no-python-scripts:" .. tostring(rc), rc)
