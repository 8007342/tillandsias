-- @trace order:877-mynm, order:863-iicc, order:2400-prg4
-- @env PATH HOME
--
-- test-pre-push-empty-ref-list.lua — pin what an EMPTY pre-push ref list means, and pin
-- that the local gate stops paying a full gate for a push git has already decided not
-- to send. Ported from test-pre-push-empty-ref-list.sh (2400-prg4); same arms, in its order.
--
-- THE FINDING. pre-push-local-gate.sh reported "plan-only lane: not applicable — no ref
-- list on stdin" and then refused with "the tree changed since ./build.sh --check last
-- passed". Both lines were true; the conclusion was wrong. git hands the hook no refs
-- exactly when it is sending no refs, so the remedy was `git pull --rebase`, not a gate.
--
--   1-5  a spy hook in the composed hook's shape (capture stdin once, report its size):
--        ff push and the --dry-run probe carry a list; up-to-date and non-ff with a
--        CURRENT tracking ref are EMPTY; non-ff with a STALE tracking ref is NOT (arm 5,
--        the discriminator: emptiness means "git already knows", not "non-ff")
--   6    the real guard accepts an empty list, names fetch-and-rebase, not the gate
--   7    NEGATIVE CONTROL: a real outgoing ref is still gated
--   8    MUTATION: strip the 877-mynm early accept and the empty list is refused
--   9    BISTABILITY: arm 7's verdict under controlled stamp absence
--
-- AMBIENT STAMP (877-mynm follow-up). Arms 7-9 run the real guard against THIS checkout,
-- deliberately (in a scratch repo it finds no gate machinery and accepts everything). It
-- then reads this checkout's .git/tillandsias-gate-stamp, so the stamp is held aside for
-- those arms and restored on every path, including an error (pcall below).
--
-- HERMETIC AGAINST GLOBAL GIT CONFIG (order 964, unfiled in the ledger): a global core.hooksPath replaces
-- .git/hooks, so the spy would never run; each scratch repo pins its own.
--
-- The guard is run with the gate's env (TILLANDSIAS_* kept, as the .sh's child inherited
-- it); it refuses or accepts on the stamp and the ref list and never re-enters build.sh.
--
-- GRAMMAR ok:pre-push-empty-ref-list:<n> arms | violation:pre-push-empty-ref-list:<n>-failed
--       | refused:pre-push-empty-ref-list:<reason>

local fixture = require "common.fixture"
local T = fixture.new("pre-push-empty-ref-list")
local ROOT, SH = fixture.repo_root(), fixture.posix_shell()
local GUARD_REL = "scripts/hooks/pre-push-local-gate.sh"
if not fs.exists(GUARD_REL) then T:refuse("guard-missing", GUARD_REL) end
local GUARD = ROOT .. "/" .. GUARD_REL
local W = T:scratch()
local GITENV = { GIT_TERMINAL_PROMPT = "0" }
local GITUNSET = { "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_PREFIX" }

local function G(dir, ...)
    local argv = { "git", "-C", dir, "-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false", ... }
    argv.env, argv.env_unset, argv.timeout_ms = GITENV, GITUNSET, 60000
    return T:run(argv)
end
local function Gm(dir, ...)
    local r = G(dir, ...)
    if r.code ~= 0 then T:refuse("setup-failed", "git " .. table.concat({ ... }, " ") .. ": " .. tostring(r.stderr or r.why)) end
    return r
end

local BARE, WC, OTHER = W.abs .. "/bare.git", W.abs .. "/wc", W.abs .. "/other"
T:must{ "git", "init", "-q", "--bare", BARE, env_unset = GITUNSET }
for _, d in ipairs{ WC, OTHER } do
    T:must{ "git", "init", "-q", "-b", "linux-next", d, env_unset = GITUNSET }
    Gm(d, "remote", "add", "origin", BARE)
    Gm(d, "config", "core.hooksPath", d .. "/.git/hooks")
end

local SPY = '#!/usr/bin/env bash\nREFS="$(cat)"\necho "REFBYTES=${#REFS}" >&2\nexit 1\n'
local function install_spy(leaf)
    fs.mkdir(W.rel .. "/" .. leaf .. "/.git/hooks")
    fs.write(W.rel .. "/" .. leaf .. "/.git/hooks/pre-push", SPY)
    T:must{ "chmod", "+x", W.abs .. "/" .. leaf .. "/.git/hooks/pre-push" }
end
-- The REFBYTES the spy printed, or nil when the hook never ran.
local function refbytes(dir, ...)
    local r = G(dir, "push", ...)
    local all = (r.stdout or "") .. "\n" .. (r.stderr or "")
    return tonumber(all:match("REFBYTES=(%d+)"))
end
local function show(b) return b == nil and "<none>" or tostring(b) end

Gm(WC, "commit", "-q", "--allow-empty", "-m", "base")
Gm(WC, "push", "-q", "-u", "origin", "linux-next")
install_spy("wc")

-- 1
Gm(WC, "commit", "-q", "--allow-empty", "-m", "ff")
local b = refbytes(WC, "origin", "linux-next")
T:arm("1 a fast-forward push carries a ref list", b ~= nil and b > 0, show(b))
-- 2
b = refbytes(WC, "--dry-run", "origin", "HEAD")
T:arm("2 the --dry-run origin HEAD probe form carries a ref list", b ~= nil and b > 0, show(b))
-- 3
Gm(WC, "push", "-q", "--no-verify", "origin", "linux-next")
b = refbytes(WC, "origin", "linux-next")
T:arm("3 an up-to-date push yields an EMPTY ref list", b == 0, show(b))
-- 4
Gm(OTHER, "fetch", "-q", "origin"); Gm(OTHER, "reset", "-q", "--hard", "origin/linux-next")
Gm(OTHER, "commit", "-q", "--allow-empty", "-m", "other host"); Gm(OTHER, "push", "-q", "origin", "linux-next")
Gm(WC, "commit", "-q", "--allow-empty", "-m", "mine"); Gm(WC, "fetch", "-q", "origin")
b = refbytes(WC, "origin", "linux-next")
T:arm("4 non-ff with a CURRENT remote-tracking ref yields an EMPTY ref list", b == 0, show(b))
-- 5 (wc has NOT fetched since)
Gm(OTHER, "commit", "-q", "--allow-empty", "-m", "other2"); Gm(OTHER, "push", "-q", "origin", "linux-next")
b = refbytes(WC, "origin", "linux-next")
T:arm("5 non-ff with a STALE remote-tracking ref still carries a ref list", b ~= nil and b > 0, show(b))

local function guard(path, stdin)
    local r = T:run{ SH, path, "origin", BARE, cwd = ROOT, stdin = stdin, env = GITENV, env_unset = GITUNSET, timeout_ms = 120000 }
    return r.code, (r.stdout or "") .. (r.stderr or "")
end

-- 6
local rc, o = guard(GUARD, "")
T:arm("6 the guard exits 0 on an empty ref list", rc == 0, "rc=" .. tostring(rc) .. ": " .. o:sub(1, 300))
T:arm("6 the message names the real remedy (fetch and rebase)", text.contains(o, "fetch and rebase"), o:sub(1, 300))
T:arm("6 no misleading gate remedy on the empty-list path", not text.contains(o, "build.sh --check"), o:sub(1, 300))

-- The ambient stamp, held aside around arms 7-9.
local gd = text.trim(T:must{ "git", "-C", ROOT, "rev-parse", "--absolute-git-dir", env_unset = GITUNSET }.stdout or "")
if gd == "" then T:refuse("no-git-dir", ROOT) end
local STAMP, HELD = gd .. "/tillandsias-gate-stamp", W.abs .. "/ambient-gate-stamp.held"
local held = false
local function hold()
    if T:run{ "test", "-f", STAMP }.code == 0 then
        T:must{ "cp", "-p", STAMP, HELD }; T:must{ "rm", "-f", STAMP }; held = true
    end
end
local function restore()
    if held then T:run{ "cp", "-p", HELD, STAMP }; held = false end
end

local REF = "refs/heads/x 1111111111111111111111111111111111111111 refs/heads/x 2222222222222222222222222222222222222222\n"
local results = {}
local okp, err = pcall(function()
    hold()
    -- 7
    results.rc7 = guard(GUARD, REF)
    -- 8: the guard with the 877-mynm block cut out
    local cut = T:run{ "awk", '/# ── ORDER 877-mynm: AN EMPTY REF LIST/{skip=1} skip && /^fi$/{skip=0; next} skip{next} {print}', GUARD }
    fs.write(W.rel .. "/pre-877-guard.sh", cut.stdout or "")
    results.cut_differs = (cut.stdout or "") ~= (fs.read(GUARD_REL) or "")
    results.rc8 = guard(W.abs .. "/pre-877-guard.sh", "")
    restore()
    -- 9
    hold()
    results.rc9 = guard(GUARD, REF)
    restore()
end)
restore()
if not okp then T:refuse("arms-7-9-errored", tostring(err)) end

T:arm("7 a non-empty ref list is still gated — no unscoped acceptance", results.rc7 ~= 0, "rc=" .. tostring(results.rc7))
T:arm("8 MUTATION: without the early accept the same empty list is refused — arm 6 has teeth",
    results.cut_differs and results.rc8 ~= 0, "cut-applied=" .. tostring(results.cut_differs) .. " rc=" .. tostring(results.rc8))
T:arm("9 BISTABILITY: arm 7's premise holds under controlled stamp absence", results.rc9 ~= 0, "rc=" .. tostring(results.rc9))

T:finish()
