-- @trace order:1401-x76w, order:2262-5kk6, order:2206-js5t, order:2305-zm8j, order:2297-vrsa, order:2401-prg5
-- @env PATH HOME
--
-- test-preflight-fixtures-default-target.lua — 1401-x76w's verifiable closure. Ported from
-- test-preflight-fixtures-default-target.sh (2401-prg5); same arms, in its order.
--
-- Every arm runs a COPY of the decider (scripts/preflight-fixtures-default-target.sh) in a
-- scratch repo whose plan binary is a stub at the default target (./target/release). Two
-- fixtures there resolve it with the real resolver (scripts/plan-binary-probe.sh, copied):
--   test-cd-first.sh   resolves AFTER `cd /`, the 1375-2x4e shape
--   test-absolute.sh   resolves inside the checkout and absolutises first
--
--   PRECONDITION  the cd-first fixture passes under both masks (else arms 1-2 prove nothing)
--   1   an absolute CARGO_TARGET_DIR does not hide the cd-first fixture: refused by name
--   2   a plan binary on PATH does not hide it either: refused by name
--   3   NEGATIVE CONTROL: the absolutising fixture is admitted under both masks
--   4   a fixture that SKIPS when it cannot find the binary is refused too
--   5a  a red fixture no gate runs is refused as ungated-red, in its own words (2262-5kk6)
--   5d  a mention, a comment and an advisory `|| true` call are not gates
--   5c  one build.sh runs inline is a note that says so
--   5b  one a .step runs is a note naming the step
--   5e  could-not-run (exit 3) is a note
--   5f  one red only from the guard's scratch cwd is a note
--   7   no timeout command: a NAMED skip, never an unbounded run
--   8   (2206-js5t) a Lua fixture masked by a plan binary on PATH is refused
--   9   NEGATIVE CONTROL for 8: the absolutising Lua fixture is admitted and counted
--   11  (2305-zm8j) a Lua fixture red only under a gate's variables is refused as gate-env
--   12  NEGATIVE CONTROL for 11: the same subject with env_unset is admitted
--   6   with no arguments the population is the added fixtures, counted
--   10  (2297-vrsa) a red helper under scripts/test-support/ is not counted as a fixture
--
-- Arms 8-12 need a REAL runner (a stub cannot run Lua); they copy the caller's plan binary and
-- skip by name without one. Every tree is under target/plan-scratch.
--
-- GRAMMAR ok:fixture-default-target-fixture:<n> arms | violation:fixture-default-target-fixture:<n>-failed
--       | skip:fixture-default-target-fixture:decider-absent

local fixture = require "common.fixture"
local T = fixture.new("fixture-default-target-fixture")
local ROOT = fixture.repo_root()
local SH = fixture.posix_shell()
local DEC = "scripts/preflight-fixtures-default-target.sh"
if not fs.exists(DEC) then T:skip("decider-absent") end

local W = T:scratch()
local R, Rabs = W.rel .. "/repo", W.abs .. "/repo"
for _, d in ipairs({ R .. "/scripts", R .. "/target/release", W.rel .. "/pathbin", W.rel .. "/ctd/release" }) do fs.mkdir(d) end
T:must{ "cp", ROOT .. "/" .. DEC, ROOT .. "/scripts/plan-binary-probe.sh", Rabs .. "/scripts/" }
for _, p in ipairs({ R .. "/target/release", W.rel .. "/pathbin", W.rel .. "/ctd/release" }) do
    fs.write(p .. "/tillandsias-plan", "#!/bin/sh\nexit 0\n")
end
T:must{ "chmod", "+x", Rabs .. "/target/release/tillandsias-plan", W.abs .. "/pathbin/tillandsias-plan", W.abs .. "/ctd/release/tillandsias-plan" }

local HEAD = '#!/usr/bin/env bash\nROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"\n. "$ROOT/scripts/plan-binary-probe.sh"\n'
fs.write(R .. "/scripts/test-cd-first.sh", HEAD
    .. 'cd / || exit 1\nP="$(resolve_plan_binary)" || { echo "no plan binary from /"; exit 2; }\n"$P" capabilities && echo "ok:cd-first"\n')
fs.write(R .. "/scripts/test-absolute.sh", HEAD
    .. 'P="$(cd "$ROOT" && resolve_plan_binary)" || { echo "no plan binary"; exit 2; }\ncase "$P" in /*) ;; *) P="$ROOT/${P#./}" ;; esac\ncd / || exit 1\n"$P" capabilities && echo "ok:absolute"\n')
fs.write(R .. "/scripts/test-skips.sh", HEAD
    .. 'cd / || exit 1\nP="$(resolve_plan_binary)" || { echo "skip:skips-fixture:no-plan-binary"; exit 0; }\n"$P" capabilities && echo "ok:skips"\n')
fs.write(R .. "/scripts/test-red.sh", '#!/usr/bin/env bash\necho "broken regardless"; exit 1\n')
local function chmodx()
    local argv = { "chmod", "+x" }
    for _, f in ipairs({ "test-cd-first.sh", "test-absolute.sh", "test-skips.sh", "test-red.sh", "test-cnr.sh" }) do
        if fs.exists(R .. "/scripts/" .. f) then argv[#argv + 1] = Rabs .. "/scripts/" .. f end
    end
    T:must(argv)
end
chmodx()

-- A clean base PATH: the host's own plan binary, if any, must not decide an arm.
local bp = T:run{ SH, "-s", stdin = 'B=""; IFS=:\nfor d in $PATH; do [ -e "$d/tillandsias-plan" ] || [ -e "$d/tillandsias-plan.exe" ] || B="${B:+$B:}$d"; done\nprintf "%s" "$B"\n' }
local BASEPATH = text.trim(bp.stdout or "")
if BASEPATH == "" then T:refuse("setup-failed", "could not build a base PATH") end

local function cat(r) return (r.stdout or "") .. (r.stderr or "") end
local function last(s)
    local L = text.lines(text.trim(s)); return L[#L] or ""
end
local function tail2(s)
    local L = text.lines(text.trim(s)); return table.concat({ L[#L - 1] or "", L[#L] or "" }, ";")
end
local function has(s, w) return text.contains(s, w) end

local function by_ctd(args, extra, cwd)
    local e = { CARGO_TARGET_DIR = W.abs .. "/ctd", PATH = BASEPATH }
    for k, v in pairs(extra or {}) do e[k] = v end
    local argv = { SH, Rabs .. "/" .. DEC }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    argv.cwd, argv.env, argv.env_unset, argv.timeout_ms = cwd or ROOT, e, { "TILLANDSIAS_PLAN_BIN" }, 300000
    local r = T:run(argv); return cat(r), r.code
end
local function by_path(args)
    local argv = { SH, Rabs .. "/" .. DEC }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    argv.cwd, argv.env, argv.env_unset, argv.timeout_ms = ROOT, { PATH = W.abs .. "/pathbin:" .. BASEPATH },
        { "TILLANDSIAS_PLAN_BIN", "CARGO_TARGET_DIR" }, 300000
    local r = T:run(argv); return cat(r), r.code
end

-- PRECONDITION: the masks really mask.
local pc = T:run{ SH, Rabs .. "/scripts/test-cd-first.sh", cwd = W.abs,
    env = { CARGO_TARGET_DIR = W.abs .. "/ctd", PATH = BASEPATH }, env_unset = { "TILLANDSIAS_PLAN_BIN" } }
local pp = T:run{ SH, Rabs .. "/scripts/test-cd-first.sh", cwd = W.abs,
    env = { PATH = W.abs .. "/pathbin:" .. BASEPATH }, env_unset = { "TILLANDSIAS_PLAN_BIN", "CARGO_TARGET_DIR" } }
T:arm("PRECONDITION the cd-first fixture passes under both masks", pc.code == 0 and pp.code == 0,
    "ctd rc=" .. tostring(pc.code) .. " path rc=" .. tostring(pp.code) .. ": " .. cat(pc) .. cat(pp))

local o, rc = by_ctd({ "scripts/test-cd-first.sh" })
T:arm("ARM 1 an absolute CARGO_TARGET_DIR does not hide the cd-first fixture",
    rc ~= 0 and has(o, "refused:fixture-default-target:scripts/test-cd-first.sh"), "rc=" .. tostring(rc) .. " " .. tail2(o))

o, rc = by_path({ "scripts/test-cd-first.sh" })
T:arm("ARM 2 a plan binary on PATH does not hide the cd-first fixture",
    rc ~= 0 and has(o, "refused:fixture-default-target:scripts/test-cd-first.sh"), "rc=" .. tostring(rc) .. " " .. tail2(o))

local o3c, rc3c = by_ctd({ "scripts/test-absolute.sh" })
local o3p, rc3p = by_path({ "scripts/test-absolute.sh" })
T:arm("ARM 3 the absolutising fixture is admitted under both masks",
    rc3c == 0 and rc3p == 0 and last(o3c) == "ok:fixture-default-target:1 checked",
    "ctd rc=" .. tostring(rc3c) .. " path rc=" .. tostring(rc3p) .. " " .. tail2(o3c .. o3p))

o, rc = by_ctd({ "scripts/test-skips.sh" })
T:arm("ARM 4 a fixture that skips without the mask is refused",
    rc ~= 0 and has(o, "refused:fixture-default-target:scripts/test-skips.sh"), "rc=" .. tostring(rc) .. " " .. tail2(o))

o, rc = by_ctd({ "scripts/test-red.sh" })
T:arm("ARM 5a a red fixture no gate runs is refused, in its own words",
    rc == 1 and has(o, "refused:fixture-default-target:ungated-red:scripts/test-red.sh")
        and has(o, "broken regardless") and has(o, "why:"), "rc=" .. tostring(rc) .. " " .. tail2(o))

-- d first: none of these gates it.
fs.mkdir(R .. "/scripts/gate-steps.d")
fs.write(R .. "/scripts/gate-steps.d/010-mention.step",
    'STEP_SCRIPT="scripts/test-other.sh"\nSTEP_READS="scripts/test-red.sh"\n# STEP_SCRIPT="scripts/test-red.sh"\n')
fs.write(R .. "/build.sh", '    # _run bash "$SCRIPT_DIR/scripts/test-red.sh" 2>&1\n    _run bash "$SCRIPT_DIR/scripts/test-red.sh" 2>&1 || true\n')
o, rc = by_ctd({ "scripts/test-red.sh" })
T:arm("ARM 5d a mention, a comment and an advisory call are not gates",
    rc == 1 and has(o, "ungated-red:scripts/test-red.sh"), "rc=" .. tostring(rc) .. " " .. tail2(o))

fs.write(R .. "/build.sh", '    if ! _run bash "$SCRIPT_DIR/scripts/test-red.sh" 2>&1; then\n')
o, rc = by_ctd({ "scripts/test-red.sh" })
T:arm("ARM 5c one build.sh runs inline is a note that says so",
    rc == 0 and has(o, "scripts/test-red.sh:rc=1 gated-by: build.sh inline step — broken regardless")
        and not has(o, "refused:"), "rc=" .. tostring(rc) .. " " .. tail2(o))

T:must{ "rm", "-f", Rabs .. "/build.sh" }
fs.write(R .. "/scripts/gate-steps.d/020-red.step", 'STEP_SCRIPT="scripts/test-red.sh"\n')
o, rc = by_ctd({ "scripts/test-red.sh" })
T:arm("ARM 5b one a step runs is a note naming the step",
    rc == 0 and has(o, "scripts/test-red.sh:rc=1 gated-by: step 020-red.step — broken regardless")
        and not has(o, "refused:"), "rc=" .. tostring(rc) .. " " .. tail2(o))

T:must{ "rm", "-rf", Rabs .. "/scripts/gate-steps.d" }
fs.write(R .. "/scripts/test-cnr.sh", '#!/usr/bin/env bash\necho "could-not-run:x:no-tool"; exit 3\n')
chmodx()
o, rc = by_ctd({ "scripts/test-cnr.sh" })
T:arm("ARM 5e could-not-run is a note, not a red",
    rc == 0 and has(o, "note:fixture-default-target:could-not-run:scripts/test-cnr.sh — could-not-run:x:no-tool"),
    "rc=" .. tostring(rc) .. " " .. tail2(o))

fs.write(R .. "/scripts/test-cnr.sh", '#!/usr/bin/env bash\n[ -d scripts ] || { echo "not in the checkout"; exit 1; }\necho ok:cwd\n')
chmodx()
o, rc = by_ctd({ "scripts/test-cnr.sh" })
T:arm("ARM 5f one red only from the scratch cwd is a note that says so",
    rc == 0 and has(o, "note:fixture-default-target:red-only-from-scratch-cwd:scripts/test-cnr.sh:rc=1 — not in the checkout"),
    "rc=" .. tostring(rc) .. " " .. tail2(o))
T:must{ "rm", "-f", Rabs .. "/scripts/test-cnr.sh" }

-- ARM 7: no timeout command (a stock macOS without coreutils) is a NAMED skip.
o, rc = by_ctd({ "scripts/test-cd-first.sh" }, { TILLANDSIAS_DEFAULT_TARGET_TIMEOUT_CMD = "none" })
T:arm("ARM 7 with no timeout command the decider skips by name instead of running unbounded",
    rc == 0 and last(o) == "skip:fixture-default-target:no-timeout-command", "rc=" .. tostring(rc) .. " " .. tail2(o))

-- ARMS 8-12: Lua fixtures, run by a real runner copied to the default target of a second
-- scratch repo and to a PATH directory (the mask).
local REALP = fixture.plan_binary()
local caps = ""
if REALP ~= "" then caps = T:run{ REALP, "capabilities" }.stdout or "" end
local has_script = false
for _, l in ipairs(text.lines(caps)) do if text.trim(l) == "script" then has_script = true end end
if not has_script then
    out.line("skip:arm-8-9:no-real-lua-runner")
else
    local L, Labs = W.rel .. "/lrepo", W.abs .. "/lrepo"
    fs.mkdir(L .. "/scripts/lua"); fs.mkdir(L .. "/target/release"); fs.mkdir(W.rel .. "/lpath")
    -- The Lua runner roots a decider at the repository containing its cwd (2213-ag5u).
    T:must{ "git", "init", "-q", Labs }
    T:must{ "cp", ROOT .. "/" .. DEC, ROOT .. "/scripts/plan-binary-probe.sh", Labs .. "/scripts/" }
    T:must{ "cp", REALP, Labs .. "/target/release/tillandsias-plan" }
    T:must{ "cp", REALP, W.abs .. "/lpath/tillandsias-plan" }
    fs.write(L .. "/scripts/res-cd-first.sh",
        '. scripts/plan-binary-probe.sh\ncd / || exit 1\nP="$(resolve_plan_binary)" || exit 2\n"$P" capabilities >/dev/null\n')
    fs.write(L .. "/scripts/res-absolute.sh",
        '. scripts/plan-binary-probe.sh\nP="$(resolve_plan_binary)" || exit 2\ncase "$P" in /*) ;; *) P="$PWD/${P#./}" ;; esac\ncd / || exit 1\n"$P" capabilities >/dev/null\n')
    -- The scratch fixtures below are DATA for the copied decider's runner; this file spawns
    -- none of them. They spell the shell as the .sh did.
    local SHELL_NAME = "bash"
    local function inner(k, script, extra)
        fs.write(L .. "/scripts/lua/test-" .. k .. ".lua", string.format(
            'local r = proc.run{ argv = { %q, %q }%s, timeout_ms = 60000 }\nif r.ok then verdict.ok("lua-%s") end\nverdict.refused("lua-%s")\n',
            SHELL_NAME, script, extra or "", k, k))
    end
    inner("cd-first", "scripts/res-cd-first.sh"); inner("absolute", "scripts/res-absolute.sh")
    local function by_lpath(f)
        local r = T:run{ SH, Labs .. "/" .. DEC, f, cwd = Labs, timeout_ms = 300000,
            env = { PATH = W.abs .. "/lpath:" .. BASEPATH },
            env_unset = { "TILLANDSIAS_PLAN_BIN", "TILLANDSIAS_SCRIPT_RUNNER_BIN", "CARGO_TARGET_DIR" } }
        return cat(r), r.code
    end
    o, rc = by_lpath("scripts/lua/test-cd-first.lua")
    T:arm("ARM 8 a Lua fixture masked by a plan binary on PATH is refused",
        rc ~= 0 and has(o, "refused:fixture-default-target:scripts/lua/test-cd-first.lua"), "rc=" .. tostring(rc) .. " " .. tail2(o))
    o, rc = by_lpath("scripts/lua/test-absolute.lua")
    -- Not noted as red in both regimes: a fixture the runner refused everywhere is "checked"
    -- and noted, which would admit it vacuously (2213-ag5u).
    T:arm("ARM 9 the absolutising Lua fixture is admitted and counted",
        rc == 0 and last(o) == "ok:fixture-default-target:1 checked" and not has(o, "red-in-both-or-normal-regime"),
        "rc=" .. tostring(rc) .. " " .. tail2(o))
    fs.write(L .. "/scripts/reads-gate.sh", '[ -z "${TILLANDSIAS_FORGE_SEED_BRANCH:-}" ] && [ -z "${CARGO_TARGET_DIR:-}" ]\n')
    inner("leaks", "scripts/reads-gate.sh")
    inner("drops", "scripts/reads-gate.sh", ', env_unset = { "TILLANDSIAS_*", "CARGO_TARGET_DIR" }')
    o, rc = by_lpath("scripts/lua/test-leaks.lua")
    T:arm("ARM 11 a Lua fixture red only under a gate's variables is refused",
        rc ~= 0 and has(o, "refused:fixture-default-target:gate-env:scripts/lua/test-leaks.lua"), "rc=" .. tostring(rc) .. " " .. tail2(o))
    o, rc = by_lpath("scripts/lua/test-drops.lua")
    if has(o, "unknown field 'env_unset'") then
        out.line("skip:arm-12:plan-binary-without-env_unset")
    else
        T:arm("ARM 12 the same subject with env_unset is admitted",
            rc == 0 and last(o) == "ok:fixture-default-target:1 checked" and not has(o, "note:fixture-default-target"),
            "rc=" .. tostring(rc) .. " " .. tail2(o))
    end
end

-- ARM 6: population mode. Base holds only the decider and resolver; the absolutising fixture
-- is added (untracked), the rest are removed.
T:must{ "rm", "-f", Rabs .. "/scripts/test-cd-first.sh", Rabs .. "/scripts/test-skips.sh", Rabs .. "/scripts/test-red.sh" }
T:must{ "git", "init", "-q", Rabs }
T:must{ "git", "-C", Rabs, "config", "user.email", "f@x.invalid" }
T:must{ "git", "-C", Rabs, "config", "user.name", "f" }
T:must{ "git", "-C", Rabs, "config", "commit.gpgsign", "false" }
T:must{ "git", "-C", Rabs, "add", "scripts/preflight-fixtures-default-target.sh", "scripts/plan-binary-probe.sh" }
T:must{ "git", "-C", Rabs, "commit", "-qm", "base" }
T:must{ "git", "-C", Rabs, "update-ref", "refs/remotes/origin/linux-next", "HEAD" }
-- The gate exports its frozen TILLANDSIAS_GATE_DIFF_BASE, a commit this scratch repo does not
-- hold (2241-f8jg), so the arm names its own base.
local POP = { TILLANDSIAS_DEFAULT_TARGET_BASE = "", TILLANDSIAS_GATE_DIFF_BASE = "refs/remotes/origin/linux-next" }
o, rc = by_ctd({}, POP, Rabs)
T:arm("ARM 6 a bare run finds the one added fixture and counts it",
    rc == 0 and last(o) == "ok:fixture-default-target:1 checked", "rc=" .. tostring(rc) .. " " .. tail2(o))

-- ARM 10 (2297-vrsa): a red helper under scripts/test-support/ is not a fixture.
fs.mkdir(R .. "/scripts/test-support")
fs.write(R .. "/scripts/test-support/mock.sh", '#!/usr/bin/env bash\necho "helper, not a fixture"; exit 97\n')
T:must{ "chmod", "+x", Rabs .. "/scripts/test-support/mock.sh" }
o, rc = by_ctd({}, POP, Rabs)
T:arm("ARM 10 a helper in a test-* directory is not counted as a fixture",
    rc == 0 and last(o) == "ok:fixture-default-target:1 checked", "rc=" .. tostring(rc) .. " " .. tail2(o))

T:finish()
