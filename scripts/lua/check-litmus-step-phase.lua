-- @trace order:2349-b3u2, order:2327-ahqf
--
-- check-litmus-step-phase.lua — a litmus STEP declares no `phase:`.
-- run-litmus-test.sh reads a phase from the file's top level only (get_test_phase), so a step's
-- phase is a promise nothing keeps: forge-as-only-runtime had a `phase: pre-build` step in a file
-- with no top-level phase and no pre-build run executed it. Split the file by phase instead.
-- If the runner learns to read a step's phase, this check is the thing to remove.
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
for _, f in ipairs(files) do
    local n, keys = 0, nil
    for l in (fs.read(f):gsub("\r", "") .. "\n"):gmatch("([^\n]*)\n") do
        n = n + 1
        if l:match("^critical_path:") then keys = -1
        elseif l:match("^%a") then keys = nil
        elseif keys then
            local dash = l:match("^( *%- +)[%w_]+:")
            -- The first dash sets the indent; a list inside a block scalar is deeper.
            if dash and (keys == -1 or #dash == keys) then keys = #dash end
            local lead, key = l:match("^([ %-]*)([%w_]+):")
            if key == "phase" and #lead == keys then hits[#hits + 1] = f .. ":" .. n end
        end
    end
end
if #hits == 0 then verdict.emit("ok:litmus-step-phase:" .. #files .. " files", 0) end
for _, h in ipairs(hits) do out.line("  " .. h .. ": phase: on a step") end
verdict.emit("violation:litmus-step-phase:" .. #hits, 1,
    "  why: the runner reads a phase from the top level only, so this step runs with its file or not at all\n  remedy: put the step in a litmus file whose top-level phase is the one it needs, or drop the key")
