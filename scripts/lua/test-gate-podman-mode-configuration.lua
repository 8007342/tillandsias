-- @trace spec:podman-orchestration, spec:dev-build, plan 797-r6tc, order:1576-luas
-- @env PATH
--
-- test-gate-podman-mode-configuration.lua — PORTED from
-- test-gate-podman-mode-configuration.sh by 1576-luas, which added the one
-- primitive the .sh needed an interpreter for: fs.listen_unix. It proves the
-- gate does not GUESS which podman it is testing.
--
-- WHY THIS EXISTS. build.sh used to export TILLANDSIAS_PODMAN_REMOTE_URL
-- whenever ${XDG_RUNTIME_DIR}/podman/podman.sock existed. A socket file
-- existing is the ordinary state of any host with podman.socket enabled, so the
-- inference fired unconditionally, and only inside the gate. Sourcing
-- scripts/common.sh with that variable set takes its remote branch, which pins
-- an exported TILLANDSIAS_PODMAN_BIN at a generated wrapper; that pin beats
-- PATH in resolve_podman_bin() and it is inherited by every litmus child, so
-- `backend: fake` tests that inject their podman by PATH silently ran against
-- real podman. Measured on macuahuitl 2026-08-17 at one commit: 302/302 from a
-- bare litmus run, 295/302 through ./build.sh --ci-full.
--
-- THE PROPERTY, not the literal: with a REAL AF_UNIX socket sitting exactly
-- where the old inference looked for it, build.sh must still hand common.sh an
-- UNSET remote URL, and must still pass through a URL the caller set itself.
-- Scenario 1 is the discriminating one: restore the inference and it goes red.
--
-- WHAT THE PORT CHANGES, deliberately:
-- * The socket comes from fs.listen_unix, not python3. The .sh's two
--   interpreter skips collapse into one: off Unix the primitive is
--   `unsupported` and this prints the SAME skip line the .sh printed when its
--   runtime had no AF_UNIX. "No interpreter on PATH" can no longer happen.
-- * The sandbox lives under the checkout's target/plan-scratch, because the
--   runtime's write verbs are rooted there (and the litmus fixture scope allows
--   it). An over-long socket path is refused BY NAME by the primitive
--   (sun-path-too-long), the way the .sh's 1428-3kdu guard named it.
-- * Children run under proc.run's cleared environment (PATH, HOME, TMPDIR and
--   every TILLANDSIAS_* pass through); `env -u` drops what each scenario unsets,
--   as the .sh did.
-- * The runtime's verdict grammar has no `PASS:`/`FAIL:` prefix, so the closing
--   line is `ok:gate-podman-mode-configuration:...` (exit 0) or
--   `violation:gate-podman-mode-configuration:...` (exit 1). The .sh's
--   `PASS: …` and `FAIL: …` lines are still printed above it, so a reader
--   matching them (the litmus) sees the same words.
--
-- Pinned by litmus:gate-podman-mode-is-configuration-not-inference.

local function trim(s) return ((s or ""):gsub("%s+$", "")) end

local root = trim(proc.run{ argv = { "pwd", "-P" } }.stdout)
local rel = "target/plan-scratch/tgpm-" .. tostring(time.now_ms())
local sb = root .. "/" .. rel

local function finish(line, code)
    proc.run{ argv = { "rm", "-rf", sb } }
    verdict.emit(line, code)
end

local failed = false
local function ok(m) out.line("  ok: " .. m) end
local function fail(m) out.line("FAIL: " .. m); failed = true end

-- Run argv with extra env; return stdout..stderr, as the .sh's `2>&1`.
local function run(argv, env)
    local r = proc.run{ argv = argv, env = env or {}, timeout_ms = 120000 }
    return (r.stdout or "") .. (r.stderr or "")
end
local function has(hay, needle) return hay:find(needle, 1, true) ~= nil end

-- ---------------------------------------------------------------------------
-- Fixture: a build.sh sandbox whose XDG_RUNTIME_DIR holds a genuine listening
-- unix socket at podman/podman.sock, and whose scripts/common.sh is a stub that
-- reports what build.sh handed it and then stops the script.
-- ---------------------------------------------------------------------------
fs.mkdir(rel .. "/scripts")
fs.mkdir(rel .. "/run/podman")

local sock_ok, sock = pcall(fs.listen_unix, rel .. "/run/podman/podman.sock")
if not sock_ok then
    local err = tostring(sock)
    if has(err, "unsupported") then
        finish("skip:gate-podman-mode:runtime-has-no-af-unix (this runtime cannot create unix sockets, e.g. Windows; nothing was asserted)", 0)
        return
    end
    out.line("FAIL: could not create the AF_UNIX fixture socket: " .. err)
    finish("violation:gate-podman-mode-configuration:no-fixture-socket", 1)
    return
end
if not proc.run{ argv = { "test", "-S", sb .. "/run/podman/podman.sock" } }.ok then
    -- Without a real socket the fixture cannot discriminate: the old inference
    -- tested -S, so a missing socket would make scenario 1 pass for the wrong
    -- reason. Refuse rather than report a green that proves nothing.
    out.line("FAIL: fixture socket is not a socket — the scenario would be vacuous")
    finish("violation:gate-podman-mode-configuration:vacuous-socket", 1)
    return
end

run{ "cp", root .. "/build.sh", sb .. "/build.sh" }
fs.write(rel .. "/scripts/with-tillandsias-builder.sh", "")
fs.write(rel .. "/scripts/with-wsl2-builder.sh", "")
-- 3d56d69b6 added a third sourced wrapper to build.sh; stub it like its siblings.
fs.write(rel .. "/scripts/with-nix-builder.sh", "")
local REPORT = 'echo "handed-remote-url=[${TILLANDSIAS_PODMAN_REMOTE_URL:-<unset>}]"\n'
fs.write(rel .. "/scripts/common.sh",
    REPORT .. 'echo "handed-container-host=[${CONTAINER_HOST:-<unset>}]"\nexit 0\n')

-- ---------------------------------------------------------------------------
-- Scenario 1 — THE REGRESSION. Socket present, caller silent: the gate must
-- still be in local-podman mode.
-- ---------------------------------------------------------------------------
local out1 = run({ "env", "-u", "TILLANDSIAS_PODMAN_REMOTE_URL", "-u", "CONTAINER_HOST",
    "bash", sb .. "/build.sh", "--check" }, { XDG_RUNTIME_DIR = sb .. "/run" })
if has(out1, "handed-remote-url=[<unset>]") then
    ok("socket present + caller silent => no inferred remote mode")
else
    fail("build.sh inferred remote podman mode from a socket file: " .. out1)
end

-- ---------------------------------------------------------------------------
-- Scenario 2 — CONFIGURATION IS STILL HONOURED. The one real consumer of remote
-- mode (packaging/systemd/user/tillandsias.service) sets the variable itself; a
-- caller that does so must reach common.sh with its own value intact.
-- ---------------------------------------------------------------------------
local out2 = run({ "env", "-u", "CONTAINER_HOST", "bash", sb .. "/build.sh", "--check" },
    { TILLANDSIAS_PODMAN_REMOTE_URL = "unix:///caller/chosen/podman.sock",
      XDG_RUNTIME_DIR = sb .. "/run" })
if has(out2, "handed-remote-url=[unix:///caller/chosen/podman.sock]") then
    ok("explicit remote URL survives build.sh unmodified")
else
    fail("build.sh did not pass the caller's remote URL through: " .. out2)
end

-- ORDER 1485-m9m8. Scenarios 3 and 4 source the REAL common.sh, whose mode
-- branches are only reachable when it RESOLVES a podman binary. On a host with
-- no podman, put a stub on PATH so both scenarios test the MODE and not the
-- host's package list. A host that has podman is untouched.
local path = env.get("PATH") or "/usr/bin:/bin"
local function present(p) return proc.run{ argv = { "test", "-x", p } }.ok end
if not proc.run{ argv = { "which", "podman" } }.ok
    and not present("/usr/bin/podman") and not present("/bin/podman")
    and not present("/usr/local/bin/podman") then
    fs.mkdir(rel .. "/fakebin")
    fs.write(rel .. "/fakebin/podman",
        '#!/usr/bin/env bash\n[ "${1:-}" = --version ] && { echo "podman version 5.0.0"; exit 0; }\nexit 0\n')
    run{ "chmod", "+x", sb .. "/fakebin/podman" }
    path = sb .. "/fakebin:" .. path
    out.line("  note: no podman on this host; scenarios 3-4 resolve a stub at " .. sb .. "/fakebin/podman (1485-m9m8)")
end

local PINNED = 'source "' .. root .. '/scripts/common.sh"; echo "pinned-bin=[${TILLANDSIAS_PODMAN_BIN:-<unset>}]"\n'
fs.write(rel .. "/pinned.sh", PINNED)

-- ---------------------------------------------------------------------------
-- Scenario 3 — THE CONSEQUENCE THAT ACTUALLY BROKE THE GATE. Against the REAL
-- scripts/common.sh: local mode must leave TILLANDSIAS_PODMAN_BIN unset, which
-- is what lets a `backend: fake` litmus inject its podman by PATH.
-- ---------------------------------------------------------------------------
local out3 = run({ "env", "-u", "TILLANDSIAS_PODMAN_REMOTE_URL", "-u", "CONTAINER_HOST",
    "-u", "TILLANDSIAS_PODMAN_GRAPHROOT", "-u", "TILLANDSIAS_PODMAN_RUNROOT",
    "-u", "TILLANDSIAS_PODMAN_STORAGE_CONF", "-u", "LITMUS_PODMAN_CALLS_FILE",
    "-u", "TILLANDSIAS_PODMAN_BIN", "bash", sb .. "/pinned.sh" }, { PATH = path })
if has(out3, "pinned-bin=[<unset>]") then
    ok("local mode leaves TILLANDSIAS_PODMAN_BIN unset (PATH injection works)")
else
    fail("local mode pinned a podman binary, which overrides fake-podman PATH injection: " .. out3)
end

-- ---------------------------------------------------------------------------
-- Scenario 4 — POSITIVE CONTROL for scenario 3. An explicit remote URL must
-- still produce the pinned wrapper; scenario 3 must be proving a mode, not
-- proving the pin was deleted everywhere.
-- ---------------------------------------------------------------------------
local wrapper_dir = sb .. "/wrapper"
local out4 = run({ "env", "-u", "CONTAINER_HOST", "-u", "LITMUS_PODMAN_CALLS_FILE",
    "-u", "TILLANDSIAS_PODMAN_BIN", "bash", sb .. "/pinned.sh" },
    { PATH = path,
      TILLANDSIAS_PODMAN_REMOTE_URL = "unix://" .. sb .. "/run/podman/podman.sock",
      TILLANDSIAS_PODMAN_WRAPPER_DIR = wrapper_dir })
if has(out4, "pinned-bin=[" .. wrapper_dir .. "/podman]") then
    ok("explicit remote mode still pins the generated wrapper")
else
    fail("explicit remote mode no longer reaches the wrapper branch: " .. out4)
end

-- ---------------------------------------------------------------------------
-- Scenarios 5-7 — ORDER 798-rvqb: the three launchers OFF the gate path that
-- inferred remote mode the same way. Each runs from a sandbox copy whose next
-- hop is a stub that reports what it was handed.
-- ---------------------------------------------------------------------------
local L = sb .. "/launchers"
fs.mkdir(rel .. "/launchers/scripts")
fs.mkdir(rel .. "/launchers/bin")
fs.write(rel .. "/launchers/scripts/common.sh", REPORT .. "exit 0\n")
fs.write(rel .. "/launchers/scripts/build-image.sh", REPORT .. "exit 0\n")
fs.write(rel .. "/launchers/scripts/launch-chromium.sh", REPORT .. "exit 0\n")
-- A podman that answers `--remote --url … info`: build-forge.sh's old inference
-- probed reachability first, so without this the scenario would pass pre-fix
-- for the wrong reason (the fake socket answers nothing).
fs.write(rel .. "/launchers/bin/podman", "#!/bin/sh\nexit 0\n")
run{ "chmod", "+x", L .. "/scripts/build-image.sh", L .. "/scripts/launch-chromium.sh", L .. "/bin/podman" }
run{ "cp", root .. "/build-forge.sh", root .. "/run-forge-standalone.sh", L .. "/" }
run{ "cp", root .. "/scripts/run-safe-browser.sh", L .. "/scripts/" }

local launch_env = { PATH = L .. "/bin:" .. path, XDG_RUNTIME_DIR = sb .. "/run" }
local function launch(script, ...) -- caller silent, real socket present
    return run({ "env", "-u", "TILLANDSIAS_PODMAN_REMOTE_URL", "-u", "CONTAINER_HOST",
        "bash", script, ... }, launch_env)
end
local out5 = launch(L .. "/build-forge.sh")
local out5b = run({ "env", "-u", "CONTAINER_HOST", "bash", L .. "/build-forge.sh" },
    { PATH = L .. "/bin:" .. path, XDG_RUNTIME_DIR = sb .. "/run",
      TILLANDSIAS_PODMAN_REMOTE_URL = "unix:///caller/chosen/podman.sock" })
if has(out5, "handed-remote-url=[<unset>]")
    and has(out5b, "handed-remote-url=[unix:///caller/chosen/podman.sock]") then
    ok("build-forge.sh: socket present + reachable, caller silent => no inferred remote mode; a caller's URL survives")
else
    fail("build-forge.sh inferred remote mode or dropped the caller's URL: [" .. out5 .. "] [" .. out5b .. "]")
end
local out6 = launch(L .. "/run-forge-standalone.sh")
if has(out6, "handed-remote-url=[<unset>]") then
    ok("run-forge-standalone.sh: socket present, caller silent => no inferred remote mode")
else
    fail("run-forge-standalone.sh inferred remote podman mode from a socket file: " .. out6)
end
-- run-safe-browser.sh looked at the HARDCODED /run/user/1000, so this arm only
-- discriminates on a host where that socket exists; it says which it was.
local out7 = launch(L .. "/scripts/run-safe-browser.sh", "--url", "example.invalid")
if has(out7, "handed-remote-url=[<unset>]") then
    if proc.run{ argv = { "test", "-S", "/run/user/1000/podman/podman.sock" } }.ok then
        ok("run-safe-browser.sh: /run/user/1000 socket present, caller silent => no inferred remote mode")
    else
        ok("run-safe-browser.sh: no inferred remote mode (NOT discriminating here: no /run/user/1000 socket on this host)")
    end
else
    fail("run-safe-browser.sh inferred remote podman mode from a socket file: " .. out7)
end

sock:close()
if failed then
    out.line("FAIL: gate podman mode is not configuration-only")
    finish("violation:gate-podman-mode-configuration:not-configuration-only", 1)
    return
end
out.line("PASS: gate podman mode is configuration, not inference (797-r6tc)")
finish("ok:gate-podman-mode-configuration:7 scenarios", 0)
