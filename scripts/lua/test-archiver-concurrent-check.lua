-- @trace order:1132-r4mt, order:1141-vf9w, order:2239-crf7
--
-- test-archiver-concurrent-check.lua — two archiver --check runs in ONE
-- checkout must not break each other. Ported from
-- test-archiver-concurrent-check.sh (2239-crf7).
--
-- THE DEFECT. On Linux the archiver's scratch was $REPO_ROOT itself, so two
-- concurrent `scripts/archive-plan-packets.sh --check` runs shared plan_tmp/,
-- plan_tmp_bak/ and scripts/archive-plan-packets-check.rb, and each run's
-- cleanup deleted them under the other. MEASURED on yoga 2026-09-25 at
-- b862d02f3, 3 pairs out of 3: one run of each pair returned rc=3 or a FALSE
-- rc=1 "Not idempotent", while its partner passed.
--
-- Not hermetic, deliberately: the race lives in the real scratch paths and the
-- real answerability harness. Slow (each pair is two full archiver checks), so
-- it is NOT in the --check gate; local-ci's daily tier runs one pair:
--     tillandsias-plan script run scripts/lua/test-archiver-concurrent-check.lua -- [pairs]   # default 3
-- PASS needs every run of every pair rc=0 and a clean worktree afterwards.
-- The second run of pair t starts t*3-1 seconds after the first (2s, 5s,
-- 8s ...: the offsets that hit on yoga).
--
-- Verdict: ok:archiver-concurrent-check:<pass>/<total>
--        | violation:archiver-concurrent-check:<pass>/<total>:<failures> failure(s)

local root = text.trim(proc.run{ argv = { "pwd", "-P" } }.stdout or "")
local pairs_n = tonumber(arg and arg[1] or "") or 3
local pass, failn = 0, 0
local function pause(sec) proc.run{ argv = { "sleep", tostring(sec) }, timeout_ms = 120000 } end

local function check()
    return proc.spawn{ argv = { root .. "/scripts/archive-plan-packets.sh", "--check" }, cwd = root, timeout_ms = 1800000 }
end

for t = 1, pairs_n do
    local ha = check()
    pause(t * 3 - 1)
    local hb = check()
    local runs = { a = ha:wait(), b = hb:wait() }
    for _, s in ipairs({ "a", "b" }) do
        local r = runs[s]
        if r.status == "exited" and r.code == 0 then
            pass = pass + 1
        else
            failn = failn + 1
            out.line("FAIL: pair " .. t .. " run " .. s .. " rc=" .. tostring(r.code) .. " (" .. tostring(r.status) .. ") — what the archiver said:")
            local shown = 0
            for _, l in ipairs(text.lines((r.stdout or "") .. (r.stderr or ""))) do
                if shown < 6 and (l:find("could-not-run", 1, true) or l:find("Check", 1, true)
                    or l:find("No such", 1, true) or l:find("fail:", 1, true)) then
                    out.line("    " .. l); shown = shown + 1
                end
            end
        end
    end
end

local st = proc.run{ argv = { "git", "status", "--porcelain", "--untracked-files=all", "--",
    "plan_tmp", "plan_tmp_bak", "scripts/archive-plan-packets-check.rb", "toolbox" }, cwd = root, timeout_ms = 60000 }
local dirty = text.trim(st.stdout or "")
if dirty ~= "" then
    failn = failn + 1
    out.line("FAIL: concurrent runs left scratch in the worktree:")
    out.line(dirty)
end

local total = pairs_n * 2
if failn == 0 then verdict.ok("archiver-concurrent-check:" .. pass .. "/" .. total) end
verdict.emit("violation:archiver-concurrent-check:" .. pass .. "/" .. total .. ":" .. failn .. " failure(s)", 1)
