-- @env PATH HOME XDG_RUNTIME_DIR
-- @trace order:2253-iher
--
-- test-gate-keep-going.lua — `./build.sh --gate-steps <root> --keep-going`
-- names EVERY refusing step and still fails, while the default stays
-- fail-fast. Real build.sh step loop over scratch roots (each root's
-- scripts/gate-steps.d is the only thing its steps read). build.sh still runs
-- its preamble, so HOME and XDG_RUNTIME_DIR are passed: without them podman
-- cannot see the builder toolbox from a Silverblue host shell (2250-974k).
--
--   1 FAIL-FAST  default: steps a(red) b(green) c(red) -> rc 1, a is named,
--                c never runs (fail-fast unchanged)
--   2 ALL REDS   --keep-going: rc 1, red-steps:2, red-step lines name a AND c,
--                b still ran green between them
--   3 POOL       the same under TILLANDSIAS_GATE_STEP_JOBS=3 (workers record
--                through the shared file): red-steps:2 naming a and c
--   4 GREEN      --keep-going over an all-green root: rc 0, no red-steps line
--   5 MUTANT     _gs_one's record-and-continue line removed from a copy of
--                build.sh: arm 2's world names only a — arm 2 has teeth
--
-- Usage: tillandsias-plan script run scripts/lua/test-gate-keep-going.lua
-- Verdict: ok:gate-keep-going:<n> arms | violation:gate-keep-going:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("gate-keep-going")
local ROOT = fixture.repo_root()
local S = T:scratch()

local function step(dir, n, name, rc)
    fs.write(dir.rel .. "/scripts/s-" .. name .. ".sh",
        "#!/usr/bin/env bash\necho step-" .. name .. "-ran\nexit " .. rc .. "\n")
    fs.write(dir.rel .. "/scripts/gate-steps.d/" .. n .. "-" .. name .. ".step", table.concat({
        'STEP_DESC="keep-going fixture step ' .. name .. '"',
        'STEP_SCRIPT="scripts/s-' .. name .. '.sh"',
        'STEP_ERROR="step ' .. name .. ' failed"',
        'STEP_OK="step ' .. name .. ' passed"',
    }, "\n") .. "\n")
end
local function mkroot(name, steps)
    local d = { rel = S.rel .. "/" .. name, abs = S.abs .. "/" .. name }
    fs.mkdir(d.rel .. "/scripts/gate-steps.d")
    for _, s in ipairs(steps) do step(d, s[1], s[2], s[3]) end
    return d
end
local mixed = mkroot("mixed", { { "100", "a", 1 }, { "200", "b", 0 }, { "300", "c", 1 } })
local green = mkroot("green", { { "100", "x", 0 }, { "200", "y", 0 } })

local function gate(build, r, extra)
    local argv = { fixture.posix_shell(), build, "--gate-steps", r.abs }
    if extra and extra.kg then argv[#argv + 1] = "--keep-going" end
    local res = proc.run({ argv = argv, timeout_ms = 300000, cwd = ROOT,
        env = { PATH = env.get("PATH"), HOME = env.get("HOME"), XDG_RUNTIME_DIR = env.get("XDG_RUNTIME_DIR"),
                TILLANDSIAS_GATE_STEP_JOBS = extra and extra.jobs or "1" } })
    return res.code, (res.stdout or "") .. (res.stderr or "")
end
local function has(o, s) return o:find(s, 1, true) ~= nil end
local B = ROOT .. "/build.sh"

-- 1
local rc, o = gate(B, mixed)
T:arm("1 FAIL-FAST default stops at the first red: rc 1, a named, c never ran",
    rc == 1 and has(o, "step a failed") and not has(o, "step-c-ran") and not has(o, "red-steps:"), "rc=" .. tostring(rc) .. "\n" .. o)

-- 2
rc, o = gate(B, mixed, { kg = true })
T:arm("2 ALL REDS --keep-going names a AND c, rc 1, b ran green between them",
    rc == 1 and has(o, "red-steps:2") and has(o, "red-step:100-a.step:rc=1") and has(o, "red-step:300-c.step:rc=1")
    and has(o, "step-b-ran") and has(o, "step-c-ran"), "rc=" .. tostring(rc) .. "\n" .. o)

-- 3
rc, o = gate(B, mixed, { kg = true, jobs = "3" })
T:arm("3 POOL under jobs=3 the workers' reds reach the summary: red-steps:2 naming a and c",
    rc == 1 and has(o, "red-steps:2") and has(o, "red-step:100-a.step:") and has(o, "red-step:300-c.step:"),
    "rc=" .. tostring(rc) .. "\n" .. o)

-- 4
rc, o = gate(B, green, { kg = true })
T:arm("4 GREEN --keep-going over an all-green root: rc 0, no red-steps line",
    rc == 0 and not has(o, "red-steps:"), "rc=" .. tostring(rc) .. "\n" .. o)

-- 5
local src = fs.read("build.sh") or ""
local cut = '_kg_note "${_step_file##*/}" "$_step_rc" && return 0'
if not src:find(cut, 1, true) then
    T:arm("5 MUTANT premise: the record-and-continue line is in build.sh", false, "not found")
else
    -- The mutant lives in SCRATCH, never at the repo root: a run KILLed between write
    -- and rm left it in the live checkout (yoga 2026-11-23 and 2026-11-24). Its one
    -- SCRIPT_DIR line is pinned to the real root, so it reads what build.sh reads.
    local mut, nd = src:gsub('\nSCRIPT_DIR=[^\n]*', function() return '\nSCRIPT_DIR="' .. ROOT .. '"' end, 1)
    local nc
    mut = mut:gsub('\n_BUILDER_DIR=[^\n]*', function() return '\n_BUILDER_DIR="' .. ROOT .. '"' end, 1)
    mut, nc = mut:gsub(cut:gsub("%p", "%%%0"), ":", 1)
    fs.write(S.rel .. "/mutant-build.sh", mut)
    rc, o = gate(S.abs .. "/mutant-build.sh", mixed, { kg = true })
    T:arm("5 MUTANT without record-and-continue only a is named: arm 2 has teeth",
        nd == 1 and nc == 1 and rc ~= 0 and has(o, "step-a-ran") and not has(o, "red-step:300-c.step"), "nd=" .. nd .. " nc=" .. nc .. " rc=" .. tostring(rc) .. "\n" .. o)
end
T:finish()
