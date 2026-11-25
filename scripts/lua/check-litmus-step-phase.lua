-- @trace order:2349-b3u2, order:2327-ahqf, order:2357-42x9
--
-- check-litmus-step-phase.lua — a litmus STEP declares no `phase:`, and a FILE only one a run selects.
-- run-litmus-test.sh reads a phase from the file's top level only (get_test_phase), so a step's
-- phase is a promise nothing keeps: forge-as-only-runtime had a `phase: pre-build` step in a file
-- with no top-level phase and no pre-build run executed it. Split the file by phase instead.
-- If the runner learns to read a step's phase, this check is the thing to remove.
--
-- A top-level phase is one of the four in openspec/litmus-tests/README.md; anything else (2, 6.5,
-- integration) is selected by no phase run (2357-42x9). None at all is read as runtime.
--
-- A step's keys sit at one indent; a `phase:` deeper down is text of a block scalar.
--
-- Usage: tillandsias-plan script run scripts/lua/check-litmus-step-phase.lua [-- <dir>]
-- Verdict: ok:litmus-step-phase:<n> files | violation:litmus-step-phase:<n>

local DIR = arg[1] or "openspec/litmus-tests"
if not fs.exists(DIR) then
    verdict.emit("refused:litmus-step-phase:no-dir:" .. DIR, 1, "  why: there is no litmus corpus there, so nothing was read\n  remedy: pass the directory that holds the litmus .yaml files")
end
local files = fs.walk(DIR, { suffix = ".yaml" })
table.sort(files)
local hits = {}
local PHASES = { ["pre-build"] = true, ["post-build"] = true, runtime = true, retired = true }
for _, f in ipairs(files) do
    local n, keys = 0, nil
    for l in (fs.read(f):gsub("\r", "") .. "\n"):gmatch("([^\n]*)\n") do
        n = n + 1
        local top = l:match("^phase:%s*(.-)%s*$")
        if top then top = top:gsub("%s+#.*$", ""):gsub("^([\"'])(.*)%1$", "%2") end
        if top and not PHASES[top] then hits[#hits + 1] = f .. ":" .. n .. ": phase: " .. top .. " is selected by no run" end
        if l:match("^critical_path:") then keys = -1
        elseif l:match("^%a") then keys = nil
        elseif keys then
            local dash = l:match("^( *%- +)[%w_]+:")
            -- The first dash sets the indent; a list inside a block scalar is deeper.
            if dash and (keys == -1 or #dash == keys) then keys = #dash end
            local lead, key = l:match("^([ %-]*)([%w_]+):")
            if key == "phase" and #lead == keys then hits[#hits + 1] = f .. ":" .. n .. ": phase: on a step" end
        end
    end
end
if #hits == 0 then verdict.emit("ok:litmus-step-phase:" .. #files .. " files", 0) end
for _, h in ipairs(hits) do out.line("  " .. h) end
verdict.emit("violation:litmus-step-phase:" .. #hits, 1,
    "  why: the runner reads a phase from the top level only, and a phase run selects pre-build, post-build, runtime or retired\n  remedy: give the file one of the four, and split a step that needs another into its own file")
