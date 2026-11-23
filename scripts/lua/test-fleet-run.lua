-- @trace order:2250-44uy
-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN CARGO_TARGET_DIR
--
-- test-fleet-run.lua — fleet-run.lua takes a step NUMBER and a REF and
-- nothing else, and refuses every other shape before extracting or running
-- anything. Arm 6 extracts HEAD and refuses a step number that does not
-- exist, which proves the extract + init + tree-equality path without
-- running a gate (a real one-step run is the record a host pastes).
--
--   1 no args              refused:fleet-run:usage, rc 2
--   2 a non-numeric step   refused:fleet-run:bad-step:12x
--   3 a ref that is a flag refused:fleet-run:bad-ref:-x
--   4 a range              refused:fleet-run:bad-ref:a..b
--   5 shell syntax         refused:fleet-run:bad-ref:$(id)
--   6 HEAD, no such step   refused:fleet-run:no-step:99999 (tree matched)
--
-- GRAMMAR ok:fleet-run-shape:6 | violation:fleet-run-shape:<n>-failed

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.code ~= 0 or ROOT == "" then verdict.could_not_run("fleet-run-shape", "no repo") end
local BIN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") or env.get("TILLANDSIAS_PLAN_BIN") or ""
if BIN == "" then
    local ctd = env.get("CARGO_TARGET_DIR") or ""
    BIN = (ctd ~= "" and ctd or ROOT .. "/target") .. "/release/tillandsias-plan"
end
if BIN:sub(1, 2) == "./" then BIN = ROOT .. "/" .. BIN:sub(3) end
if proc.run({ argv = { "test", "-x", BIN }, timeout_ms = 10000 }).code ~= 0 then
    verdict.could_not_run("fleet-run-shape", "no plan binary at " .. BIN)
end

local failed = {}
local function arm(name, args, want)
    local argv = { BIN, "script", "run", ROOT .. "/scripts/lua/fleet-run.lua", "--" }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local r = proc.run({ argv = argv, cwd = ROOT, timeout_ms = 600000 })
    local o = text.trim(r.stdout or "")
    if r.code == 2 and o == want then out.line("ok:   " .. name)
    else
        out.line("FAIL: " .. name .. " — rc=" .. tostring(r.code) .. " got: " .. o:gsub("\n", " | "))
        failed[#failed + 1] = name
    end
end
arm("1 no args", {}, "refused:fleet-run:usage")
arm("2 non-numeric step", { "12x", "HEAD" }, "refused:fleet-run:bad-step:12x")
arm("3 a ref that is a flag", { "1", "-x" }, "refused:fleet-run:bad-ref:-x")
arm("4 a range", { "1", "a..b" }, "refused:fleet-run:bad-ref:a..b")
arm("5 shell syntax", { "1", "$(id)" }, "refused:fleet-run:bad-ref:$(id)")
arm("6 HEAD extracts, tree matches, no such step", { "99999", "HEAD" }, "refused:fleet-run:no-step:99999")
local head = text.trim(proc.run({ argv = { "git", "rev-parse", "HEAD" }, cwd = ROOT, timeout_ms = 30000 }).stdout or "")
if head ~= "" then proc.run({ argv = { "rm", "-rf", ROOT .. "/target/work/fleet-run/" .. head }, timeout_ms = 60000 }) end

if #failed > 0 then verdict.emit("violation:fleet-run-shape:" .. #failed .. "-failed", 1) end
verdict.ok("fleet-run-shape", "6")
