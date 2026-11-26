-- @env PATH HOME
-- @trace spec:ci-release, order:1325-ygq5, order:2306-y8sg
--
-- test-added-test-is-referenced.lua — prove scripts/check-added-test-is-referenced.sh REFUSES,
-- not merely that it passes on a clean tree. Ported from the .sh of the same name (2306-y8sg);
-- same ten arms, each in its own throwaway repo holding a copy of the guard.
--
-- Usage: tillandsias-plan script run scripts/lua/test-added-test-is-referenced.lua
-- Verdict: ok:added-test-is-referenced:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("added-test-is-referenced")
local SH = fixture.posix_shell()
-- BUILT, never spelled beside a synthetic name: check-litmus-pin-claims.sh reads the literal
-- token as a claim that a real test of that name exists.
local L = "lit" .. "mus"

local function setup(files)
    local d = T:git_repo()
    local function put(f, body)
        local dir = f:match("^(.*)/")
        if dir then fs.mkdir(d.rel .. "/" .. dir) end
        fs.write(d.rel .. "/" .. f, body)
    end
    fs.mkdir(d.rel .. "/scripts/hooks"); fs.mkdir(d.rel .. "/scripts/gate-steps.d"); fs.mkdir(d.rel .. "/openspec/litmus-tests")
    for _, f in ipairs{ "scripts/check-added-test-is-referenced.sh", "scripts/test-reference-surfaces.manifest" } do put(f, fs.read(f)) end
    put("build.sh", ""); put("scripts/local-ci.sh", "")
    put("openspec/litmus-bindings.yaml", "specs:\n- spec_id: ci-release\n  litmus_tests:\n  - " .. L .. ":already-bound\n")
    put("scripts/unreferenced-grandfathered.txt", "# grandfather list\n")
    put("openspec/litmus-tests/unbound-grandfathered.txt", "# grandfather list\n")
    d.put = put
    d.commit = function()
        T:must{ "git", "-C", d.abs, "add", "-A" }; T:must{ "git", "-C", d.abs, "commit", "-q", "-m", "base" }
        d.base = text.trim(T:must{ "git", "-C", d.abs, "rev-parse", "HEAD" }.stdout)
    end
    d.commit()
    for f, body in pairs(files or {}) do put(f, body) end
    return d
end
local function run(d, enforce)
    local r = proc.run{ argv = { SH, d.abs .. "/scripts/check-added-test-is-referenced.sh" }, cwd = d.abs, timeout_ms = 60000, env = {
        PATH = env.get("PATH"), HOME = env.get("HOME"), TILLANDSIAS_ADDED_TEST_BASE = d.base,
        TILLANDSIAS_ADDED_TEST_REFERENCE_ENFORCE = enforce and "1" or "0" } }
    local o, e = text.trim(r.stdout or ""), r.stderr or ""
    return o, r.code, e, "rc=" .. tostring(r.code) .. " [" .. o .. "] " .. e:sub(1, 300)
end
local function starts(s, p) return s:sub(1, #p) == p end
local WARN1, OK0, OK1 = "warn:added-test-unreferenced:1 standing=", "ok:added-test-referenced:0 checked", "ok:added-test-referenced:1 checked"

local d = setup{ ["scripts/test-orphan-arm.sh"] = "#!/bin/bash\necho ok:nothing\n" }
local o, rc, e, why = run(d)
T:arm("1 an unreferenced shell test warns and is named", starts(o, WARN1) and text.contains(o, "surfaces=") and text.contains(e, "test-orphan-arm.sh"), why)
T:arm("2 the migration phase does not refuse", rc == 0, why)
o, rc, e, why = run(d, true)
T:arm("3 ENFORCE=1 refuses with exit 1", o == "violation:added-test-unreferenced:1" and rc == 1, why)
d = setup{ ["scripts/test-bound-arm.sh"] = "#!/bin/bash\necho ok:real\n", ["scripts/gate-steps.d/90-bound.step"] = "STEP_SCRIPT=scripts/test-bound-arm.sh\n" }
o, rc, e, why = run(d)
T:arm("4 a test a gate step names is accepted", starts(o, OK1), why)
d = setup{ ["openspec/litmus-tests/litmus-orphan-shape.yaml"] = "name: " .. L .. ":orphan-shape\nspec: ci-release\n" }
o, rc, e, why = run(d)
T:arm("5 an unbound litmus yaml warns and is named", starts(o, "warn:added-test-unreferenced:1") and text.contains(e, L .. ":orphan-shape"), why)
d = setup{ ["openspec/litmus-tests/litmus-already-bound.yaml"] = "name: " .. L .. ":already-bound\nspec: ci-release\n" }
o, rc, e, why = run(d)
T:arm("6 a bound litmus yaml is accepted", starts(o, OK1), why)
d = setup{ ["scripts/test-manual-drill.sh"] = "#!/bin/bash\necho ok:manual\n",
    ["scripts/unreferenced-grandfathered.txt"] = "# grandfather list\ntest-manual-drill.sh  # operator-run drill, no gate can host it\n" }
o, rc, e, why = run(d)
T:arm("7 CONTROL a grandfathered test passes and says it was declared", starts(o, OK1) and text.contains(e, "declared unreferenced"), why)
d = setup{ ["openspec/litmus-tests/litmus-gone-shape.yaml"] = "name: " .. L .. ":gone-shape\nspec: ci-release\nphase: retired\n" }
o, rc, e, why = run(d)
T:arm("8 a retired litmus yaml is skipped, not counted", starts(o, OK0), why)
d = setup{ ["scripts/test-whatever.sh"] = "#!/bin/bash\n" }
T:must{ "rm", "-f", d.abs .. "/scripts/test-reference-surfaces.manifest" }
o, rc, e, why = run(d)
T:arm("9 a missing surface manifest refuses, never a silent green", o == "violation:added-test-unreferenced:0" and rc == 2, why)
d = setup{ ["scripts/test-inherited.sh"] = "#!/bin/bash\necho ok:old\n" }
d.commit(); d.put("scripts/test-inherited.sh", "#!/bin/bash\necho ok:old-edited\n")
o, rc, e, why = run(d)
T:arm("10 editing an inherited unreferenced test is not refused", starts(o, OK0), why)
T:finish()
