-- @trace order:1072-b7eq, order:1063-nraf, order:1087-h2z9, order:1384-bqhy, order:2355-ncuh
--
-- test-gate-step-append-no-conflict.lua — two hosts adding a gate step must not conflict.
-- Four conflicts on 2026-09-05 were content-free, but resolving one was a build.sh edit and
-- so a full re-gate. Scratch repositories only. Ported from the .sh (2355-ncuh).
--
--   1 two hosts each adding a .step FILE merge cleanly and both survive
--   2 CONTROL: two appends to one region of one file DO conflict, so arm 1 has teeth
--   3 every .step names its script as a literal, and it exists
--   4 the gate loop refuses a step whose script is missing, rather than skipping it
--   5 no two .step files name the same script: a conflict resolved as "keep both" runs the
--     step twice, and nothing else can see it
--   6 every .step is complete, with exactly one runner: a truncated resolution is still
--     valid shell. 6b STEP_SKIP_EXIT is an integer other than 0 and 1, with a reason:
--     nominating 1 would downgrade every real refusal to a skip
--   7 no two .step files share a numeric prefix: the ordering gap survives
--
-- Verdict: ok:gate-step-append-no-conflict:<n> arms | violation:gate-step-append-no-conflict:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("gate-step-append-no-conflict")

-- Two branches off one baseline, each committing its own write; whether they merge.
local function merges(tag, base, a, b)
    local d = T:git_repo(tag)
    local function git(...)
        local argv = { "git", "-C", d.abs }
        for _, x in ipairs({ ... }) do argv[#argv + 1] = x end
        return T:must(argv)
    end
    local function put(f, msg)
        local dir = f[1]:match("^(.*)/")
        if dir then fs.mkdir(d.rel .. "/" .. dir) end
        fs.write(d.rel .. "/" .. f[1], f[2])
        git("add", "-A"); git("commit", "-qm", msg)
    end
    git("config", "core.autocrlf", "false")
    put(base, "baseline")
    git("checkout", "-q", "-b", "hostA"); put(a, "hostA adds")
    git("checkout", "-q", "main"); git("checkout", "-q", "-b", "hostB"); put(b, "hostB adds")
    local r = T:run{ "git", "-C", d.abs, "merge", "-q", "--no-edit", "hostA" }
    return r.code == 0, d
end
local SD = "scripts/gate-steps.d/"
local merged, d = merges("data", { SD .. "010-existing.step", 'STEP_SCRIPT="scripts/test-existing.sh"\n' },
    { SD .. "060-order-a.step", 'STEP_SCRIPT="scripts/test-a.sh"\n' }, { SD .. "070-order-b.step", 'STEP_SCRIPT="scripts/test-b.sh"\n' })
T:arm("1 two hosts adding .step files merge and both survive", merged and fs.exists(d.rel .. "/" .. SD .. "060-order-a.step")
    and fs.exists(d.rel .. "/" .. SD .. "070-order-b.step"), "merged=" .. tostring(merged))
local function inline(h) return '    _step "existing"\n    _info "existing passed"\n' .. (h and '    _step "' .. h .. '"\n    _info "' .. h .. ' passed"\n' or "") end
merged = merges("inline", { "build.sh", inline() }, { "build.sh", inline("hostA") }, { "build.sh", inline("hostB") })
T:arm("2 CONTROL two inline appends to one region DO conflict", not merged, "they merged: this suite cannot tell the shapes apart")

local nonliteral, missing, incomplete, badskip, scripts, dupes, prefixes, dupnum = {}, {}, {}, {}, {}, {}, {}, {}
local n = 0
local function add(t, s) t[#t + 1] = s end
for _, p in ipairs(fs.list("scripts/gate-steps.d")) do
    local f = tostring(p):match("([^/]+)$")
    if f:find("%.step$") then
        n = n + 1
        local ls, runners, line = {}, 0, nil
        for l in (fs.read(SD .. f) .. "\n"):gmatch("([^\n]*)\n") do
            ls[#ls + 1] = l
            if l:find("^STEP_SCRIPT=") or l:find("^STEP_LUA=") then line = line or l end
            if l:find('^STEP_SCRIPT="..*"$') or l:find('^STEP_LUA="..*"$') then runners = runners + 1 end
        end
        local function field(k) for _, l in ipairs(ls) do if l:find("^" .. k .. '="..*"$') then return true end end end
        if not line or line:find("[$`]") then add(nonliteral, f)
        else
            local path = line:gsub('^STEP_%u+="', ""):gsub('"$', "")
            if not fs.exists(path) then add(missing, f .. ":" .. path) end
            if scripts[path] then add(dupes, path .. " (" .. scripts[path] .. ", " .. f .. ")") end
            scripts[path] = f
        end
        for _, k in ipairs{ "STEP_DESC", "STEP_ERROR", "STEP_OK" } do if not field(k) then add(incomplete, f .. ":" .. k) end end
        if runners ~= 1 then add(incomplete, f .. ":STEP_SCRIPT-or-STEP_LUA(found " .. runners .. ")") end
        for _, l in ipairs(ls) do
            local v = l:match("^STEP_SKIP_EXIT=(.*)$")
            if v then
                v = v:gsub('^"', ""):gsub('"$', "")
                if not v:find("^%d+$") then add(badskip, f .. ":not-an-integer(" .. v .. ")")
                elseif v == "0" or v == "1" then add(badskip, f .. ":reserved(" .. v .. ")") end
                if not field("STEP_SKIP_DESC") then add(badskip, f .. ":no-STEP_SKIP_DESC") end
            end
        end
        local num = f:match("^[^-]*")
        if prefixes[num] then add(dupnum, num .. " (" .. prefixes[num] .. ", " .. f .. ")") end
        prefixes[num] = f
    end
end
if n == 0 then T:refuse("no-steps", "scripts/gate-steps.d holds no .step file") end
local function clean(name, t) T:arm(name, #t == 0, table.concat(t, " ")) end
clean("3 every .step names its script as a literal a grep can find", nonliteral)
clean("3 every .step names a script that exists", missing)
T:arm("4 the loop refuses a .step whose script is missing", fs.read("build.sh"):find("a step that cannot run must refuse, not skip", 1, true),
    "build.sh no longer refuses a missing step script")
clean("5 no two .step files name the same script", dupes)
clean("6 every .step declares STEP_DESC, STEP_ERROR, STEP_OK and exactly one runner, non-empty", incomplete)
clean("6b every STEP_SKIP_EXIT is an integer other than 0 and 1, with a reason", badskip)
clean("7 no two .step files share a numeric prefix", dupnum)
T:finish()
