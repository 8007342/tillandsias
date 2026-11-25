-- @env PATH HOME
-- @trace order:1437-yfuh, order:2325-qmsb
--
-- test-litmus-covering-relay-scope.lua — `litmus-covering-specs.sh --relay-scope` partitions
-- the covering set into run and deferred (T4). Ported from the .sh of the same name
-- (2325-qmsb). Six arms over a synthetic corpus pin the rules; two over the REAL corpus pin
-- that the relay catches of 2026-09-27 are still selected (paths copied from the commits, so a
-- shallow clone runs).
--
--   1 a declared match runs whatever its size; an unbound test never appears
--   2 a command match: instant runs, long defers by size
--   3 a non-pre-build test defers by phase, even when declared
--   4 an edited litmus file selects its own spec
--   5 an untouched path: empty set, exit 0, nothing on stderr
--   6 cap 15, declared first then by name; --all-covering lifts it; reruns are byte-identical
--   7 f18dc0d74 (1428-v4tt): the PATH query answers 0 specs, relay-scope runs meta-orchestration
--   8 562e6281a (1432-x3ug): both the full run and relay-scope run the harness's spec
--
-- Usage: tillandsias-plan script run scripts/lua/test-litmus-covering-relay-scope.lua
-- Verdict: ok:litmus-covering-relay-scope:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("litmus-covering-relay-scope")
local SH, ROOT = fixture.posix_shell(), fixture.repo_root()
-- COMPOSED, never a literal name (721-77yu).
local L = "lit" .. "mus:"
local d

local function corpus(bound)
    d = T:scratch()
    fs.mkdir(d.rel .. "/tests")
    local y = "version: '1.0'\nspecs:\n"
    for _, n in ipairs(bound) do y = y .. "- spec_id: x\n  litmus_tests:\n  - " .. L .. n .. "\n" end
    fs.write(d.rel .. "/bind.yaml", y)
end
-- declared / command: a path, or nil.
local function mk(file, name, spec, phase, size, declared, command)
    fs.write(d.rel .. "/tests/" .. file .. ".yaml", "name: " .. L .. name .. "\nspec: " .. spec .. "\nphase: " .. phase .. "\nsize: " .. size .. "\npreconditions:\n"
        .. (declared and "  - workspace contains " .. declared .. "\n" or "") .. 'critical_path:\n  - step: "s"\n    command: "test -f ' .. (command or "-") .. '"\n')
end
local function map(real, ...)
    local e = { PATH = env.get("PATH"), HOME = env.get("HOME") }
    if not real then e.TILLANDSIAS_LITMUS_TESTS_DIR = d.abs .. "/tests"; e.TILLANDSIAS_LITMUS_BINDINGS = d.abs .. "/bind.yaml" end
    local r = proc.run{ argv = { SH, ROOT .. "/scripts/litmus-covering-specs.sh", ... }, cwd = ROOT, env = e, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 60000 }
    local o = (r.stdout or ""):gsub("\r", "")
    return { rc = r.code, out = o, err = r.stderr or "", why = "rc=" .. tostring(r.code) .. " " .. o:sub(1, 900) .. (r.stderr or "") }
end
local function scope(...) return map(false, "--relay-scope", ...) end
local function has(x, line) return text.contains("\n" .. x.out, "\n" .. line .. "\n") end

corpus{ "decl-long", "cmd-instant", "cmd-long", "post", "selfish" }
mk("a", "decl-long", "s-decl", "pre-build", "long", "lib/d.sh")
mk("b", "cmd-instant", "s-cmdi", "pre-build", "instant", nil, "lib/c.sh")
mk("c", "cmd-long", "s-cmdl", "pre-build", "long", nil, "lib/c.sh")
mk("d", "post", "s-post", "post-build", "instant", "lib/d.sh")
mk("e", "orphan", "s-orph", "pre-build", "instant", "lib/d.sh")
mk("f", "selfish", "s-self", "pre-build", "quick", nil, "none/at/all")
local x = scope("--paths", "lib/d.sh", "lib/c.sh")
T:arm("1 a declared match runs at any size and an unbound test never appears",
    has(x, "run:declared:s-decl\tlib/d.sh\tlong") and not text.contains(x.out, "s-orph"), x.why)
T:arm("2 a command match runs when instant and defers by size when long",
    has(x, "run:command:s-cmdi\tlib/c.sh\tinstant") and has(x, "deferred:size:s-cmdl\tlib/c.sh\tlong"), x.why)
T:arm("3 a non-pre-build test defers by phase even when declared",
    has(x, "deferred:phase:s-post\tlib/d.sh\tinstant") and has(x, "ok:litmus-relay-scope:run=2 deferred=2"), x.why)
x = scope("--paths", "openspec/litmus-tests/f.yaml")
T:arm("4 an edited litmus file selects its own spec", has(x, "run:declared:s-self\topenspec/litmus-tests/f.yaml\tquick"), x.why)
x = scope("--paths", "nothing/covers/this")
T:arm("5 an untouched path is empty, rc 0 and silent", x.out == "ok:litmus-relay-scope:run=0 deferred=0\n" and x.rc == 0 and x.err == "", x.why)

local names = { "kd" }
for i = 1, 17 do names[#names + 1] = string.format("k%02d", i) end
corpus(names)
mk("kd", "kd", "cap-zz", "pre-build", "instant", "lib/k.sh")
for i = 1, 17 do mk(string.format("k%02d", i), string.format("k%02d", i), string.format("cap-%02d", i), "pre-build", "instant", nil, "lib/k.sh") end
x = scope("--paths", "lib/k.sh")
local again, all = scope("--paths", "lib/k.sh"), scope("--all-covering", "--paths", "lib/k.sh")
T:arm("6 cap 15 declared first, --all-covering lifts it, byte-identical reruns", x.out:match("^[^\n]*") == "run:declared:cap-zz\tlib/k.sh\tinstant"
    and has(x, "deferred:cap:cap-16\tlib/k.sh\tinstant") and has(x, "deferred:cap:cap-17\tlib/k.sh\tinstant") and has(x, "ok:litmus-relay-scope:run=15 deferred=3")
    and again.out == x.out and has(all, "ok:litmus-relay-scope:run=18 deferred=0"), x.why .. all.why)

local P1 = { "openspec/litmus-tests/litmus-build-cache-sweep-trigger.yaml", "openspec/litmus-tests/litmus-committable-branch-guard-shape.yaml",
    "openspec/litmus-tests/litmus-plan-only-push-lane-shape.yaml" }
local full = map(true, P1[1], P1[2], P1[3])
x = map(true, "--relay-scope", "--paths", P1[1], P1[2], P1[3])
T:arm("7 CATCH f18dc0d74: the path query answers 0 specs and relay-scope runs meta-orchestration", full.out == "ok:litmus-coverage:0-spec(s)\n"
    and text.contains("\n" .. x.out, "\nrun:declared:meta-orchestration\t") and text.contains(fs.read(P1[1]), L .. "build-cache-sweep-trigger"), full.why .. x.why)
local P2 = "openspec/litmus-tests/groundtruth/expert-groundtruth-rung1.yaml"
full, x = map(true, "--run", P2), map(true, "--relay-scope", "--paths", P2)
T:arm("8 CATCH 562e6281a: the full run and relay-scope both run forge-environment-discoverability",
    text.contains("\n" .. full.out, "\nscripts/run-litmus-test.sh forge-environment-discoverability ")
    and ("\n" .. x.out):find("\nrun:[a-z]*:forge%-environment%-discoverability\t") ~= nil, full.why .. x.why)
T:finish()
