-- @trace order:1304-wbb2, order:1570-qutp, order:2387-lrg2, spec:ci-release
--
-- test-litmus-binding-truth.lua — a litmus bound under a block that is not its own `spec:`
-- RUNS and is MISATTRIBUTED (1304-wbb2: 69 such bindings on the live corpus, 2026-09-20).
-- Ported from test-litmus-binding-truth.sh (2387-lrg2); same four arms, in its order.
--
--   1  2a MISATTRIBUTION  declared intended-spec, bound under wrong-spec: refused, both named
--   2  MUTATION of 2a     the cross-check's CONDITION neutralised: arm 1's tree is accepted
--   3  2b INVISIBILITY    bound under no block: refused as unbound (660-ryhn stays true)
--   4  MUTATION of 2b     the unbound CONDITION neutralised: arm 3's tree is accepted
--
-- Each arm builds a REAL git repo: the checks are diff-scoped against a base ref, and a plain
-- tree would skip them and read green while exercising nothing. Mutants are written into this
-- fixture's scratch dir, never into the checkout. The probe's prefix is LOAD-BEARING (the
-- checker greps `<prefix>:<name>` out of the registry) so it is assembled (LIT), never written,
-- as in test-litmus-parse-only-duplicate-key.lua.
--
-- GRAMMAR ok:litmus-binding-truth:<n> arms | violation:litmus-binding-truth:<n>-failed
--       | skip:litmus-binding-truth:no-script-runner

local fixture = require "common.fixture"
local T = fixture.new("litmus-binding-truth")
local ROOT = fixture.repo_root()
local CHECKER_REL = "scripts/lua/check-litmus-bindings.lua"
if not fs.exists(CHECKER_REL) then T:refuse("checker-not-found", CHECKER_REL) end
local PLAN = fixture.plan_binary()
if PLAN == "" then T:skip("no-script-runner") end
if PLAN:sub(1, 1) ~= "/" and not PLAN:match("^%a:[/\\]") then PLAN = ROOT .. "/" .. PLAN:gsub("^%./", "") end
local caps = T:run{ PLAN, "capabilities", timeout_ms = 30000 }
if not ("\n" .. (caps.stdout or "") .. "\n"):find("\nscript\n", 1, true) then T:skip("no-script-runner") end

local LIT = "litmus"
local W = T:scratch()

local function build_tree(leaf, declared)
    local d = W.rel .. "/" .. leaf
    fs.mkdir(d .. "/openspec/litmus-tests")
    fs.write(d .. "/openspec/litmus-tests/litmus-truth-probe.yaml", table.concat({
        "name: " .. LIT .. ":truth-probe", "spec: " .. declared, "phase: pre-build", "severity: low",
        "size: instant", "description: >", "  probe for 1304-wbb2", "critical_path:",
        '  - step: "a step"', '    command: "echo hello"', '    expected_behavior: "hello"',
        "    timeout_ms: 1000", "" }, "\n"))
    fs.write(d .. "/openspec/litmus-bindings.yaml", table.concat({
        "version: '1.0'", "description: fixture registry", "specs:",
        "- spec_id: intended-spec", "  status: active", "  litmus_tests: []", "  coverage_ratio: 0",
        "  last_verified: '2026-09-20'",
        "- spec_id: wrong-spec", "  status: active", "  litmus_tests: []", "  coverage_ratio: 0",
        "  last_verified: '2026-09-20'", "" }, "\n"))
    -- 1356-vv5m: a spec_id needs openspec/specs/<id>/spec.md, or every arm is refused for THAT.
    fs.mkdir(d .. "/openspec/specs/intended-spec"); fs.mkdir(d .. "/openspec/specs/wrong-spec")
    fs.write(d .. "/openspec/specs/intended-spec/spec.md", "# intended-spec\n")
    fs.write(d .. "/openspec/specs/wrong-spec/spec.md", "# wrong-spec\n")
    local abs = W.abs .. "/" .. leaf
    T:must{ "git", "init", "-q", abs }
    T:must{ "git", "-C", abs, "config", "user.email", "fixture@local" }
    T:must{ "git", "-C", abs, "config", "user.name", "fixture" }
    T:must{ "git", "-C", abs, "config", "commit.gpgsign", "false" }
    T:must{ "git", "-C", abs, "add", "-A" }
    T:must{ "git", "-C", abs, "commit", "-qm", "base" }
    return d, abs
end

-- Append the binding to one block, as an uncommitted change.
local function bind_under(d, blk)
    local p = d .. "/openspec/litmus-bindings.yaml"
    local outl, cur = {}, nil
    for _, l in ipairs(text.lines(fs.read(p))) do
        local id = l:match("^%- spec_id: (%S+)")
        if id then cur = id end
        if l == "  litmus_tests: []" and cur == blk then
            outl[#outl + 1] = "  litmus_tests:"; outl[#outl + 1] = "  - " .. LIT .. ":truth-probe"
        else outl[#outl + 1] = l end
    end
    fs.write(p, table.concat(outl, "\n") .. "\n")
end

-- The verdict is the checker's last stdout line.
local function run_checker(abs, checker)
    local r = T:run{ PLAN, "script", "run", checker, cwd = ROOT,
        env = { LITMUS_BINDINGS_ROOT = abs, TILLANDSIAS_LITMUS_BIND_BASE = "HEAD" }, timeout_ms = 60000 }
    local ls = text.lines(text.trim(r.stdout or ""))
    return ls[#ls] or ""
end

-- A mutant of the checker in scratch: one exact line replaced. nil when it did not apply.
local function mutant(name, old, new)
    local src = fs.read(CHECKER_REL)
    local outl, hits = {}, 0
    for _, l in ipairs(text.lines(src)) do
        if l == old then outl[#outl + 1] = new; hits = hits + 1 else outl[#outl + 1] = l end
    end
    if hits == 0 then return nil end
    fs.write(W.rel .. "/" .. name, table.concat(outl, "\n") .. "\n")
    return W.abs .. "/" .. name
end

local CHECKER = ROOT .. "/" .. CHECKER_REL

-- ARM 1 (2a)
local A, Aabs = build_tree("a1", "intended-spec"); bind_under(A, "wrong-spec")
local o = run_checker(Aabs, CHECKER)
T:arm("ARM 1 (2a): a misbound litmus is refused naming the declared spec and the block",
    o:match("^violation:binding%-spec%-mismatch:") ~= nil and text.contains(o, "declared=intended-spec")
        and text.contains(o, "bound-under=wrong-spec"), o)

-- ARM 2 (2a mutation): neutralise the GUARD, not its message.
local M2 = mutant("mutant-no-crosscheck.lua", "    if #misbound > 0 then", "    if false then -- MUTATED-NO-CROSSCHECK")
if not M2 then
    T:arm("ARM 2: the cross-check mutation applies", false, "anchor `    if #misbound > 0 then` reworded")
else
    o = run_checker(Aabs, M2)
    T:arm("ARM 2: removing the cross-check restores acceptance of arm 1's tree",
        o:match("^ok:litmus%-bindings:") ~= nil, o)
end

-- ARM 3 (2b)
local _, Babs = build_tree("a3", "intended-spec")
o = run_checker(Babs, CHECKER)
T:arm("ARM 3 (2b): an unbound litmus is refused as unbound, by name",
    o:match("^violation:unbound%-litmus:") ~= nil and text.contains(o, "truth-probe"), o)

-- ARM 4 (2b mutation): the CONDITION, not the echo.
local M4 = mutant("mutant-no-unbound.lua", "if #unbound > 0 then", "if false then -- MUTATED-NO-UNBOUND")
if not M4 then
    T:arm("ARM 4: the unbound mutation applies", false, "anchor `if #unbound > 0 then` reworded")
else
    o = run_checker(Babs, M4)
    T:arm("ARM 4: removing the unbound check restores acceptance of arm 3's tree",
        o:match("^ok:litmus%-bindings:") ~= nil, o)
end

T:finish()
