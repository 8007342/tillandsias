-- @trace order:1265-8qr6, order:1176-9vqn
-- @env PATH TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-release-freeze-landing.lua — scripts/release-freeze.sh `land` and the
-- successor-first re-freeze, against a scratch bare origin.
--
-- THE RED (1265-8qr6, measured on pirria-silverblue 2026-09-19): landing the
-- cut's own fix meant clear -> land -> set, and for the whole land
-- `git ls-remote origin 'refs/tillandsias/freeze/<branch>/*'` returned nothing
-- (42 consecutive clear samples across 7m26s). The criterion is that the
-- marker set is NEVER EMPTY across a legitimate land. Sampling ls-remote from
-- outside races the pushes, so the origin itself records: a post-receive hook
-- on the bare repository logs the full marker set after EVERY push, and the
-- assertion reads every intermediate state there was.
--
-- Arms:
--   1 SET       set -> ok:freeze-set; status frozen:
--   2 LAND      land -> ok:freeze-landing:refs/tillandsias/freeze-landing/...;
--               status frozen-landing:<branch>:by=<host> (never ok:freeze-none)
--   3 HOOK      the reader the pre-push hook, land queue and release-preflight
--               share (lib-freeze-paths.sh freeze_markers) sees no freeze during
--               the land, so the landing host's own code push is admitted
--   4 AUDIT     audit during the land -> ok:freeze-landing (not ok:freeze-none)
--   5 REFREEZE  set after the land -> ok:freeze-set, the landing marker gone,
--               status frozen:
--   6 NEVER-EMPTY every state origin passed through from the first set to the
--               re-freeze held at least one marker for the branch
--   7 AGAIN     land twice -> ok:freeze-landing-already, nothing changes
--   8 CLEAR     clear during a land removes it -> ok:freeze-cleared:1, status
--               ok:freeze-none: a freeze that is genuinely over still reads clear
--   9 NOTFROZEN land on an unfrozen branch -> refused:freeze:not-frozen, exit 1,
--               with why and remedy
--  10 CONTROL   the OLD sequence (clear, then set) is caught by the same log:
--               it records an empty state. Without this the never-empty arm
--               could pass on a log that cannot see an empty state.
--
-- Usage: tillandsias-plan script run scripts/lua/test-release-freeze-landing.lua

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.status ~= "exited" or top.code ~= 0 or ROOT == "" then
    verdict.could_not_run("release-freeze-landing", "git rev-parse --show-toplevel did not answer")
end
local REL = "target/plan-scratch/freeze-landing-" .. time.iso_utc() .. "-" .. tostring(math.random(100000, 999999))
fs.mkdir(REL)
local ABS = ROOT .. "/" .. REL
local BR = "linux-next"
local BRP = (BR:gsub("%-", "%%-"))

local failed = {}
local function arm(name, cond, got)
    got = got and tostring(got):gsub("\n", " | ") or nil
    if cond then out.line("ok:   " .. name .. (got and (" — " .. got) or "")) else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got))
        failed[#failed + 1] = name
    end
end

local ENV = {
    PATH = env.get("PATH") or "/usr/bin:/bin",
    HOME = ABS .. "/home",
    GIT_CONFIG_NOSYSTEM = "1",
    GIT_CONFIG_GLOBAL = ABS .. "/home/.gitconfig",
}
fs.mkdir(REL .. "/home")
fs.write(REL .. "/home/.gitconfig", "[user]\n\temail = t@example.invalid\n\tname = fixture\n[init]\n\tdefaultBranch = " .. BR .. "\n")
local function run(argv, cwd)
    local r = proc.run({ argv = argv, cwd = cwd or ABS, env = ENV, timeout_ms = 60000 })
    return r.code or -1, text.trim(r.stdout or ""), text.trim(r.stderr or "")
end

-- origin, with the recorder; a clone holding the scripts under test.
run({ "git", "init", "-q", "--bare", ABS .. "/origin.git" })
local LOG = ABS .. "/states.log"
fs.write(REL .. "/origin.git/hooks/post-receive",
    "#!/bin/sh\n{ printf 'state:'; git for-each-ref --format=' %(refname)' 'refs/tillandsias/'; echo; } | tr -d '\\n' >> '" ..
    LOG .. "'\necho >> '" .. LOG .. "'\n")
run({ "chmod", "+x", ABS .. "/origin.git/hooks/post-receive" })
local C = ABS .. "/coord"
fs.mkdir(REL .. "/coord/scripts")
for _, f in ipairs({ "release-freeze.sh", "lib-freeze-paths.sh" }) do
    fs.write(REL .. "/coord/scripts/" .. f, fs.read("scripts/" .. f))
end
fs.write(REL .. "/coord/drive-markers.sh", '. scripts/lib-freeze-paths.sh; freeze_markers origin "$1"; echo "rc=$?"\n')
fs.write(REL .. "/coord/README", "seed\n")
run({ "git", "init", "-q", "." }, C)
run({ "git", "add", "-A" }, C)
run({ "git", "commit", "-q", "-m", "seed" }, C)
run({ "git", "remote", "add", "origin", ABS .. "/origin.git" }, C)
local prc = run({ "git", "push", "-q", "origin", BR }, C)
if prc ~= 0 then verdict.could_not_run("release-freeze-landing", "could not seed the scratch origin") end

local function rf(...)
    return run({ "bash", "scripts/release-freeze.sh", ... }, C)
end
local function last(s) return (s:match("([^\n]*)$")) or "" end
local function log_states()
    local r = proc.run({ argv = { "cat", LOG }, timeout_ms = 10000 })
    local t = {}
    for l in (r.stdout or ""):gmatch("[^\n]+") do t[#t + 1] = l end
    return t
end
-- Every state since index `from` names a freeze or landing marker for BR.
local function all_nonempty(from)
    local st, bad = log_states(), nil
    for i = from, #st do
        if not st[i]:find("refs/tillandsias/freeze/" .. BR .. "/", 1, true)
            and not st[i]:find("refs/tillandsias/freeze-landing/" .. BR .. "/", 1, true) then
            bad = st[i]; break
        end
    end
    return bad == nil, #st - from + 1, bad
end

-- 9 first, on the unfrozen branch.
local rc, o, e = rf("land", BR)
arm("9 NOTFROZEN land with no freeze is refused, with why and remedy",
    rc == 1 and last(o) == "refused:freeze:not-frozen:" .. BR
    and e:find("why:", 1, true) ~= nil and e:find("remedy:", 1, true) ~= nil, rc .. " " .. o)

local start = #log_states() + 1
rc, o = rf("set", BR, "cut fixture")
local _, st = rf("status", BR)
arm("1 SET the branch is frozen", rc == 0 and last(o):find("^ok:freeze%-set:refs/tillandsias/freeze/") ~= nil
    and st:find("^frozen:" .. BRP .. ":by=") ~= nil, last(o) .. " / " .. st)

rc, o = rf("land", BR)
_, st = rf("status", BR)
arm("2 LAND reads frozen-landing, never ok:freeze-none",
    rc == 0 and last(o):find("^ok:freeze%-landing:refs/tillandsias/freeze%-landing/" .. BRP .. "/") ~= nil
    and st:find("^frozen%-landing:" .. BRP .. ":by=") ~= nil, last(o) .. " / " .. st)

local _, mk = run({ "bash", "drive-markers.sh", BR }, C)
arm("3 HOOK the shared freeze reader sees no freeze during the land (the landing push is admitted)", mk == "rc=0", mk)

rc, o = rf("audit", BR)
arm("4 AUDIT a land in progress is named, not ok:freeze-none",
    rc == 0 and last(o):find("^ok:freeze%-landing:" .. BRP .. ":by=") ~= nil, rc .. " " .. last(o))

rc, o = rf("set", BR)
_, st = rf("status", BR)
local _, lm = run({ "git", "ls-remote", "origin", "refs/tillandsias/freeze-landing/*" }, C)
arm("5 REFREEZE set after the land re-freezes and the landing marker is gone",
    rc == 0 and last(o):find("^ok:freeze%-set:") ~= nil and lm == "" and st:find("^frozen:") ~= nil,
    last(o) .. " / landing=[" .. lm .. "] / " .. st)

local ne, n, bad = all_nonempty(start)
arm("6 NEVER-EMPTY every origin state from set through land to re-freeze held a marker",
    ne and n >= 4, "states=" .. n .. (bad and (" first-empty=[" .. bad .. "]") or ""))

rf("land", BR)
rc, o = rf("land", BR)
arm("7 AGAIN a second land changes nothing", rc == 0 and last(o):find("^ok:freeze%-landing%-already:") ~= nil, last(o))

rc, o = rf("clear", BR)
_, st = rf("status", BR)
local _, any = run({ "git", "ls-remote", "origin", "refs/tillandsias/*" }, C)
arm("8 CLEAR a genuinely-over freeze reads clear: every marker kind removed",
    rc == 0 and last(o) == "ok:freeze-cleared:1" and st == "ok:freeze-none:" .. BR and any == "",
    last(o) .. " / " .. st .. " / left=[" .. any .. "]")

-- 10: the pre-fix sequence, through the same recorder.
rf("set", BR)
local ctl = #log_states() + 1
rf("clear", BR)
rf("set", BR)
local cne = all_nonempty(ctl)
arm("10 CONTROL the old clear-then-set sequence records an empty state", cne == false, "empty-state-seen=" .. tostring(not cne))

proc.run({ argv = { "rm", "-rf", ABS }, timeout_ms = 30000 })
if #failed > 0 then
    verdict.emit("violation:release-freeze-landing:" .. #failed .. "-failed", 1)
end
verdict.ok("release-freeze-landing", "10 arms")
