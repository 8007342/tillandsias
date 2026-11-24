-- @env PATH HOME XDG_RUNTIME_DIR
-- @trace order:1765-q7rg, spec:ci-release
--
-- A GATE STEP THAT DECLARES STEP_HOST_STATE GETS ONE RETRY, AND ONLY ONE.
--
-- credential-cold-state-probe (900-z3kv, keyring) and door-index-lock-sweep
-- (1650-fb7z, load) can disagree with themselves on a healthy tree. build.sh's
-- step runner re-runs a declared host-state step once after a settle: a pass
-- then is a pass. A retry that FAILS is a red that reproduced, and is named
-- red-twice:, never flaky: (#1441 was requeued as `flaky:...:ok:,ok:` on a
-- deterministic "8 passed, 1 failed", a gate wasted each time). A retry that
-- could not run (exit 3, 2251-iyiu) gave no verdict and stays flaky:.
--
-- Every arm EXECUTES the real loop through `./build.sh --gate-steps <root>`
-- (1384-bqhy) over a scratch root whose stub counts its own runs:
--   1 FLAKE-ONCE  red then green: the gate passes, two runs, no flaky: line
--   2 RED-TWICE   red twice: red, two runs, red-twice:<step>:<v1>,<v2>, no flaky:
--   3 NO-FIELD    red-then-green WITHOUT the field: red after ONE run (control)
--   4 GREEN       a host-state step that passes runs once
--   5 OK-THEN-RED prints ok: lines, then "8 passed, 1 failed", exit 1, twice:
--                 red-twice: carrying rc=1, never flaky: and never an ok: token
--   6 CNR-TWICE   exits 3 twice: flaky:, never red-twice: (2251-iyiu kept)
--   7 CNR-RED     exits 3, then red: the retry's red is the verdict
--
-- Usage: tillandsias-plan script run scripts/lua/test-gate-step-host-state-retry.lua
-- Verdict: ok:gate-step-host-state-retry:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("gate-step-host-state-retry")
local ROOT, SH = fixture.repo_root(), fixture.posix_shell()

-- On MSYS build.sh re-execs into the tillandsias-build distro, which cannot see
-- this scratch root; the gate runs this step inside that distro.
local uname = text.trim(proc.run{ argv = { "uname", "-s" } }.stdout or "")
if uname ~= "Linux" and uname ~= "Darwin" then
    T:skip(uname .. "-re-execs-build-sh-into-wsl")
end

local VIOLATION = 'if [ "$n" -le %d ]; then echo "violation:stub-hs:run-$n"; exit 1; fi'
local function gate(tag, body, host_state)
    local d = T:scratch(tag)
    fs.mkdir(d.rel .. "/scripts/gate-steps.d")
    fs.write(d.rel .. "/runs.log", "")
    fs.write(d.rel .. "/scripts/stub-hs.sh", table.concat({
        "#!/usr/bin/env bash",
        'echo run >> "' .. d.abs .. '/runs.log"',
        'n="$(wc -l < "' .. d.abs .. '/runs.log" | tr -d \' \')"', -- BSD wc pads
        body, 'echo "ok:stub-hs:run-$n"', "" }, "\n"))
    local step = {
        'STEP_DESC="Stub host-state step (1765-q7rg fixture)"',
        'STEP_SCRIPT="scripts/stub-hs.sh"',
        'STEP_ERROR="stub host-state step failed"',
        'STEP_OK="Stub host-state step passed"',
    }
    if host_state then step[#step + 1] = 'STEP_HOST_STATE="' .. host_state .. '"' end
    fs.write(d.rel .. "/scripts/gate-steps.d/500-stub.step", table.concat(step, "\n") .. "\n")
    local g = proc.run{ argv = { SH, ROOT .. "/build.sh", "--gate-steps", d.abs }, cwd = ROOT, timeout_ms = 600000,
        env = { PATH = env.get("PATH"), HOME = env.get("HOME"), XDG_RUNTIME_DIR = env.get("XDG_RUNTIME_DIR"),
                TILLANDSIAS_GATE_HOST_STATE_SETTLE_S = "0" } }
    local o = (g.stdout or "") .. (g.stderr or "")
    local runs, flaky, red = 0, nil, nil
    for _, l in ipairs(text.lines(fs.read(d.rel .. "/runs.log"))) do if l == "run" then runs = runs + 1 end end
    for _, l in ipairs(text.lines(o)) do
        if text.starts_with(l, "flaky:") then flaky = l end
        if text.starts_with(l, "red-twice:") then red = l end
    end
    return { code = g.code, runs = runs, flaky = flaky, red = red, o = o,
        got = "rc=" .. tostring(g.code) .. " runs=" .. runs .. " flaky=" .. tostring(flaky) .. " red=" .. tostring(red) .. "\n" .. o }
end

local r = gate("once", VIOLATION:format(1), "keyring")
T:arm("1 FLAKE-ONCE red then green passes after exactly one retry", r.code == 0 and r.runs == 2 and not r.flaky and not r.red, r.got)

r = gate("twice", VIOLATION:format(9), "load")
T:arm("2 RED-TWICE a red that reproduces is red-twice:, never flaky:",
    r.code ~= 0 and r.runs == 2 and not r.flaky and r.red == "red-twice:stub-hs.sh:violation:stub-hs:run-1,violation:stub-hs:run-2"
    and text.contains(r.o, "stub host-state step failed"), r.got)

r = gate("nofield", VIOLATION:format(1), nil)
T:arm("3 NO-FIELD a step that declares no host state is red after one run",
    r.code ~= 0 and r.runs == 1 and not r.flaky and not r.red and not text.contains(r.o, "retry:stub-hs"), r.got)

r = gate("green", VIOLATION:format(0), "keyring")
T:arm("4 GREEN a host-state step that passes runs once", r.code == 0 and r.runs == 1, r.got)

r = gate("okred", 'echo "ok: arm 1"; echo "stub: 8 passed, 1 failed"; echo "ok: arm 9"; exit 1', "load")
T:arm("5 OK-THEN-RED a step that prints ok: and fails twice is red-twice: rc=1, not flaky: ok:,ok:",
    r.code ~= 0 and r.runs == 2 and not r.flaky and r.red == "red-twice:stub-hs.sh:rc=1,rc=1", r.got)

r = gate("cnr", 'echo "stub: 8 passed, 0 failed, 1 could-not-run"; exit 3', "load")
T:arm("6 CNR-TWICE a retry that could not run gave no verdict: flaky:",
    r.code ~= 0 and r.runs == 2 and not r.red and r.flaky == "flaky:stub-hs.sh:rc=3,rc=3", r.got)

r = gate("cnrred", 'if [ "$n" -eq 1 ]; then exit 3; fi; echo "violation:stub-hs:run-$n"; exit 1', "load")
T:arm("7 CNR-RED could-not-run then red: the retry's red is the verdict",
    r.code ~= 0 and r.runs == 2 and not r.flaky and r.red == "red-twice:stub-hs.sh:rc=3,violation:stub-hs:run-2", r.got)
T:finish()
