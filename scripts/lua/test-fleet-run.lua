-- @trace order:2250-44uy
-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN CARGO_TARGET_DIR
--
-- test-fleet-run.lua — fleet-run.lua takes a step NUMBER and a REF and
-- nothing else, and refuses every other shape before extracting or running
-- anything. Arm 6 extracts HEAD and refuses a step number that does not
-- exist, which proves the extract + init + tree-equality path without
-- running a gate (a real one-step run is the record a host pastes).
--
--   1 no args              refused:fleet-run:usage, rc 2
--   2 a non-numeric step   refused:fleet-run:bad-step:12x
--   3 a ref that is a flag refused:fleet-run:bad-ref:-x
--   4 a range              refused:fleet-run:bad-ref:a..b
--   5 shell syntax         refused:fleet-run:bad-ref:$(id)
--   6 HEAD, no such step   refused:fleet-run:no-step:99999 (tree matched)
--
-- Over a scratch repo whose build.sh is a stub (native Windows runs the step
-- directly, so both roads are real), with this plan binary:
--   7 a green step         regime rc=0, ok:, rc 0 (control)
--   8 a red step           regime rc=1, violation:, rc 1
--   9 a step past its deadline: rc=-1 regime, could-not-run:, rc 2, never ok:
--     (RED before 2259-fk3m's fix: ok:fleet-run, rc 0)
--  10 its child is killed with it (the child's marker is never written)
--  11 no extract is left behind by 7-9
--  12 a diff-scoped (*-added) step judges the ref against its merge-base with
--     origin/linux-next: an added line is a violation, not skip:no-base-ref
--     (RED before 2250-44uy round 3: the depth=1 extract had no base)
--  13 a skip verdict is reported as one: result=skip in the regime line and
--     skip:fleet-run, never ok:fleet-run (a skip is not evidence)
--
-- GRAMMAR ok:fleet-run-shape:13 | violation:fleet-run-shape:<n>-failed

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.code ~= 0 or ROOT == "" then verdict.could_not_run("fleet-run-shape", "no repo") end
local BIN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") or env.get("TILLANDSIAS_PLAN_BIN") or ""
if BIN == "" then
    local ctd = env.get("CARGO_TARGET_DIR") or ""
    BIN = (ctd ~= "" and ctd or ROOT .. "/target") .. "/release/tillandsias-plan"
end
if BIN:sub(1, 2) == "./" then BIN = ROOT .. "/" .. BIN:sub(3) end
if proc.run({ argv = { "test", "-x", BIN }, timeout_ms = 10000 }).code ~= 0 then
    verdict.could_not_run("fleet-run-shape", "no plan binary at " .. BIN)
end

local failed = {}
local function arm(name, args, want)
    local argv = { BIN, "script", "run", ROOT .. "/scripts/lua/fleet-run.lua", "--" }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local r = proc.run({ argv = argv, cwd = ROOT, timeout_ms = 600000 })
    local o = text.trim(r.stdout or "")
    if r.code == 2 and o == want then out.line("ok:   " .. name)
    else
        out.line("FAIL: " .. name .. " — rc=" .. tostring(r.code) .. " got: " .. o:gsub("\n", " | "))
        failed[#failed + 1] = name
    end
end
arm("1 no args", {}, "refused:fleet-run:usage")
arm("2 non-numeric step", { "12x", "HEAD" }, "refused:fleet-run:bad-step:12x")
arm("3 a ref that is a flag", { "1", "-x" }, "refused:fleet-run:bad-ref:-x")
arm("4 a range", { "1", "a..b" }, "refused:fleet-run:bad-ref:a..b")
arm("5 shell syntax", { "1", "$(id)" }, "refused:fleet-run:bad-ref:$(id)")
arm("6 HEAD extracts, tree matches, no such step", { "99999", "HEAD" }, "refused:fleet-run:no-step:99999")
local head = text.trim(proc.run({ argv = { "git", "rev-parse", "HEAD" }, cwd = ROOT, timeout_ms = 30000 }).stdout or "")
if head ~= "" then proc.run({ argv = { "rm", "-rf", ROOT .. "/target/work/fleet-run/" .. head }, timeout_ms = 60000 }) end

local fixture = require "common.fixture"
local T = fixture.new("fleet-run-shape")
local R = T:git_repo("fr")
fs.mkdir(R.rel .. "/scripts/gate-steps.d"); fs.mkdir(R.rel .. "/target/release"); fs.mkdir(R.rel .. "/lib/lua/common")
fs.write(R.rel .. "/.gitignore", "/target/\n/marker\n")
fs.write(R.rel .. "/build.sh", 'set -u\n. "$2"/scripts/gate-steps.d/*.step\necho "[build] $STEP_DESC..."\n'
    .. 'bash "$STEP_SCRIPT"; rc=$?\necho "[build] done"\nexit $rc\n')
local function step(n, body)
    fs.write(R.rel .. "/scripts/gate-steps.d/" .. n .. "-x.step",
        'STEP_DESC="scratch step ' .. n .. '"\nSTEP_SCRIPT="scripts/s' .. n .. '.sh"\n')
    fs.write(R.rel .. "/scripts/s" .. n .. ".sh", body)
end
step(1, "echo ok:scratch:1\n")
step(2, "echo violation:scratch:1\nexit 1\n")
step(3, '(sleep 6; echo alive > "' .. R.abs .. '/marker") &\nsleep 60\n')
-- An *-added decider in miniature: what changed since TILLANDSIAS_GATE_DIFF_BASE.
step(4, 'b="${TILLANDSIAS_GATE_DIFF_BASE:-}"\n'
    .. 'git rev-parse -q --verify "$b^{commit}" >/dev/null 2>&1 || { echo skip:scratch-added:no-base-ref; exit 0; }\n'
    .. 'if git diff --name-only "$b" -- added.txt | grep -q .; then echo violation:scratch-added:added.txt; exit 1; fi\n'
    .. 'echo ok:scratch-added:0\n')
step(5, "echo skip:scratch:nothing-to-judge\n")
for _, f in ipairs({ "fixture", "verdict" }) do
    fs.write(R.rel .. "/lib/lua/common/" .. f .. ".lua", fs.read("lib/lua/common/" .. f .. ".lua"))
end
-- Same crates on both sides, or fleet-run builds a plan binary (and cargo, with
-- no manifest here, would build the enclosing checkout's).
fs.mkdir(R.rel .. "/crates"); fs.write(R.rel .. "/crates/README", "scratch\n")
for _, f in ipairs({ "Cargo.toml", "Cargo.lock" }) do fs.write(R.rel .. "/" .. f, "# scratch: not a workspace\n") end
fs.write(R.rel .. "/scripts/fleet-run.lua", fs.read("scripts/lua/fleet-run.lua"))
T:must{ "git", "-C", R.abs, "add", "-A" }
T:must{ "git", "-C", R.abs, "commit", "-q", "-m", "steps" }
-- The base is trunk; the ref under test adds one line after it.
T:must{ "git", "-C", R.abs, "update-ref", "refs/remotes/origin/linux-next", "HEAD" }
fs.write(R.rel .. "/added.txt", "an added line\n")
T:must{ "git", "-C", R.abs, "add", "added.txt" }
T:must{ "git", "-C", R.abs, "commit", "-q", "-m", "adds a line" }
local exe = fixture.posix_shell() ~= "bash" and ".exe" or ""
T:must{ "cp", BIN .. ((exe ~= "" and not BIN:find("%.exe$")) and exe or ""), R.abs .. "/target/release/tillandsias-plan" .. exe }
local function fr(n, ms)
    local r = proc.run({ argv = { BIN, "script", "run", "scripts/fleet-run.lua", "--", tostring(n), "HEAD" }, cwd = R.abs,
        env = { TILLANDSIAS_FLEET_RUN_TIMEOUT_MS = ms }, timeout_ms = 300000 })
    return r.code, (r.stdout or "") .. (r.code == 0 and "" or tostring(r.stderr))
end
local function arm2(name, cond, got)
    if cond then out.line("ok:   " .. name) else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got):gsub("\n", " | ")); failed[#failed + 1] = name end
end
local c, o = fr(1)
arm2("7 a green step is ok", c == 0 and text.contains(o, ":rc=0:") and text.contains(o, "verdict=ok:scratch:1")
    and text.contains(o, "ok:fleet-run:step=1"), "rc=" .. tostring(c) .. " " .. o)
c, o = fr(2)
arm2("8 a red step is a violation, never ok", c == 1 and text.contains(o, ":step=2:rc=1:")
    and text.contains(o, "violation:fleet-run:step=2:rc=1") and not text.contains(o, "\nok:fleet-run"), "rc=" .. tostring(c) .. " " .. o)
c, o = fr(3, "2000")
arm2("9 a step that did not exit is could-not-run, never ok", c == 2 and text.contains(o, ":step=3:rc=-1:")
    and text.contains(o, "could-not-run:fleet-run:step-did-not-exit:") and not text.contains(o, "\nok:fleet-run"),
    "rc=" .. tostring(c) .. " " .. o)
c, o = fr(4)
arm2("12 an added line is judged against the merge-base, not skipped", c == 1
    and text.contains(o, "verdict=violation:scratch-added:added.txt") and not text.contains(o, "no-base-ref"),
    "rc=" .. tostring(c) .. " " .. o)
c, o = fr(5)
arm2("13 a skip is reported as a skip, never ok", c == 0 and text.contains(o, ":result=skip:")
    and text.contains(o, "\nskip:fleet-run:step=5") and not text.contains(o, "\nok:fleet-run"), "rc=" .. tostring(c) .. " " .. o)
T:run{ fixture.posix_shell("/bin/bash"), "-s", stdin = "sleep 8\n" }
arm2("10 the step's child is killed with it", not fs.exists(R.rel .. "/marker"), "the child outlived the step")
local left = T:run{ "find", R.abs .. "/target/work/fleet-run", "-mindepth", "1", "-maxdepth", "1", "-type", "d", "-not", "-name", "cargo-target*" }
arm2("11 no extract is left behind", left.code == 0 and text.trim(left.stdout or "") == "", left.stdout)
T:cleanup()

if #failed > 0 then verdict.emit("violation:fleet-run-shape:" .. #failed .. "-failed", 1) end
verdict.ok("fleet-run-shape", "13")
