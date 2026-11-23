-- @env PATH HOME
-- @trace order:2243-urcy
--
-- test-ghost-trace-yaml-anchoring.lua — the ghost-trace gate
-- (scripts/trace-coverage.sh --gate) catches an ANCHORED trace annotation that
-- names a spec which does not exist, and ignores the same words in prose.
-- Ported from scripts/test-ghost-trace-yaml-anchoring.sh (order 2243-urcy pays
-- the carried shell-to-lua item); same five scenarios and verdict line.
--
-- Each scenario writes ONE scratch litmus YAML under openspec/litmus-tests/
-- (the only place the gate reads them), runs the real gate, and removes it.
--
-- Usage: tillandsias-plan script run scripts/lua/test-ghost-trace-yaml-anchoring.lua
-- Verdict: ok:ghost-trace-yaml-anchoring:5/5 | skip:ghost-trace-yaml-anchoring:baseline-red:<rc>
--          | violation:ghost-trace-yaml-anchoring:<n>-failed

local AT = "@" .. "trace"
local FIX = "openspec/litmus-tests/zz-ghost-anchor-fixture-" .. tostring(time.now_ms()) .. ".yaml"
local root = text.trim(proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 }).stdout or "")
local pass, fail = 0, 0

local function gate()
    local r = proc.run({ argv = { "bash", root .. "/scripts/trace-coverage.sh", "--gate" }, timeout_ms = 300000,
        env = { PATH = env.get("PATH"), HOME = env.get("HOME") } })
    return r.code
end
local function cleanup() proc.run({ argv = { "rm", "-f", root .. "/" .. FIX }, timeout_ms = 10000 }) end
local function result(name, want, got)
    if want == got then pass = pass + 1
    else fail = fail + 1; out.line("FAIL: " .. name .. " — expected exit " .. want .. ", got " .. got) end
end

local base = gate()
if base ~= 0 then
    verdict.emit("skip:ghost-trace-yaml-anchoring:baseline-red:" .. base ..
        " (the ghost-trace gate already fails on this tree; the fixture cannot attribute its own result)", 0)
end

fs.write(FIX, "# " .. AT .. " spec:zzz-no-such-spec-anchored-comment\n")
result("anchored comment annotation is caught", 1, gate())

fs.write(FIX, 'observability:\n  traces:\n    - "' .. AT .. ' spec:zzz-no-such-spec-quoted-item"\n')
result("anchored quoted evidence item is caught", 1, gate())

fs.write(FIX, "# some note that mentions " .. AT .. " spec:zzz-prose-mention-not-real inline\n")
result("unanchored prose mention is ignored", 0, gate())

fs.write(FIX, "description: |\n  See the note about " .. AT .. " spec:zzz-block-scalar-not-real for detail.\n")
result("block-scalar prose is ignored", 0, gate())

cleanup()
result("clean tree restores a green gate", 0, gate())

local total = pass + fail
if fail == 0 then
    out.line("PASS: ghost-trace yaml anchoring fixture " .. pass .. "/" .. total ..
        " scenarios green (anchored-comment, anchored-quoted-item, prose-mention-ignored, block-scalar-ignored, clean-tree-restores-green)")
    verdict.emit("ok:ghost-trace-yaml-anchoring:" .. pass .. "/" .. total, 0)
end
verdict.emit("violation:ghost-trace-yaml-anchoring:" .. fail .. "-failed", 1)
