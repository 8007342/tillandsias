-- @env PATH HOME
-- @trace order:1128-j9fc
--
-- test-plan-binary-probe-usage-population.lua — does the probe-usage guard
-- actually WALK the surfaces it claims to? Ported from
-- scripts/test-plan-binary-probe-usage-population.sh (order 2239-5gb5 pays the
-- carried shell-to-lua item); same four arms and verdict.
--
-- WHY THIS EXISTS. check-plan-binary-probe-usage.sh has been found too narrow
-- three times, each time by a human noticing a file that resolved the binary
-- by hand while the guard was green (751-vega litmus commands, 1060-428m
-- mention-vs-use, 1128-j9fc the gate entry point). An unwalked surface and a
-- clean surface produce the SAME verdict, so this plants a violation on each
-- surface and requires the guard to find it.
--
-- THE .step ARM MATTERS MOST: gate-steps.d/*.step files are shell the gate runs,
-- under scripts/ (already scanned), yet no `find -name '*.sh'` walk matches them.
--
-- Usage: tillandsias-plan script run scripts/lua/test-plan-binary-probe-usage-population.lua
-- Verdict: ok:plan-binary-probe-usage-population:4 | violation:plan-binary-probe-usage-population:<n>-failed

local GUARD = "scripts/check-plan-binary-probe-usage.sh"
local BAD = '#!/usr/bin/env bash\nif [ -x "$R/target/release/tillandsias-plan" ]; then :; fi\n'
local CLEAN = '#!/usr/bin/env bash\n. scripts/plan-binary-probe.sh\nP="$(resolve_plan_binary)"\n'
local fails = 0

local root = text.trim(proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 }).stdout or "")
local BASE = "target/plan-scratch/probe-usage-pop-" .. tostring(time.now_ms())
local n = 0
local function mkroot()
    n = n + 1
    local d = BASE .. "/" .. n
    fs.mkdir(d .. "/scripts/gate-steps.d")
    fs.mkdir(d .. "/openspec/litmus-tests")
    -- the probe must exist: the guard skips it by name
    fs.write(d .. "/scripts/plan-binary-probe.sh", "resolve_plan_binary() { echo /bin/true; }\n")
    return d
end

local function expect(name, want_rc, want_sub, d, extra)
    local argv = { "bash", root .. "/" .. GUARD }
    if extra then argv[#argv + 1] = extra end
    local r = proc.run({ argv = argv, timeout_ms = 120000,
        env = { PATH = env.get("PATH"), HOME = env.get("HOME"), PLAN_PROBE_ROOT = root .. "/" .. d } })
    local o = text.trim((r.stdout or "") .. (r.stderr or ""))
    if r.code == want_rc and o:find(want_sub, 1, true) then
        out.line("ok: " .. name .. " (" .. o .. ")")
    else
        out.line("FAIL: " .. name .. " — wanted rc=" .. want_rc .. " containing '" .. want_sub .. "', got rc=" .. r.code .. ": " .. o)
        fails = fails + 1
    end
end

-- ARM 1 — a hardcoded resolution in a repo-ROOT shell file is REFUSED (1128-j9fc).
local d = mkroot(); fs.write(d .. "/build.sh", BAD)
expect("root-shell-file-is-walked", 1, "violation:plan-binary-probe-usage:1", d)

-- ARM 2 — a hardcoded resolution in a gate-steps.d/*.step is REFUSED.
d = mkroot(); fs.write(d .. "/scripts/gate-steps.d/099-probe.step", BAD)
expect("gate-step-extension-is-walked", 1, "violation:plan-binary-probe-usage:1", d)

-- ARM 3 — NEGATIVE CONTROL: a clean tree passes and the verdict names the entry
-- surface; without it arms 1 and 2 are satisfied by a guard that refuses everything.
d = mkroot(); fs.write(d .. "/build.sh", CLEAN)
expect("clean-tree-passes-and-names-the-entry-surface", 0, "entry=", d)

-- ARM 4 — the SCOPED-CALL SEAM: an explicit positional scan dir keeps the
-- pre-1128 semantics (scripts only).
d = mkroot(); fs.write(d .. "/build.sh", BAD)
expect("explicit-scan-dir-stays-scoped", 0, "entry=0/0", d, "scripts")

proc.run({ argv = { "rm", "-rf", root .. "/" .. BASE }, timeout_ms = 60000 })
if fails == 0 then verdict.emit("ok:plan-binary-probe-usage-population:4", 0) end
verdict.emit("violation:plan-binary-probe-usage-population:" .. fails .. "-failed", 1)
