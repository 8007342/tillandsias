-- @trace order:1247-3e64, order:1247-amcu, order:2375-psb9
-- @env PATH HOME
--
-- test-plan-fragments-lane-affordance.lua — every refused:fragments-to-trunk:* verdict of
-- push-plan-fragments-to-trunk.sh is followed by "  why: ..." and "  remedy: ..." on stderr,
-- its verdict line unchanged, and a hook refusal is reported by its REAL cause.
-- Ported from test-plan-fragments-lane-affordance.sh (2375-psb9); same five arms.
--
-- Hermetic: a bare scratch origin whose linux-next carries a minimal ledger (packets: []),
-- a clone carrying the lane and its two helpers, and a stub pre-push hook (core.hooksPath).
--
--   1  usage                why/remedy (a flag the script does not take)
--   2  not-a-git-checkout   why/remedy (run from a directory in no repository)
--   3  missing              why/remedy; REMEDY EXECUTED (omit the path) -> ok
--   4  push, stale plan binary: the stub hook prints the real hook's plan-only lane
--      "REFUSED ... STALE" line and REMEDY, then the generic "tree changed" line. The
--      verdict MUST name the stale binary (pre-fix it quoted the stamp line, yolanda
--      2026-09-27/28) and the remedy MUST carry the cargo build. REMEDY EXECUTED: the
--      stub's "rebuilt" flag is set -> the same command lands.
--   5  STATIC: every refused:fragments-to-trunk:* echo in the script's CODE (comment lines
--      stripped) is followed within four lines by an _afford call, and there are >= 13
--      such sites (covers sites a scratch origin cannot induce)
--
-- GRAMMAR ok:plan-fragments-lane-affordance:<n> arms
--       | violation:plan-fragments-lane-affordance:<n>-failed
--       | skip:plan-fragments-lane-affordance:lane-absent|no-plan-binary

local fixture = require "common.fixture"
local T = fixture.new("plan-fragments-lane-affordance")
local ROOT, SH = fixture.repo_root(), fixture.posix_shell()
local LANE_REL = "scripts/push-plan-fragments-to-trunk.sh"
if not fs.exists(LANE_REL) then T:skip("lane-absent") end
local PLAN = fixture.plan_binary()
if PLAN == "" then T:skip("no-plan-binary") end
if not fixture.is_abs(PLAN) then PLAN = ROOT .. "/" .. PLAN:gsub("^%./", "") end

local W = T:scratch()
local function has_afford(o) return text.contains(o, "  why: ") and text.contains(o, "  remedy: ") end
local function last_line(o)
    local ls = text.lines(text.trim(o))
    return ls[#ls] or ""
end
local function tail(o, n)
    local ls = text.lines(text.trim(o))
    return table.concat(ls, ";", math.max(1, #ls - n + 1))
end

-- The scratch origin and a working clone.
local ORIGIN, SEED, C = W.abs .. "/origin.git", W.abs .. "/seed", W.abs .. "/work"
T:must{ "git", "init", "-q", "--bare", ORIGIN }
T:must{ "git", "init", "-q", SEED }
T:must{ "git", "-C", SEED, "config", "user.email", "f@x.invalid" }
T:must{ "git", "-C", SEED, "config", "user.name", "f" }
T:must{ "git", "-C", SEED, "config", "commit.gpgsign", "false" }
fs.mkdir(W.rel .. "/seed/plan"); fs.write(W.rel .. "/seed/plan/index.yaml", "packets: []\n")
T:must{ "git", "-C", SEED, "add", "-A" }
T:must{ "git", "-C", SEED, "commit", "-qm", "base" }
T:must{ "git", "-C", SEED, "push", "-q", ORIGIN, "HEAD:refs/heads/linux-next" }
T:must{ "git", "clone", "-q", "-b", "linux-next", ORIGIN, C }
T:must{ "git", "-C", C, "config", "user.email", "f@x.invalid" }
T:must{ "git", "-C", C, "config", "user.name", "f" }
T:must{ "git", "-C", C, "config", "commit.gpgsign", "false" }
fs.mkdir(W.rel .. "/work/scripts"); fs.mkdir(W.rel .. "/work/plan/index.d"); fs.mkdir(W.rel .. "/hooks")
for _, s in ipairs{ "push-plan-fragments-to-trunk.sh", "plan-binary-probe.sh", "agent-identity.sh" } do
    fs.write(W.rel .. "/work/scripts/" .. s, fs.read("scripts/" .. s))
end
-- fs.write drops the exec bit `cp` kept, and the lane runs agent-identity.sh only when -x.
T:must{ "chmod", "+x", C .. "/scripts/push-plan-fragments-to-trunk.sh", C .. "/scripts/agent-identity.sh" }
-- The stub hook: refuses like the real hook does for a STALE plan binary until "rebuilt" exists.
fs.write(W.rel .. "/hooks/pre-push", table.concat({
    "#!/bin/sh",
    '[ -f "' .. W.abs .. '/rebuilt" ] && exit 0',
    'echo "plan-only lane: REFUSED — the resolved plan binary is STALE (full gate required)"',
    'echo "  REMEDY: cargo build --release -p tillandsias-plan && bash scripts/check-plan-binary-current.sh"',
    'echo ""',
    'echo "✗ pre-push refused: the tree changed since ./build.sh --check last passed"',
    "exit 1", "" }, "\n"))
T:must{ "chmod", "+x", W.abs .. "/hooks/pre-push" }
T:must{ "git", "-C", C, "config", "core.hooksPath", W.abs .. "/hooks" }

-- Run the lane with stdout and stderr interleaved (2>&1), as the .sh did.
local LANE_RUN = 's="$1"; shift; exec "$BASH" "$s" "$@" 2>&1\n'
local function lane(...)
    local spec = { SH, "-s", "--", "scripts/push-plan-fragments-to-trunk.sh", ... }
    spec.cwd = C; spec.stdin = LANE_RUN; spec.timeout_ms = 120000
    spec.env_unset = { "TILLANDSIAS_*" }; spec.env = { TILLANDSIAS_PLAN_BIN = PLAN }
    return T:run(spec).stdout or ""
end
local function frag(name, n)
    fs.write(W.rel .. "/work/plan/index.d/20260928t00000" .. n .. "z-fixture-" .. name .. ".yaml",
        table.concat({ "packets:", "  - packet_id: fixture-" .. name, "    order: 1-" .. name,
            "    status: ready", "    title: fixture " .. name, "" }, "\n"))
end

-- 1 usage
local o1 = lane("--bogus")
T:arm("1 usage carries why/remedy", text.contains(o1, "refused:fragments-to-trunk:usage:--bogus") and has_afford(o1), tail(o1, 3))

-- 2 not-a-git-checkout
fs.mkdir(W.rel .. "/nogit")
local r2 = T:run{ SH, "-s", "--", C .. "/scripts/push-plan-fragments-to-trunk.sh", cwd = W.abs .. "/nogit", stdin = LANE_RUN,
    env_unset = { "TILLANDSIAS_*" }, env = { TILLANDSIAS_PLAN_BIN = PLAN, GIT_CEILING_DIRECTORIES = W.abs } }
local o2 = r2.stdout or ""
T:arm("2 not-a-git-checkout carries why/remedy",
    text.contains(o2, "refused:fragments-to-trunk:not-a-git-checkout") and has_afford(o2), tail(o2, 3))

-- 3 missing, then its remedy (omit the path)
frag("a", 1)
local o3 = lane("plan/index.d/does-not-exist.yaml")
local o3r = lane("--dry-run")
T:arm("3 missing carries why/remedy, and omitting the path clears it",
    text.contains(o3, "refused:fragments-to-trunk:missing:plan/index.d/does-not-exist.yaml") and has_afford(o3)
        and last_line(o3r):find("^ok:fragments%-to%-trunk:dry%-run:.*:1$") ~= nil,
    tail(o3, 2) .. " / remedy: " .. last_line(o3r))

-- 4 push refused for a stale plan binary: the REAL cause, then its remedy run
local o4 = lane()
local v4, rem4 = "", ""
for _, l in ipairs(text.lines(o4)) do
    if l:find("^refused:fragments%-to%-trunk:push:") then v4 = v4 .. l end
    if rem4 == "" and text.contains(l, "  remedy:") then rem4 = l end
end
if text.contains(v4, "resolved plan binary is STALE") and not text.contains(v4, "tree changed")
    and text.contains(o4, "  remedy: cargo build --release -p tillandsias-plan") then
    fs.write(W.rel .. "/rebuilt", "")
    local o4r = lane()
    T:arm("4 a stale-binary refusal names the stale binary and its cargo remedy, and the remedy clears it",
        last_line(o4r):find("^ok:fragments%-on%-trunk:.*:1$") ~= nil, "remedy did not clear it: " .. tail(o4r, 2))
else
    T:arm("4 a stale-binary refusal names the stale binary and its cargo remedy, and the remedy clears it", false,
        "push reason: verdict='" .. (v4 ~= "" and v4 or "none") .. "' remedy-line='" .. rem4 .. "'")
end

-- 5 STATIC: every refusal echo in code is followed by _afford within 4 lines.
local code = {}
for _, l in ipairs(text.lines(fs.read(LANE_REL))) do code[#code + 1] = l:find("^%s*#") and "" or l end
local pending, site, missing, sites = nil, nil, {}, 0
for nr, l in ipairs(code) do
    if text.contains(l, 'echo "refused:fragments-to-trunk:') then
        sites = sites + 1
        pending, site = nr, l   -- as the .sh's awk: a new site replaces a pending one
    elseif pending and text.contains(l, "_afford ") then
        pending = nil
    elseif pending and nr - pending > 4 then
        missing[#missing + 1] = pending .. ": " .. site; pending = nil
    end
end
if pending then missing[#missing + 1] = pending .. ": " .. site end
T:arm("5 all " .. sites .. " refusal sites in code carry _afford", #missing == 0 and sites >= 13,
    "sites=" .. sites .. " without _afford: " .. table.concat(missing, ";"))

T:finish()
