-- @trace order:933-4gm8, order:1588-27v3
-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- check-litmus-yaml-parses.lua — every litmus definition must load under the
-- sanctioned YAML reader, or the runner's metadata fallbacks silently
-- RE-BUCKET it.
--
-- THE INSTANCE THAT PROVED IT (2026-08-29, found by lenovinha validating a
-- conversion batch): litmus-expert-groundtruth-harness.yaml stopped parsing
-- when 888-miiy added a plain-scalar list item containing `: ` — the
-- continuation lines scan as keyless mapping keys. Nothing said so. The file
-- declares `phase: pre-build` and `severity: critical`; with the parse
-- failing, every metadata read fell back to its default and the test sat in
-- the RUNTIME bucket — absent from the pre-build suite the whole time, while
-- 249/249 printed green. A parse failure did not fail anything; it changed
-- which tests run.
--
-- So this is a GATE, not a lint: one unparseable file is a red build. The
-- reader is `tillandsias-plan validate-yaml`, which dispatches ledger-free
-- (746-htj9). Runs from the checkout root; forge-safe (no podman, no vault).
--
-- PORTED from scripts/check-litmus-yaml-parses.sh, verdict for verdict, as
-- 1588-27v3's carried shell-to-lua item. The reader is the binary that runs
-- this script (handed over as TILLANDSIAS_SCRIPT_RUNNER_BIN by build.sh's
-- _run_lua_decider, or TILLANDSIAS_PLAN_BIN when run by hand).
--
-- Verdict grammar (stdout, last line):
--   ok:litmus-yaml-parses:<n>
--   blocked:litmus-yaml-unparseable:<n-broken> (each file's verdict above it)
--   skip:litmus-yaml-parses:no-runnable-reader
--
-- Usage: TILLANDSIAS_PLAN_BIN=<bin> tillandsias-plan script run scripts/lua/check-litmus-yaml-parses.lua
local READER = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") or env.get("TILLANDSIAS_PLAN_BIN") or ""
if READER == "" then
    -- No reader is its own named state, not a pass and not this gate's red.
    verdict.emit("skip:litmus-yaml-parses:no-runnable-reader (set TILLANDSIAS_PLAN_BIN, or run it through build.sh)", 0)
end

local DIR = "openspec/litmus-tests"
local files = {}
for _, p in ipairs(fs.walk(DIR)) do
    if p:match("%.yaml$") then files[#files + 1] = p end
end
table.sort(files)

local broken = 0
for _, f in ipairs(files) do
    local r = proc.run({ argv = { READER, "validate-yaml", f }, timeout_ms = 30000 })
    if not (r.status == "exited" and r.code == 0) then
        out.line(text.trim((r.stdout or "") .. (r.stderr or "")))
        broken = broken + 1
    end
end

if broken ~= 0 then verdict.emit("blocked:litmus-yaml-unparseable:" .. broken, 1) end
verdict.emit("ok:litmus-yaml-parses:" .. #files, 0)
