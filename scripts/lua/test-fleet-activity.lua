-- @trace order:1223-wzc4, order:1931-66u5, order:2373-f26m
--
-- test-fleet-activity.lua — scripts/fleet-activity.sh names HOSTS by the address's domain,
-- buckets addresses that name none, and refuses rather than answering when it cannot look.
-- Two worlds on purpose: a scratch repository, and the REAL one, because a hermetic world
-- holds only what its author thought of (the first real run bucketed a live host whose
-- address ends .local). Ported from the .sh (2373-f26m).
--
--   1 the root seam and --ref are honoured: the scratch repo's exactly 4 commits
--   2 a shared provider is an unattributed BUCKET   3 and never a host row
--   4 a .local address that names its host is a HOST row
--   5 an empty window is skipped, not zero hosts    6 an unresolvable ref refuses
--   7 unknown and value-less arguments refuse, and do not hang
--   8 every run disclaims idleness, in a non-empty and an empty window (the words may wrap)
-- The windows are DERIVED from the history read, never a fixed 24 hours: one red on every
-- gate the first day nobody committed. 2 and 4 skip by name where the history has no case.
--
-- Verdict: ok:fleet-activity-fixture | violation:fleet-activity:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("fleet-activity")
local ROOT = fixture.repo_root()
local SH = fixture.posix_shell()
local CHECK = ROOT .. "/scripts/fleet-activity.sh"
if not fs.exists("scripts/fleet-activity.sh") then T:skip("no-check-script") end
local function activity(e, timeout_ms, ...)
    local argv = { SH, CHECK }
    for _, a in ipairs({ ... }) do argv[#argv + 1] = a end
    argv.cwd, argv.env, argv.env_unset, argv.timeout_ms = ROOT, e, { "TILLANDSIAS_*" }, timeout_ms
    local r = T:run(argv)
    return (r.stdout or "") .. (r.stderr or ""), r
end
-- The verdict is the last line of STDOUT; its why is on stderr.
local function last(_, r) return text.trim(r.stdout or ""):match("([^\n]*)$") end
local function ct(...)
    local r = T:run{ "git", "-C", ROOT, "log", "-1", "--format=%ct", ... }
    return tonumber(text.trim(r.stdout or ""))
end
local now = os.time()

local W = T:scratch()
local function git(...)
    local argv = { "git", "-C", W.abs }
    for _, a in ipairs({ ... }) do argv[#argv + 1] = a end
    argv.env_unset = { "GIT_*" }
    return T:must(argv)
end
git("init", "-q"); git("config", "commit.gpgsign", "false")
for i, c in ipairs{ { "tlatoani@alpha.ayahuitlcalpan.com", "plan/index.d/a.yaml" }, { "tlatoani@alpha.ayahuitlcalpan.com", "crates/x.rs" },
    { "tlatoani@Some-MacBook.local", "plan/index.d/b.yaml" }, { "someone@gmail.com", "plan/index.d/c.yaml" } } do
    fs.mkdir(W.rel .. "/" .. c[2]:match("^(.*)/"))
    fs.write(W.rel .. "/" .. c[2], i .. "\n")
    git("add", "-A"); git("-c", "user.email=" .. c[1], "-c", "user.name=x", "commit", "-qm", "c" .. i)
end
local o = activity({ TILLANDSIAS_FLEET_ACTIVITY_ROOT = W.abs }, 20000, "--ref", "HEAD", "--since", "10.years")
T:arm("1 --ref and the root seam are honoured (4 commits)", o:find("ref=HEAD", 1, true) and o:find("commits=4", 1, true), o:sub(1, 300))

-- A one-commit export has no origin/linux-next: the arms over the real history skip by name.
local has_ref = T:run{ "git", "-C", ROOT, "rev-parse", "--verify", "-q", "origin/linux-next^{commit}" }.code == 0
local REAL = has_ref and "origin/linux-next" or "HEAD"
if not has_ref then out.line("note: no origin/linux-next here; arms 2 to 4 skip, 8 reads HEAD") end
local shared = has_ref and ct("--author=@gmail\\.com", "origin/linux-next")
if not has_ref then
    out.line("skip: arms 2 to 4 — no origin/linux-next in this checkout")
elseif not shared then
    out.line("skip: arms 2 to 4 — no shared-provider author anywhere in this checkout's history")
else
    o = activity(nil, 120000, "--since", (now - shared + 3600) .. ".seconds")
    T:arm("2 an address naming no host is an unattributed bucket", o:find("UNATTRIBUTED BUCKET", 1, true), o:sub(1, 300))
    local host_row, neo, neo_bucketed
    for l in o:gmatch("[^\n]+") do
        if l:find("^  [a-z]+ ") and l:find("gmail", 1, true) then host_row = l end
        if l:find("MacBook-Neo", 1, true) then neo = l; if l:find("UNATTRIBUTED", 1, true) then neo_bucketed = l end end
    end
    T:arm("3 no shared-provider address is a host row", o ~= "" and host_row == nil, host_row)
    if neo then T:arm("4 a .local address that names its host is a HOST row", neo_bucketed == nil, neo_bucketed)
    else out.line("skip: arm 4 — no .local author in the arm 2 window") end
end

-- Backdated, so a checkout committed within the second cannot fill the window.
local Q = T:git_repo("quiet")
T:must{ "git", "-C", Q.abs, "commit", "-q", "--amend", "--no-edit", "--date", "2001-01-01T00:00:00Z", env_unset = { "GIT_*" },
    env = { GIT_COMMITTER_DATE = "2001-01-01T00:00:00Z" } }
o = last(activity({ TILLANDSIAS_FLEET_ACTIVITY_ROOT = Q.abs }, 60000, "--ref", "HEAD", "--since", "1.seconds"))
T:arm("5 an empty window is skipped, not zero hosts", o:find("^skipped:fleet%-activity:no%-commits:"), o)
o = last(activity(nil, 60000, "--ref", "refs/heads/no-such-ref-1223"))
T:arm("6 an unresolvable ref refuses", o:find("^fail:fleet%-activity:bad%-ref:"), o)
o = last(activity(nil, 10000, "--no-such-flag"))
T:arm("7 an unknown argument examines nothing", o:find("^fail:fleet%-activity:unknown%-argument:"), o)
for _, flag in ipairs{ "--since", "--ref" } do
    local all, r = activity(nil, 10000, flag)
    T:arm("7 " .. flag .. " with no value refuses and terminates", r.status == "exited" and last(all, r):find("^fail:fleet%-activity:missing%-value:"), tostring(r.status) .. " " .. all)
end
local newest = ct() or now
local why = {}
for _, w in ipairs{ (now - newest + 3600) .. ".seconds", "1.seconds" } do
    local joined = activity(nil, 120000, "--ref", REAL, "--since", w):gsub("%s+", " "):upper()
    if not joined:find("IDLENESS IS ESTABLISHED BY ASKING", 1, true) then why[#why + 1] = w end
end
T:arm("8 every run says absence is not idleness", #why == 0, "not in window " .. table.concat(why, ", "))
T:finish({ ok = function() return "ok:fleet-activity-fixture" end })
