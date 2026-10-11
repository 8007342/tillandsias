-- @env TILLANDSIAS_SCRIPT_RUNNER_BIN TILLANDSIAS_PLAN_BIN
-- @trace order:933-4gm8, order:1585-hb8w
--
-- check-litmus-yaml-parses.lua — PORTED from check-litmus-yaml-parses.sh
-- (carried obligation shell->lua, 1585-hb8w). Every litmus definition must load
-- under the sanctioned YAML reader, or the runner's metadata fallbacks silently
-- RE-BUCKET it.
--
-- THE INSTANCE THAT PROVED IT (2026-08-29, lenovinha):
-- litmus-expert-groundtruth-harness.yaml stopped parsing when 888-miiy added a
-- plain-scalar list item containing `: `. Nothing said so; every metadata read
-- fell back to its default and the test sat in the RUNTIME bucket, absent from
-- the pre-build suite, while 249/249 printed green. So this is a GATE, not a
-- lint: one unparseable file is a red build.
--
-- The reader is this runner's own binary (`validate-yaml`), named by
-- TILLANDSIAS_SCRIPT_RUNNER_BIN (build.sh's _run_lua_decider and the preflight
-- door set it). Files go in batches, so a Windows command line never meets its
-- length limit; each failing file's own verdict line is printed above the
-- verdict, with its path relative to the checkout (the .sh printed absolute
-- paths; nothing parses these lines).
--
-- Verdict grammar (stdout, last line), unchanged:
--   ok:litmus-yaml-parses:<n>
--   blocked:litmus-yaml-unparseable:<n-broken>
--   skip:litmus-yaml-parses:no-runnable-reader (run scripts/cycle-preflight.sh)

local READER = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN")
if READER == nil or READER == "" then READER = env.get("TILLANDSIAS_PLAN_BIN") end
local probe = (READER ~= nil and READER ~= "") and proc.run({ argv = { READER, "capabilities" } }) or nil
if probe == nil or probe.status ~= "exited" or probe.code ~= 0 then
    -- No reader is its own named state, not a pass and not this gate's red:
    -- cycle-preflight owns building the binary.
    verdict.emit("skip:litmus-yaml-parses:no-runnable-reader (run scripts/cycle-preflight.sh)", 0)
end

local files = {}
for _, f in ipairs(fs.walk("openspec/litmus-tests")) do
    if f:sub(-5) == ".yaml" then files[#files + 1] = f end
end
table.sort(files)

local broken = 0
local BATCH = 100
for i = 1, #files, BATCH do
    local argv = { READER, "validate-yaml" }
    for j = i, math.min(i + BATCH - 1, #files) do argv[#argv + 1] = files[j] end
    local r = proc.run({ argv = argv, timeout_ms = 300000 })
    local seen = 0
    for _, l in ipairs(text.lines((r.stdout or "") .. "\n" .. (r.stderr or ""))) do
        if l:sub(1, 13) == "ok:yaml-loads" then
            seen = seen + 1
        elseif l ~= "" then
            out.line(l)
            if l:sub(1, 8) == "blocked:" then
                broken = broken + 1
                seen = seen + 1
            end
        end
    end
    -- Every file in the batch must have answered one way or the other: a
    -- reader that stopped early would otherwise read as fewer files checked.
    local want = math.min(i + BATCH - 1, #files) - i + 1
    if seen ~= want then
        broken = broken + (want - seen)
        out.line("blocked:yaml-load-unanswered:" .. (want - seen) .. " file(s) in a batch starting at " .. files[i])
    end
end

if broken ~= 0 then
    verdict.emit("blocked:litmus-yaml-unparseable:" .. broken, 1)
end
verdict.emit("ok:litmus-yaml-parses:" .. #files, 0)
