-- @trace order:1266-dh2d, order:2375-psb9
-- @env PATH HOME
--
-- test-plan-fragments-lane-carries-status.lua — the plan-only lane
-- (scripts/push-plan-fragments-to-trunk.sh) must never report ok while dropping a claim's
-- STATUS fragment. Ported from test-plan-fragments-lane-carries-status.sh (2375-psb9); same
-- four arms.
--
-- MEASURED on esmeraldinha 2026-09-19 (793-zumy): trunk gains ANOTHER host's set-field
-- fragment after this branch last merged; the base->HEAD diff sees it as deleted, pairs this
-- branch's near-identical status fragment with it as a RENAME, and --diff-filter=A drops it.
-- The notes, whose text differs, still ride. Regime: a scratch repo with a bare remote; every
-- run is --dry-run (builds and validates the commit, pushes nothing).
--
--   1  default selection CARRIES the status fragment in the rename-collision shape, and the
--      stderr note counts 1 status write
--   2  MUTANT with the pre-fix selection (renames on): the status fragment is dropped and the
--      status-loss guard REFUSES, naming it (teeth; also proves the collision happens here)
--   3  an explicit subset naming only the note is refused as status-loss
--   4  MUTATION ARM: explicit note + status is accepted (the guard does not always refuse)
--
-- GRAMMAR ok:plan-fragments-lane-carries-status:<n> arms
--       | violation:plan-fragments-lane-carries-status:<n>-failed
--       | refused:plan-fragments-lane-carries-status:<reason>

local fixture = require "common.fixture"
local T = fixture.new("plan-fragments-lane-carries-status")
local ROOT, SH = fixture.repo_root(), fixture.posix_shell()
local PLAN = fixture.plan_binary()
if PLAN == "" then T:refuse("no-plan-binary", "build one: cargo build --release -p tillandsias-plan") end
if PLAN:sub(1, 1) ~= "/" then PLAN = ROOT .. "/" .. PLAN:gsub("^%./", "") end
local AGENT = "windows-fixture-claude-20200101t000000z"
local ENV = { TILLANDSIAS_PLAN_BIN = PLAN, TILLANDSIAS_AGENT_ID = AGENT, GIT_TERMINAL_PROMPT = "0" }

local W = T:scratch()
local WC = { rel = W.rel .. "/wc", abs = W.abs .. "/wc" }
-- argv first, then named fields: a vararg before a named field would not expand.
local function with(argv, fields) for k, v in pairs(fields) do argv[k] = v end return argv end
local function G(...) return T:must(with({ "git", "-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false", ... }, { cwd = WC.abs })) end
local function g(...) return T:must(with({ "git", ... }, { cwd = WC.abs })) end
local function plan(...) return T:run(with({ PLAN, "--index", "plan/index.yaml", ... }, { cwd = WC.abs, env = ENV, env_unset = { "TILLANDSIAS_*" } })) end
local function untracked()
    return text.lines(T:run{ "git", "ls-files", "--others", "--exclude-standard", "plan/index.d", cwd = WC.abs }.stdout or "")
end

T:must{ "git", "init", "-q", "--bare", W.abs .. "/bare.git" }
T:must{ "git", "init", "-q", "-b", "linux-next", WC.abs }
g("remote", "add", "origin", W.abs .. "/bare.git")
g("config", "core.autocrlf", "false")
fs.mkdir(WC.rel .. "/scripts"); fs.mkdir(WC.rel .. "/plan/index.d"); fs.mkdir(WC.rel .. "/plan/loop_status.d")
for _, f in ipairs{ "push-plan-fragments-to-trunk.sh", "plan-binary-probe.sh", "agent-identity.sh", "common.sh", "gate-stamp.sh" } do
    if not fs.exists("scripts/" .. f) then T:refuse("scratch-missing", "fixture scratch is missing scripts/" .. f) end
    -- cp, not fs.write: the helper runs agent-identity.sh only when it is executable.
    T:must{ "cp", ROOT .. "/scripts/" .. f, WC.abs .. "/scripts/" .. f }
end
fs.write(WC.rel .. "/plan/index.yaml", [[
packets:
  - packet_id: fixture-packet-one-claimed-by-another-host-on-trunk
    order: 1-aaaa
    status: ready
    kind: enhancement
    priority: p2
    desired_release: v0.5
    pickup_role: windows
    title: fixture packet one
    unscoreable: "fixture packet; not scored"
  - packet_id: fixture-packet-two-claimed-on-this-branch
    order: 2-bbbb
    status: ready
    kind: enhancement
    priority: p2
    desired_release: v0.5
    pickup_role: windows
    title: fixture packet two
    unscoreable: "fixture packet; not scored"
]])
G("add", "-A"); G("commit", "-q", "-m", "base")
g("push", "-q", "-u", "origin", "linux-next")

-- This branch forks here, BEFORE trunk moves.
G("checkout", "-q", "-b", "windows-next")
-- Trunk moves: ANOTHER host claims 1-aaaa with a set-field fragment.
G("checkout", "-q", "linux-next")
plan("set-field", "1-aaaa", "status", "in_progress", "--host", "other-host", "--reason", "claimed elsewhere")
G("add", "plan/index.d"); G("commit", "-q", "-m", "claim(1-aaaa): other-host")
g("push", "-q", "origin", "linux-next")
G("checkout", "-q", "windows-next")

-- This branch claims 2-bbbb: a status fragment and a note, both committed.
plan("set-field", "2-bbbb", "status", "in_progress", "--host", "fixture", "--reason", "claimed here")
local status_frag = untracked()[1] or ""
fs.write(W.rel .. "/note.txt", "fixture note on the claimed row\n")
local ts = text.trim(T:run{ "date", "-u", "+%Y-%m-%dT%H:%M:%SZ" }.stdout or "")
plan("append-event", "2-bbbb", "note", "--summary-file", W.abs .. "/note.txt", "--ts", ts, "--host", "fixture", "--agent", AGENT)
local note_frag = ""
for _, l in ipairs(untracked()) do if l ~= status_frag and l ~= "" then note_frag = l; break end end
G("add", "plan/index.d"); G("commit", "-q", "-m", "claim(2-bbbb): fixture")
g("fetch", "-q", "origin")
if status_frag == "" or note_frag == "" then
    T:refuse("setup-no-fragment", "set-field or append-event wrote no fragment (status=[" .. status_frag .. "] note=[" .. note_frag .. "])")
end

local function lane(script, ...)
    local r = T:run(with({ SH, script, "--dry-run", ... }, { cwd = WC.abs, env = ENV, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 300000 }))
    return r.code, r.stdout or "", r.stderr or ""
end
local function brief(rc, o, e) return "rc=" .. tostring(rc) .. " out=[" .. text.trim(o) .. "] err=[" .. e:gsub("\n", " "):sub(1, 400) .. "]" end
local function has_line(s, pat) for _, l in ipairs(text.lines(s)) do if l:find(pat) then return true end end return false end
local function base(p) return (p:match("[^/]+$")) end

local rc, o, e = lane("scripts/push-plan-fragments-to-trunk.sh")
T:arm("1 the default selection carries the status fragment through the rename collision (2 carried, 1 status write)",
    rc == 0 and has_line(o, "^ok:fragments%-to%-trunk:dry%-run:") and text.contains(e, base(status_frag))
        and text.contains(e, "carrying 2 fragment(s), 1 writing a status field"), brief(rc, o, e))

-- 2: the pre-fix selection, on a copy (the subject is never edited).
local src = fs.read(WC.rel .. "/scripts/push-plan-fragments-to-trunk.sh")
local mutant, n = src:gsub("git diff %-%-no%-renames ", "git diff ")
fs.write(W.rel .. "/mutant.sh", mutant)
if n == 0 then
    T:arm("2 with renames on, the collision drops the status fragment and the new guard refuses, naming it", false,
        "the mutation did not land (0 --no-renames replaced)")
else
    rc, o, e = lane(W.abs .. "/mutant.sh")
    T:arm("2 with renames on, the collision drops the status fragment and the new guard refuses, naming it",
        rc ~= 0 and has_line(o, "^refused:fragments%-to%-trunk:trunk%-fold:status%-loss:fixture%-packet%-two%-claimed%-on%-this%-branch$")
            and text.contains(e, status_frag), brief(rc, o, e))
end

rc, o, e = lane("scripts/push-plan-fragments-to-trunk.sh", note_frag)
T:arm("3 an explicit subset without the status fragment is refused as status-loss",
    rc ~= 0 and has_line(o, "^refused:fragments%-to%-trunk:trunk%-fold:status%-loss:"), brief(rc, o, e))

rc, o, e = lane("scripts/push-plan-fragments-to-trunk.sh", note_frag, status_frag)
T:arm("4 note and status together are accepted (the guard does not always refuse)",
    rc == 0 and has_line(o, "^ok:fragments%-to%-trunk:dry%-run:"), brief(rc, o, e))

T:finish()
