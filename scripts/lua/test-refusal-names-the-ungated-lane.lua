-- @trace order:1177-k4jq, order:872-c9nd, order:1146-8j7i, order:2380-psba
-- @env PATH HOME
--
-- test-refusal-names-the-ungated-lane.lua — the pre-push gate's refusal names the
-- ungated salvage/ lane. Ported from test-refusal-names-the-ungated-lane.sh (2380-psba);
-- same eight arms.
--
-- REGIME: source text only. No arm pushes, creates a remote ref, or runs the hook or the
-- salvage script: the .sh once called `salvage-dirty-worktree.sh --help`, which took
-- --help as the SLUG and pushed a salvage ref per gate run (sixteen strays on origin).
-- The refusal is read as its `echo` lines only: the function body's comments explain the
-- remedy too, and a matcher over the body passed with the echoes deleted.
-- (Not named test-work-ref-accepts-ungated-tree: work/ stays the gated lane by design.)
--
--   1  the refusal names salvage-dirty-worktree.sh
--   2  it says work/ is the GATED lane
--   3  NC1: the refusal gained no exit-0 / skip path
--   4  NC1: the salvage exemption is still scoped to refs/heads/salvage/
--   5  NC2: the salvage lane is offered BEFORE --no-verify (or --no-verify is absent)
--   6  the salvage script covers the clean-but-stranded commit (1146-8j7i)
--   7  the named command exists, is executable, parses, and describes itself
--   8  the meta-orchestration skill carries the same rule (1177-k4jq)
--
-- GRAMMAR ok:refusal-names-the-ungated-lane:<n> arms | violation:refusal-names-the-ungated-lane:<n>-failed
--       | refused:refusal-names-the-ungated-lane:missing | refused:refusal-names-the-ungated-lane:no-refuse-function

local fixture = require "common.fixture"
local T = fixture.new("refusal-names-the-ungated-lane")
local ROOT, SH = fixture.repo_root(), fixture.posix_shell()
local HOOK = "scripts/hooks/pre-push-local-gate.sh"
local SALVAGE = "scripts/salvage-dirty-worktree.sh"
local SKILL = "skills/meta-orchestration/SKILL.md"

for _, f in ipairs({ HOOK, SALVAGE }) do
    if not fs.exists(f) then T:refuse("missing", f) end
end

local hook = fs.read(HOOK)
local salvage = fs.read(SALVAGE)

-- The refusal's echo lines, from `refuse() {` to the first `}` at column 0.
local refusal, inb = {}, false
for l in (hook .. "\n"):gmatch("([^\n]*)\n") do
    if l:match("^refuse%(%) {") then inb = true end
    if inb and l:match("^%s*echo ") then refusal[#refusal + 1] = l end
    if inb and l == "}" then break end
end
if #refusal == 0 then T:refuse("no-refuse-function", HOOK) end
local body = table.concat(refusal, "\n")
local function has(s, needle) return s:find(needle, 1, true) ~= nil end

T:arm("1 the refusal names the ungated hand-off by the command that performs it",
    has(body, "salvage-dirty-worktree.sh"), "refusal never names salvage-dirty-worktree.sh")

local hw, hg = has(body, "work/"), has(body, "GATED") or has(body, "demands the stamp")
T:arm("2 the refusal distinguishes the GATED work/ lane from the ungated salvage one",
    hw and hg, "work:" .. tostring(hw) .. " gated:" .. tostring(hg))

local escape
for _, l in ipairs(refusal) do
    if has(l, "exit 0") or has(l, "return 0") or l:find("TILLANDSIAS_.*SKIP") or l:find("%-%-no%-verify.*exec") then
        escape = l; break
    end
end
T:arm("3 NC1: the refusal still only refuses; it gained a sentence, not an escape", escape == nil, escape)

T:arm("4 NC1: the salvage exemption is still scoped to refs/heads/salvage/ (872-c9nd), not widened",
    has(hook, "refs/heads/salvage/"), "no refs/heads/salvage/ in " .. HOOK)

local nv, sv
for i, l in ipairs(refusal) do
    if not nv and has(l, "no-verify") then nv = i end
    if not sv and has(l, "salvage-dirty-worktree.sh") then sv = i end
end
T:arm("5 NC2: the sanctioned lane is offered BEFORE --no-verify (or --no-verify is not offered)",
    nv == nil or (sv ~= nil and sv < nv), "no-verify:" .. tostring(nv) .. " salvage:" .. tostring(sv))

T:arm("6 the salvage script covers the clean-but-stranded commit (1146-8j7i)",
    has(salvage, "1146-8j7i"), "no 1146-8j7i in " .. SALVAGE)

-- Read, never run: exists, executable, parses (-n), self-describing header.
local x = T:run{ "test", "-x", ROOT .. "/" .. SALVAGE }.code == 0
local parses = T:run{ SH, "-n", ROOT .. "/" .. SALVAGE, cwd = ROOT, timeout_ms = 30000 }.code == 0
local described = false
for l in salvage:gmatch("[^\n]+") do
    if l:match("^#") and (l:find("salvage", 1, true) or l:find("slug", 1, true)) then described = true; break end
end
T:arm("7 the named command exists, parses, and its header describes itself",
    x and parses and described, "x:" .. tostring(x) .. " parses:" .. tostring(parses) .. " described:" .. tostring(described))

T:arm("8 the meta-orchestration skill carries the same rule, so the refusal is not the only place it lives",
    fs.exists(SKILL) and has(fs.read(SKILL), "1177-k4jq"), SKILL .. " lacks 1177-k4jq")

T:finish()
