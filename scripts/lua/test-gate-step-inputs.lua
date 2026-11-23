-- @trace order:2118-tnut, spec:ci-release
-- @env PATH HOME
--
-- test-gate-step-inputs.lua — litmus:gate-step-declared-inputs-are-mutation-proven.
-- Operator 2026-11-20 (landing-pipeline P10 item a): a gate step may declare
-- STEP_INPUTS and is skipped when no changed path intersects them. Every such
-- declaration is a gate-integrity decision, so EVERY declared step is proven
-- here by mutation, through the REAL rule (scripts/change-class.sh may-skip)
-- over a scratch repo:
--   * for each declared input (a class or a path:<glob>) a tree that changes
--     only a path of that input makes the step RUN;
--   * the implicit inputs build.sh adds (the .step, the step's script,
--     build.sh, the selector, the classifier) make it RUN too;
--   * with no recent FULL gate the step RUNS whatever changed (fail closed);
--   * the docs+test tree's verdict is printed for each step (the saving).
-- A structural arm pins that build.sh's loop adds those implicit inputs, so
-- the fixture and the gate cannot drift apart.
--
-- Usage: tillandsias-plan script run scripts/lua/test-gate-step-inputs.lua
-- Verdict: ok:gate-step-inputs:<n> arms | violation:gate-step-inputs:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("gate-step-inputs")

-- The implicit inputs build.sh adds, and the arm that pins them to build.sh.
local build = fs.read("build.sh") or ""
local IMPLICIT_LINE = '_gs_inputs="$STEP_INPUTS path:scripts/gate-steps.d/${_step_file##*/} path:$_step_path path:build.sh path:scripts/change-class.sh path:scripts/gate-stamp.sh"'
T:arm("build.sh's roster loop adds the implicit inputs this fixture models",
    build:find(IMPLICIT_LINE, 1, true) ~= nil, "the loop's _gs_inputs line changed; update both")

-- One concrete path per class, for the class mutations.
local CLASS_PATH = {
    rust = "crates/fixture/src/lib.rs", images = "images/fixture/x", specs = "openspec/fixture.md",
    methodology = "methodology.yaml", ["plan-ledger"] = "plan/index.d/fixture.yaml",
    ["build-scripts"] = "scripts/fixture-x.sh", ci = ".github/fixture.yml",
    docs = "docs/fixture.md", other = "fixture-other.txt",
}
local DOCS_TEST_TREE = { "cheatsheets/fixture/x.md", "scripts/test-fixture-other.sh",
    "scripts/lua/test-fixture-other.lua", "openspec/litmus-tests/litmus-fixture.yaml" }

-- The declared steps.
local steps = {}
for _, f in ipairs(fs.walk("scripts/gate-steps.d", { suffix = ".step" })) do
    local body = fs.read(f) or ""
    local inputs = body:match('\nSTEP_INPUTS="([^"]*)"')
    if inputs then
        local script = body:match('\nSTEP_SCRIPT="([^"]+)"') or body:match('\nSTEP_LUA="([^"]+)"')
        steps[#steps + 1] = { file = f, name = f:match("([^/]+)%.step$"), inputs = inputs, script = script }
    end
end
T:arm("at least one step declares STEP_INPUTS", #steps > 0, "none — the fixture has no subject")

-- The scratch repo: the rule's two scripts, a base commit, origin/linux-next at it.
local R = T:git_repo("rule")
fs.mkdir(R.rel .. "/scripts")
for _, s in ipairs{ "change-class.sh", "gate-stamp.sh" } do
    fs.write(R.rel .. "/scripts/" .. s, fs.read("scripts/" .. s))
end
T:must{ "git", "-C", R.abs, "add", "-A" }
T:must{ "git", "-C", R.abs, "commit", "-q", "-m", "rule" }
T:must{ "git", "-C", R.abs, "update-ref", "refs/remotes/origin/linux-next", "HEAD" }
local MARK = T:scratch("marker")
local MARKER = MARK.abs .. "/last-full"
local function fresh_marker() fs.write(MARK.rel .. "/last-full", tostring(time.now_ms() // 1000) .. "\n") end

local function concrete(glob) return (glob:gsub("%*", "fixture")) end
local function ask(paths, inputs, marker_on)
    T:must{ "git", "-C", R.abs, "checkout", "-q", "-B", "case", "origin/linux-next" }
    for _, p in ipairs(paths) do
        local dir = p:match("^(.*)/[^/]+$")
        if dir then fs.mkdir(R.rel .. "/" .. dir) end
        -- an existing file (the rule's own scripts) gains a comment line, so
        -- the mutation changes its bytes without breaking it
        local old = fs.exists(R.rel .. "/" .. p) and fs.read(R.rel .. "/" .. p) or ""
        fs.write(R.rel .. "/" .. p, old .. "# mutation\n")
    end
    T:must{ "git", "-C", R.abs, "add", "-A" }
    T:must{ "git", "-C", R.abs, "commit", "-q", "--allow-empty", "-m", "case" }
    if marker_on then fresh_marker() else T:run{ "rm", "-f", MARKER } end
    local argv = { "bash", "scripts/change-class.sh", "may-skip", "fixture" }
    for w in inputs:gmatch("%S+") do argv[#argv + 1] = w end
    argv.cwd = R.abs
    argv.env = { PATH = env.get("PATH"), HOME = env.get("HOME"), CHANGE_CLASS_ROOT = R.abs,
        TILLANDSIAS_FULL_GATE_MARKER = MARKER, TILLANDSIAS_CLASS_SELECTOR = "on" }
    local r = T:run(argv)
    return text.trim(r.stdout or ""), r
end

for _, st in ipairs(steps) do
    local all = st.inputs .. " path:scripts/gate-steps.d/" .. st.name .. ".step path:" .. tostring(st.script)
        .. " path:build.sh path:scripts/change-class.sh path:scripts/gate-stamp.sh"
    for w in all:gmatch("%S+") do
        local p = w:match("^path:(.+)$")
        p = p and concrete(p) or CLASS_PATH[w]
        if not p then
            T:arm(st.name .. ": declared input '" .. w .. "' is a known class or a path glob", false, w)
        else
            local v, r = ask({ p }, all, true)
            T:arm(st.name .. ": a change to " .. p .. " (" .. w .. ") makes it run", v == "run",
                v .. " " .. tostring(r.stderr))
        end
    end
    local v = ask(DOCS_TEST_TREE, all, false)
    T:arm(st.name .. ": with no recent FULL gate a docs+test tree runs it (fail closed)", v == "run", v)
    v = ask(DOCS_TEST_TREE, all, true)
    out.line("note:gate-step-inputs:" .. st.name .. ":docs+test-tree:" .. v)
end

-- ORDER 2178-luai: a step that runs on the plan binary also reads what the
-- runtime reads. build.sh adds RUNTIME_LINE's inputs to it; pinned here, and
-- driven through the real rule: a .tillandsias/command-policies.yaml change
-- selects a Lua step. PREMISE first: without the runtime inputs the same
-- change is skipped, so the arm is about the added inputs and nothing else.
local RUNTIME_INPUTS = "path:.tillandsias/command-policies.yaml path:.tillandsias/branch-discipline.yaml path:.gitignore path:methodology/distributed-work.yaml path:VERSION path:flake.nix path:crates/tillandsias-plan/* path:crates/tillandsias-exec/* path:Cargo.lock"
T:arm("build.sh adds the plan runtime's reads to a STEP_LUA step's implicit inputs",
    build:find('_gs_inputs="$_gs_inputs ' .. RUNTIME_INPUTS .. '"', 1, true) ~= nil,
    "the runtime implicit-input line changed; update RUNTIME_INPUTS here too")
local lua_base = "path:docs/fixture-only.md path:scripts/gate-steps.d/fixture.step path:scripts/lua/fixture.lua"
    .. " path:build.sh path:scripts/change-class.sh path:scripts/gate-stamp.sh"
local pv = ask({ ".tillandsias/command-policies.yaml" }, lua_base, true)
T:arm("PREMISE: without the runtime inputs, a command-policies.yaml change would be skipped", pv == "skip", pv)
local lv, lr = ask({ ".tillandsias/command-policies.yaml" }, lua_base .. " " .. RUNTIME_INPUTS, true)
T:arm("a .tillandsias/command-policies.yaml change makes a STEP_LUA step run (2178-luai)", lv == "run",
    lv .. " " .. tostring(lr.stderr))

T:finish()
