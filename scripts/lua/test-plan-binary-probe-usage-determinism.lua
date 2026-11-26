-- @env PATH HOME TILLANDSIAS_DETERMINISM_RUNS
-- @trace order:1130-qk7d, order:2412-ewmt
--
-- test-plan-binary-probe-usage-determinism.lua — does the probe-usage guard give the SAME answer
-- twice? Ported from the .sh of the same name (2412-ewmt); its breadth sibling is
-- test-plan-binary-probe-usage-determinism-corpus.lua (--ci-full only).
--
-- WHY. On 2026-09-12 check-plan-binary-probe-usage.sh returned a different verdict on an
-- unchanged tree between consecutive runs: 10 runs split 7/3, and exactly one file flipped, the
-- largest. THE CAUSE, kept so nobody "simplifies" the fix away: the eligibility test was
-- `printf | grep -v | grep -q`; grep -q exits on its first match and SIGPIPEs the writer, and under
-- pipefail `if !` read the 141 as "no match". Determinism is not observable from one run.
--
--   1 DETECTOR  N runs over a MINIMAL tree holding the REAL file that flaked, and nothing else, give
--               exactly one verdict. Measured on yoga 2026-09-12 with that file verbatim: pre-fix
--               20 runs -> 13x scripts=0/2 and 7x scripts=1/2; post-fix 20x scripts=1/2, 7 ms/run.
--               A SYNTHETIC stand-in of the same size did NOT reproduce the flake: use the real
--               file. Its absence is a failure, never a pass on an empty tree.
--   2 CONTROL   a planted violation is refused N/N. NOT a pin for this defect: the pre-fix guard
--               refused it 20/20 too. It is here because arm 1 alone is satisfied by a guard that
--               is reliably wrong (refuses everything, walks nothing).
--
-- Usage: tillandsias-plan script run scripts/lua/test-plan-binary-probe-usage-determinism.lua
-- Verdict: ok:plan-binary-probe-usage-determinism:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("plan-binary-probe-usage-determinism")
local SH, ROOT = fixture.posix_shell(), fixture.repo_root()
local GUARD = ROOT .. "/scripts/check-plan-binary-probe-usage.sh"
local RUNS = tonumber(env.get("TILLANDSIAS_DETERMINISM_RUNS") or "") or 20
local SUBJECT = "scripts/test-fragment-status-loss.sh"
local PROBE = "resolve_plan_binary() { echo /bin/true; }\n"

local function tree(subject_body)
    local d = T:scratch()
    fs.mkdir(d.rel .. "/scripts/gate-steps.d"); fs.mkdir(d.rel .. "/openspec/litmus-tests")
    fs.write(d.rel .. "/scripts/plan-binary-probe.sh", PROBE)
    if subject_body then fs.write(d.rel .. "/" .. SUBJECT, subject_body) end
    return d
end
local function guard(d)
    return T:run{ SH, GUARD, env = { PLAN_PROBE_ROOT = d.abs }, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 60000, refusal_ok = true }
end

if not fs.exists(SUBJECT) then
    T:arm("1 the real flaking file is present (this arm has no subject without it)", false, SUBJECT .. " is absent")
else
    local d = tree(fs.read(SUBJECT))
    local seen, order, t0 = {}, {}, time.now_ms()
    for _ = 1, RUNS do
        local v = text.trim(guard(d).stdout or "")
        if not seen[v] then seen[v] = true; order[#order + 1] = v end
    end
    T:arm("1 " .. RUNS .. " runs over the real file agree (" .. (time.now_ms() - t0) .. " ms)", #order == 1, #order .. " verdicts: " .. table.concat(order, " | "))
end

local pad = { "#!/usr/bin/env bash\n", 'if [ -x "$R/target/release/tillandsias-plan" ]; then :; fi\n' }
for _ = 1, 400 do pad[#pad + 1] = "# padding to outlast the reader, see 1130-qk7d\n" end
local p = tree(table.concat(pad))
local misses = 0
for _ = 1, RUNS do if guard(p).code == 0 then misses = misses + 1 end end
T:arm("2 a planted violation is refused " .. RUNS .. "/" .. RUNS, misses == 0, "missed on " .. misses .. " runs (the 1130-qk7d symptom)")
T:finish()
