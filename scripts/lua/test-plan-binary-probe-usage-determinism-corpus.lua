-- @trace order:1130-qk7d, order:2181-dlcp
-- @env PATH HOME TILLANDSIAS_DETERMINISM_CORPUS_RUNS
--
-- test-plan-binary-probe-usage-determinism-corpus.lua — the BREADTH arm.
-- Ported from the .sh of the same name (order 2181-dlcp); same run count, same
-- outcome.
--
-- --ci-full ONLY, declared in scripts/gate-divergence-declared.txt. Its cheap
-- sibling, test-plan-binary-probe-usage-determinism.sh, runs on every --check
-- against a two-file tree holding the one file known to flake, and pins THAT
-- mechanism (SIGPIPE from `grep -q` killing its upstream writer under
-- pipefail). It is NARROW by construction: it cannot see a non-determinism that
-- only appears at corpus scale, or one carried by a file nobody has identified.
-- This arm runs the guard over the WHOLE repository. About 6.6 s per run on a
-- floor host, which is why it runs once a day on one host and not on every land.
--
-- RUN COUNT BY BINOMIAL. The check misses a flake only if all N runs agree:
-- P(miss) = p^N + (1-p)^N. With the observed pre-fix splits (6/4, 7/3) and the
-- worst lopsidedness p=0.70: N=10 -> 97.2%, N=15 -> 99.5%, N=20 -> 99.9%. 15 is
-- the smallest count clearing 99.5%. p is THIS host's timing, not a constant of
-- the defect: where the race never fires no count detects anything, and this
-- arm is a regression pin against reintroducing the pipeline, not a detector.
--
-- Usage: tillandsias-plan script run scripts/lua/test-plan-binary-probe-usage-determinism-corpus.lua
-- Verdicts:
--   ok:plan-binary-probe-usage-determinism-corpus:1-verdict-over-<N>-runs   exit 0
--   violation:plan-binary-probe-usage-determinism-corpus:<k>-verdicts       exit 1

local NAME = "plan-binary-probe-usage-determinism-corpus"
local RUNS = tonumber(env.get("TILLANDSIAS_DETERMINISM_CORPUS_RUNS") or "") or 15
local E = { PATH = env.get("PATH"), HOME = env.get("HOME") }
local ROOT = text.trim(proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, env = E }).stdout or "")
E.PLAN_PROBE_ROOT = ROOT

local seen, order = {}, {}
local t0 = time.now_ms()
for _ = 1, RUNS do
    local r = proc.run({ argv = { "bash", ROOT .. "/scripts/check-plan-binary-probe-usage.sh" }, env = E, timeout_ms = 600000 })
    for _, l in ipairs(text.lines(r.stdout or "")) do
        if l ~= "" and not seen[l] then seen[l] = true; order[#order + 1] = l end
    end
end
local ms = time.now_ms() - t0
table.sort(order)

if #order == 1 then
    out.line(RUNS .. " runs agree in " .. ms .. "ms: " .. order[1])
    verdict.ok(NAME, "1-verdict-over-" .. RUNS .. "-runs")
end
out.line(RUNS .. " full-corpus runs produced " .. #order .. " distinct verdicts in " .. ms .. "ms:")
for _, v in ipairs(order) do out.line("    " .. v) end
out.line("  This is corpus-scale non-determinism. The cheap --check arm pins only the")
out.line("  1130-qk7d SIGPIPE mechanism on one known file; a split HERE that the cheap")
out.line("  arm did not catch means a different file or a different cause. Identify")
out.line("  which file's eligibility flipped before assuming it is the same defect.")
verdict.emit("violation:" .. NAME .. ":" .. #order .. "-verdicts", 1)
