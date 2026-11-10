-- @env TILLANDSIAS_PIN_ENFORCE_BASE TILLANDSIAS_GATE_DIFF_BASE
-- @trace spec:ci-release, order:634-39ik, order:2078-kmbx
--
-- check-litmus-expression-pinning-added.lua: the ENFORCEMENT rung for litmus
-- expression-pinning. PORTED from scripts/check-litmus-expression-pinning-added.sh
-- as the carried shell-to-lua item of 2078-kmbx, with the same rule and the
-- same seam.
--
-- Approved by The Tlatoāni 2026-08-11 under methodology/convergence.yaml ->
-- bar_raise_governance (packet 634-39ik), with the recorded scope: "no NEWLY
-- ADDED litmus step may pin a literal source expression without a negative
-- control". The operator's CRDT/Erlang posture applies: enforcement never halts
-- the line; the existing backlog is accepted standing debt (drained via
-- 624-cf9f).
--
-- DIFF-SCOPED BY CONSTRUCTION. Only litmus step commands ADDED on this branch
-- are examined: `git diff <base>` over openspec/litmus-tests/*.yaml, plus wholly
-- untracked litmus files. The existing corpus is structurally unreachable.
--
-- WHAT IT REFUSES. A newly added `command:` that pins a literal source
-- expression, in a test file that carries no negative control. A pin is a
-- literal grep (`grep ... -<letters>F`) that reads a source FILE directly: it
-- names a .sh/.rs/.ps1/.yml/.yaml/.toml in grep's own arguments and is not fed
-- from a pipe. `./build.sh | grep -F 'text'` reads OUTPUT, so it is no pin.
--
-- EXEMPTION. A negative control in the same test file ("negative control",
-- "NEG-", "negative_control", "must FAIL", "really is present", any case), or
-- asserting behaviour by running the binary and checking its OUTPUT.
--
-- SEAM (git-free, what the litmus dogfoods):
--   script run <this> -- --check-line "<command>" <has_negative:0|1>
--     violation:litmus-expression-pinning-added:pin            exit 1
--     ok:litmus-expression-pinning-added:not-refused           exit 0
-- TREE MODE (no arguments):
--     ok:litmus-expression-pinning-added:added-steps-clean      exit 0
--     violation:litmus-expression-pinning-added:<n>             exit 1
--     skip:litmus-expression-pinning-added:no-base-ref          exit 0
-- The .sh printed `ok: ...` prose and exited 0 or 1. A Lua decider ends on a
-- house prefix, so the lines are tokens now. The exit codes are the .sh's, and
-- they are all the gate reads. A missing base ref was `ok: ... skipped` in the
-- .sh; it is `skip:` here, because nothing was examined.

local NAME = "litmus-expression-pinning-added"
local EXTS = { "sh", "rs", "ps1", "yml", "yaml", "toml" }

-- Each `grep ` occurrence's argument span: up to the next '|' (ERE [^|]*).
local function grep_spans(c)
    local spans, i = {}, 1
    while true do
        local s, e = c:find("grep ", i, true)
        if not s then break end
        local bar = c:find("|", e + 1, true)
        spans[#spans + 1] = c:sub(e + 1, bar and bar - 1 or #c)
        i = e + 1
    end
    return spans
end

local function is_literal_grep(c)
    for _, span in ipairs(grep_spans(c)) do
        if span:find("%-%a*F") then return true end
    end
    return false
end

local function names_source(span)
    for _, ext in ipairs(EXTS) do
        local i = 1
        while true do
            local s, e = span:find("." .. ext, i, true)
            if not s then break end
            local nxt = span:sub(e + 1, e + 1)
            if nxt == "" or not nxt:match("%l") then return true end
            i = e + 1
        end
    end
    return false
end

local function is_pin(c)
    if not is_literal_grep(c) then return false end
    -- piped INTO grep: grep reads a prior command's output, not source
    if c:find("|%s*grep") then return false end
    for _, span in ipairs(grep_spans(c)) do
        if names_source(span) then return true end
    end
    return false
end

local NEG = { "negative control", "neg-", "negative_control", "must fail", "really is present" }
local function has_negative(path)
    local ok, body = pcall(fs.read, path)
    if not ok or not body then return false end
    body = body:lower()
    for _, n in ipairs(NEG) do
        if body:find(n, 1, true) then return true end
    end
    return false
end

local args = arg or {}
if args[1] == "--check-line" then
    local cmd, neg = args[2] or "", args[3] or "0"
    if is_pin(cmd) and neg ~= "1" then
        verdict.emit("violation:" .. NAME .. ":pin", 1, "a literal source pin with no negative control")
    end
    verdict.emit("ok:" .. NAME .. ":not-refused", 0)
end

local function git(argv)
    local full = { "git" }
    for _, a in ipairs(argv) do full[#full + 1] = a end
    return proc.run{ argv = full, timeout_ms = 60000 }
end

-- The live ref is the last resort: the gate's frozen base (1592-idmu) comes
-- first. test-gate-diff-base-frozen.lua counts this site by the spelling below.
local DEFAULT_BASE = "origin/linux-next"
local base = env.get("TILLANDSIAS_PIN_ENFORCE_BASE") or ""
if base == "" then base = env.get("TILLANDSIAS_GATE_DIFF_BASE") or "" end
if base == "" then base = DEFAULT_BASE end
if not git({ "rev-parse", "--verify", "--quiet", base }).ok then
    verdict.emit("skip:" .. NAME .. ":no-base-ref", 0,
        "base ref '" .. base .. "' unavailable: no added steps could be examined")
end

local GLOB = "openspec/litmus-tests/*.yaml"
local found = {}
local function report(f, cmd)
    found[#found + 1] = f
    out.line("REFUSED: " .. f .. " adds a litmus step that pins a literal source expression with no negative control:")
    out.line("   " .. text.trim(cmd):sub(1, 100))
end
local function after_command(line)
    local _, e = line:find("command:", 1, true)
    return e and line:sub(e + 1) or nil
end

-- 1) tracked litmus files changed vs base: only ADDED command lines
local changed = git({ "diff", "--name-only", base, "--", GLOB })
for _, f in ipairs(text.lines(changed.stdout or "")) do
    if f ~= "" and fs.exists(f) and not has_negative(f) then
        local d = git({ "diff", base, "--", f })
        for _, l in ipairs(text.lines(d.stdout or "")) do
            if l:sub(1, 1) == "+" then
                local cmd = after_command(l:sub(2))
                if cmd and is_pin(cmd) then report(f, cmd) end
            end
        end
    end
end

-- 2) wholly untracked litmus files: every command line is "added"
local untracked = git({ "ls-files", "--others", "--exclude-standard", "--", GLOB })
for _, f in ipairs(text.lines(untracked.stdout or "")) do
    if f ~= "" and fs.exists(f) and not has_negative(f) then
        local ok, body = pcall(fs.read, f)
        for _, l in ipairs(text.lines((ok and body) or "")) do
            local cmd = after_command(l)
            if cmd and is_pin(cmd) then report(f, cmd) end
        end
    end
end

if #found > 0 then
    out.line("Expression-pinning enforcement (634-39ik): a NEW litmus step must assert a PROPERTY,")
    out.line("not pin how source is currently written. Fix by asserting the behavior (run the")
    out.line("binary/script and check its OUTPUT) or by adding a negative control to the test.")
    out.line("This check is diff-scoped: it flags ONLY steps added in this change, never the existing corpus.")
    verdict.emit("violation:" .. NAME .. ":" .. #found, 1)
end
verdict.emit("ok:" .. NAME .. ":added-steps-clean", 0)
