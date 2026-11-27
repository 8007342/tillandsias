-- @trace order:1375-6pnd, order:2061-cpnt, order:2159-n9sa, order:2386-lrg1
-- @env PATH LITMUS_SELECTION_SPEC
--
-- test-litmus-runner-reads-without-jq.lua — the litmus runner's SELECTION must not depend on
-- which JSON/YAML tools the host has (order 1375-6pnd). Ported from
-- test-litmus-runner-reads-without-jq.sh (2386-lrg1); same arms, same order.
--
-- The same spec (LITMUS_SELECTION_SPEC, default git-mirror-service) runs --select-only twice:
--   A  the host PATH
--   B  a leading PATH dir whose jq, yq AND toolbox are stubs that log their calls and exit 127,
--      and an EMPTY runtime dir (else the runner prepends a cached toolbox yq ahead of PATH)
-- and the selection (the ordered `Executing litmus:<name>` lines plus `Total: N`) must be
-- byte-identical. The executed/skipped split is a runtime outcome, not compared (2061-cpnt).
--
--   split arm    a split-only change compares EQUAL; a changed Total or Executing list DIFFERS
--   control arm  a scratch spec with a quoted/commented phase is selected identically with and
--                without jq/yq (plain+quoted, runtime excluded) — the DISCRIMINATING arm
--   parity arm   --select-only selects what a real run executes, and executes nothing (2159-n9sa)
--   stub arm     the stubs were reached in run B (else refused:...:stub-not-reached)
--   selection    run A == run B, over a non-empty selection (else refused:...:empty-selection)
--
-- GRAMMAR ok:litmus-runner-reads-without-jq:<n> arms | violation:litmus-runner-reads-without-jq:<n>-failed
--       | refused:litmus-runner-reads-without-jq:<stub-not-reached|empty-selection|setup-failed>

local fixture = require "common.fixture"
local T = fixture.new("litmus-runner-reads-without-jq")
local ROOT, SH = fixture.repo_root(), fixture.posix_shell()
local RUNNER = ROOT .. "/scripts/run-litmus-test.sh"
local SPEC = env.get("LITMUS_SELECTION_SPEC")
if not SPEC or SPEC == "" then SPEC = "git-mirror-service" end
local PATH = env.get("PATH") or ""

local S = T:scratch()
T:must{ "mkdir", "-p", S.abs .. "/stubs", S.abs .. "/ctl/tests" }
for _, t in ipairs{ "jq", "yq", "toolbox" } do
    fs.write(S.rel .. "/stubs/" .. t, '#!/bin/sh\necho "$(basename "$0") $*" >> "${LITMUS_STUB_LOG:?}"\nexit 127\n')
    T:must{ "chmod", "+x", S.abs .. "/stubs/" .. t }
end
local STUB_LOG = S.abs .. "/calls.log"
fs.write(S.rel .. "/calls.log", "")

-- <log text> -> the ordered selection, colour stripped
local function selection(log)
    local t = {}
    for l in (log:gsub("\27%[[0-9;]*m", "") .. "\n"):gmatch("([^\n]*)\n") do
        local name = l:match("^ℹ Executing (litmus:.*)$")
        if name then t[#t + 1] = name
        else
            local tot = l:match("^(  Total: %d+) %(executed: %d+, skipped: %d+%)$")
            if tot then t[#t + 1] = tot end
        end
    end
    return table.concat(t, "\n")
end
local function lines_with(sel, pre)
    local t = {}
    for l in (sel .. "\n"):gmatch("([^\n]*)\n") do if l:sub(1, #pre) == pre then t[#t + 1] = l end end
    return t
end

-- split arm: synthetic logs. The names are BUILT (a literal pin token is read as a claim).
local LP = "litmus"
local a = selection("ℹ Executing " .. LP .. ":a\n  Total: 45 (executed: 32, skipped: 13)\n")
local b = selection("ℹ Executing " .. LP .. ":a\n  Total: 45 (executed: 31, skipped: 14)\n")
local n = selection("ℹ Executing " .. LP .. ":a\n  Total: 44 (executed: 31, skipped: 13)\n")
local x = selection("ℹ Executing " .. LP .. ":b\n  Total: 45 (executed: 32, skipped: 13)\n")
T:arm("split arm: a runtime skip is not a selection difference; Total and Executing still are",
    a ~= "" and a == b and a ~= n and a ~= x, "a=[" .. a .. "] b=[" .. b .. "] n=[" .. n .. "] x=[" .. x .. "]")

-- run(label, stubs?, extra env, argv tail...) -> log text
local function runner(stubbed, runtime, extra, ...)
    local e = { LITMUS_STUB_LOG = STUB_LOG }
    if stubbed then e.PATH = S.abs .. "/stubs:" .. PATH end
    if runtime then e.TILLANDSIAS_LITMUS_RUNTIME_DIR = S.abs .. "/runtime-" .. runtime end
    for k, v in pairs(extra or {}) do e[k] = v end
    local spec = { SH, RUNNER, ... }
    spec.env, spec.cwd, spec.timeout_ms = e, ROOT, 900000
    local r = T:run(spec)
    return (r.stdout or "") .. (r.stderr or "")
end
local LIVE = { "--phase", "pre-build", "--size", "instant", "--compact", "--select-only" }
local with_tools = selection(runner(false, nil, nil, SPEC, table.unpack(LIVE)))
local without_tools = selection(runner(true, "without-tools", nil, SPEC, table.unpack(LIVE)))

-- control arm: t-plain (selected either way), t-quoted (a quoted phase and a commented size:
-- a real YAML reader selects it, the awk tier drops it), t-runtime (never selected).
local META = {
    plain = "phase: pre-build\nsize: instant",
    quoted = "phase: \"pre-build\"\nsize: instant  # a comment is valid YAML's business, not part of the value",
    runtime = "phase: runtime\nsize: instant",
}
for _, t in ipairs{ "plain", "quoted", "runtime" } do
    fs.write(S.rel .. "/ctl/tests/litmus-fx6pnd-" .. t .. ".yaml",
        "name: " .. LP .. ":fx6pnd-" .. t .. "\nspec: fx6pnd\n" .. META[t] .. "\n"
        .. "description: 1375-6pnd selection fixture (" .. t .. ")\ncritical_path:\n"
        .. '  - step: "a step that asks no hard question"\n    command: "echo ok"\n'
        .. '    expected_behavior: "ok"\n    timeout_ms: 5000\n')
end
fs.write(S.rel .. "/ctl/bindings.yaml", "specs:\n- spec_id: fx6pnd\n  status: active\n  litmus_tests:\n"
    .. "  - " .. LP .. ":fx6pnd-plain\n  - " .. LP .. ":fx6pnd-quoted\n  - " .. LP .. ":fx6pnd-runtime\n")
local CTL = { TILLANDSIAS_LITMUS_TESTS_DIR = S.abs .. "/ctl/tests", TILLANDSIAS_LITMUS_BINDINGS = S.abs .. "/ctl/bindings.yaml" }
local REAL = { "fx6pnd", "--phase", "pre-build", "--size", "instant", "--compact" }
local ctl_with = selection(runner(false, nil, CTL, table.unpack(REAL)))
local ctl_without = selection(runner(true, "ctl-without-tools", CTL, table.unpack(REAL)))
local want = LP .. ":fx6pnd-plain...\n" .. LP .. ":fx6pnd-quoted..."
local got_with = table.concat(lines_with(ctl_with, "litmus:"), "\n")
T:arm("control arm: a quoted/commented phase is selected identically with and without jq/yq (plain+quoted, runtime excluded)",
    got_with == want and ctl_with == ctl_without,
    got_with ~= want and ("blocked:control-arm-misread — with jq/yq present the runner selected: [" .. got_with .. "]")
        or ("without jq/yq the runner selected a DIFFERENT set: with=[" .. ctl_with .. "] without=[" .. ctl_without .. "]"))

-- parity arm (2159-n9sa): --select-only prints the same selection as the real run, executes nothing.
local SO = { table.unpack(REAL) }; SO[#SO + 1] = "--select-only"
local so_log = runner(false, nil, CTL, table.unpack(SO)):gsub("\27%[[0-9;]*m", "")
local so_sel = selection(so_log)
local executed0 = false
for l in (so_log .. "\n"):gmatch("([^\n]*)\n") do
    if l:find("^  Total: %d+ %(executed: 0, ") then executed0 = true end
end
T:arm("parity arm: --select-only prints the same selection as a real run and executes nothing (2159-n9sa)",
    so_sel == ctl_with and executed0, "real=[" .. ctl_with .. "] select-only=[" .. so_sel .. "] executed0=" .. tostring(executed0))

-- The stubs must have been reached in B, and A must have selected something.
local calls = text.trim(fs.read(S.rel .. "/calls.log"))
if calls == "" then T:refuse("stub-not-reached", "the PATH shadow did not take, so run B proves nothing") end
local nsel = #lines_with(with_tools, "litmus:")
if nsel == 0 then T:refuse("empty-selection", "run A selected no tests, so equality would be vacuous") end
local ncalls = 0
for _ in (calls .. "\n"):gmatch("[^\n]*\n") do ncalls = ncalls + 1 end
T:arm("stub calls in run B: " .. ncalls .. " (jq/yq shadowed, reached)", ncalls > 0, calls)
T:arm("selection=" .. nsel .. " tests, byte-identical with and without jq/yq (1375-6pnd)", with_tools == without_tools,
    "with=[" .. with_tools .. "] without=[" .. without_tools .. "]")

T:finish()
