-- @env PATH HOME
-- @trace order:1034-whsp, order:1948-xbaf, order:2372-snfs, order:2392-9zcp
--
-- test-claims-across-branches.lua — check-claims-across-branches.lua reports a packet a sibling
-- branch holds, and never answers "unclaimed" when it could not look. Ported from the .sh of the
-- same name (2372-snfs). A scratch repository with a diverged osx-next; the plan binary is a stub
-- that answers one status for every ledger.
--
--   1 held by a sibling: reported    2 ready: not refused     3 this host's own claim reflected
--   4 NC another host's label, 5 NC an unattributable one: refused
--   6 the parser takes the greatest ts, 7 and resets per fragment   8 no plan binary: blocked
--   9 a verdict line on every run    10 a packet nobody knows is unknown
--   11 TERM mid-fold leaves no extract, 12 nor does a normal run
--   13 an ancestor sibling holds nothing, 14 in batch too           15 a diverged one does
--   16 an override that fixes its own --index does not blind the fold
--   17 the selector's exit contract: --batch exits 1 held, 0 clean, 2 blind (select-work-batch.sh)
--   11 on msys: a caller deadline cuts a fold (no trap can run there), and the next run sweeps it
--   18 the sweep: a dead owner and an old pid-less extract go; a live owner and a fresh one stay
--
-- 2392-9zcp: the subject is the Lua decider, run by the real plan binary (the runner); the
-- stubs only answer its folds, through TILLANDSIAS_PLAN_BIN.
--
-- Usage: tillandsias-plan script run scripts/lua/test-claims-across-branches.lua
-- Verdict: ok:claims-across-branches:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("claims-across-branches")
local SH, CHECK = fixture.posix_shell(), "scripts/lua/check-claims-across-branches.lua"
local RUNNER = fixture.plan_binary()
if RUNNER == "" then T:refuse("no-plan-binary", "the decider is Lua; build tillandsias-plan to run it") end
local w = T:scratch()
local function exe(path, body)
    fs.write(path, body)
    T:must{ "chmod", "+x", w.abs .. path:sub(#w.rel + 1) }
end
for _, s in ipairs{ "in_progress", "ready" } do
    fs.mkdir(w.rel .. "/" .. s)
    exe(w.rel .. "/" .. s .. "/tillandsias-plan", "#!/bin/sh\necho \"PKT\t" .. s .. "\tsome-packet-name\"\n")
end
fs.mkdir(w.rel .. "/none"); exe(w.rel .. "/none/tillandsias-plan", "#!/bin/sh\nexit 1\n")
local HOLD, FREE, NONE = w.abs .. "/in_progress/tillandsias-plan", w.abs .. "/ready/tillandsias-plan", w.abs .. "/none/tillandsias-plan"

local g = T:git_repo()
local function git(...)
    local a = { "git", "-C", g.abs, "-c", "core.hooksPath=/dev/null", ... }
    return text.trim(T:must(a).stdout or "")
end
fs.mkdir(g.rel .. "/scripts/lua"); fs.mkdir(g.rel .. "/plan/index.d")
for _, f in ipairs{ CHECK, "scripts/plan-binary-probe.sh" } do fs.write(g.rel .. "/" .. f, fs.read(f)) end
fs.write(g.rel .. "/plan/index.yaml", "packets: []\n"); fs.write(g.rel .. "/plan/index.d/README.md", "# keep\n")
git("add", "-A"); git("commit", "-qm", "a sibling's ledger")
local anc = git("rev-parse", "HEAD")
fs.write(g.rel .. "/plan/index.yaml", "packets: []\n# trunk moved on\n")
git("add", "-A"); git("commit", "-qm", "trunk moves on")
git("checkout", "-q", "-b", "osx", anc)
fs.write(g.rel .. "/plan/index.d/claim.yaml", "claim\n")
git("add", "-A"); git("commit", "-qm", "a claim HEAD lacks")
local osx = git("rev-parse", "HEAD")
git("checkout", "-q", "main")
local function sibling(sha) git("update-ref", "refs/remotes/origin/osx-next", sha) end
sibling(osx)

-- The environment is set by a shell, so a label of one space or an unset variable is what it says.
local function check(bin, more, ...)
    local pre = "R='" .. RUNNER .. "'\nunset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE CARGO_TARGET_DIR\n" .. (bin and "export TILLANDSIAS_PLAN_BIN='" .. bin .. "'\n" or "") .. (more or "")
    local a = { SH, "-s", "--", g.abs .. "/" .. CHECK, "--" }
    for _, v in ipairs{ ... } do a[#a + 1] = v end
    if #a == 5 then a[6] = "SOME-PKT"; a[7] = "--no-fetch" end
    local r = proc.run{ argv = a, cwd = g.abs, env = { PATH = env.get("PATH"), HOME = env.get("HOME") }, env_unset = { "TILLANDSIAS_*", "GIT_*", "CARGO_TARGET_DIR" }, timeout_ms = 300000,
        stdin = pre .. 'exec "$R" script run "$@" </dev/null\n' }
    local o = "\n" .. (r.stdout or ""):gsub("\r", "")
    return { rc = r.code, out = o, why = "rc=" .. tostring(r.code) .. o:sub(1, 300) .. (r.stderr or ""):sub(1, 300) }
end
local function says(x, rc, prefix) return x.rc == rc and text.contains(x.out, "\n" .. prefix) end
local x = check(HOLD)
T:arm("1 a sibling holding the packet is reported, exit 1", says(x, 1, "claimed-elsewhere:SOME-PKT:osx-next"), x.why)
local free = check(FREE)
T:arm("2 a packet nobody holds passes", says(free, 0, "ok:cross-branch-claims:"), free.why)
local node = text.trim(T:run{ "hostname", "-s" }.stdout or "")
if node == "" then node = text.trim(T:run{ "uname", "-n" }.stdout or ""):match("^[^.]*") end
local function label(l) return "export TILLANDSIAS_WORKSTATION='" .. node .. "' TILLANDSIAS_XBRANCH_CLAIM_HOST='" .. l .. "'\n" end
x = check(HOLD, label(node))
T:arm("3 this host's own claim is reported as its own, exit 0", says(x, 0, "own-claim-reflected:SOME-PKT:"), node .. " " .. x.why)
x = check(HOLD, label("some-other-host"))
T:arm("4 NC another host's label still refuses", says(x, 1, "claimed-elsewhere:SOME-PKT:"), x.why)
x = check(HOLD, label(" "))
T:arm("5 NC an unattributable claim is not assumed the reader's", x.rc == 1, x.why)

local fn = ("\n" .. fs.read(CHECK):gsub("\r", "")):match("\n(_claim_host_on_branch%(%) {[^\n]*\n.-\n})\n")
if not fn then T:refuse("parser-not-found") end
local function parse(name, a, b)
    fs.mkdir(w.rel .. "/" .. name .. "/plan/index.d")
    fs.write(w.rel .. "/" .. name .. "/plan/index.d/a.yaml", a); fs.write(w.rel .. "/" .. name .. "/plan/index.d/b.yaml", b)
    return text.trim(T:run{ SH, "-s", "--", w.abs .. "/" .. name, cwd = w.abs, env_unset = { "TILLANDSIAS_*" }, stdin = fn .. '\n_claim_host_on_branch "$1" some-packet-name 2>/dev/null\n' }.stdout or "")
end
local function row(key, ts, host) return key .. ":\n  - packet_id: some-packet-name\n    field: status\n    value: in_progress\n    ts: \"" .. ts .. "\"\n    host: " .. host .. "\n" end
local got = parse("tree", row("status", "2026-01-01T00:00:00Z", "older-host"), row("status", "2026-06-01T00:00:00Z", "newer-host"))
T:arm("6 the parser takes the entry with the greatest ts", got == "newer-host", got)
got = parse("tree2", row("packets", "2026-01-01T00:00:00Z", "first-host"), "    field: status\n    ts: \"2027-01-01T00:00:00Z\"\n    host: leaked-host\npackets:\n  - packet_id: unrelated-packet\n")
T:arm("7 its block state resets at each fragment", got == "first-host", got)
-- A PATH with no plan binary on it that still finds git: the native runner spawns git itself.
local GITDIR = (fixture.which("git") or "/usr/bin/git"):gsub("/[^/]*$", "")
x = check(nil, "export PATH=\"$(cygpath -u '" .. GITDIR .. "' 2>/dev/null || echo '" .. GITDIR .. "'):/usr/bin:/bin\" HOME='" .. w.abs .. "'\n")
T:arm("8 no plan binary blocks rather than reporting unclaimed", says(x, 2, "blocked:no-plan-binary"), x.why)
T:arm("9 a run prints a machine-readable verdict line", text.contains(free.out, "\nok:") or text.contains(free.out, "\nblocked:"), free.why)
x = check(NONE, nil, "NO-SUCH-PACKET-1091", "--no-fetch")
T:arm("10 a packet nothing knows is unknown, not ok", says(x, 2, "unknown-packet:"), x.why)

fs.mkdir(w.rel .. "/xtmp"); fs.mkdir(w.rel .. "/block")
exe(w.rel .. "/block/tillandsias-plan", "#!/bin/sh\necho $$ >\"" .. w.abs .. "/block/started\"\nread _ <\"" .. w.abs .. "/block/fifo\"\n")
local function xleft()
    local k = 0
    for _, f in ipairs(fs.list(w.rel .. "/xtmp")) do if f:match("^xbranch%.") then k = k + 1 end end
    return k
end
-- 2392-tv47: a TERM from Git Bash to a native runner is not how anything on Windows ends a decider, and
-- it hard-terminates the runner's MSYS descendants, so no trap can run. On msys arm 11 drives the REAL
-- path, a caller's deadline (tillandsias-exec terminates the job), and the bound is the next run's
-- sweep. The TERM arm stays where it is real, on Unix.
local MSYS = SH ~= "bash"
if MSYS then
    T:must{ SH, "-s", "--", w.abs, stdin = 'mkfifo "$1/block/fifo"\n' }
    local d = proc.run{ argv = { RUNNER, "script", "run", g.abs .. "/" .. CHECK, "--", "SOME-PKT", "--no-fetch" }, cwd = g.abs,
        env = { PATH = env.get("PATH"), HOME = env.get("HOME"), TMPDIR = w.abs .. "/xtmp", TILLANDSIAS_PLAN_BIN = w.abs .. "/block/tillandsias-plan" },
        env_unset = { "TILLANDSIAS_*", "GIT_*", "CARGO_TARGET_DIR" }, timeout_ms = 8000 }
    local residue = xleft()
    -- Measured on doris: residue=0 here, so on the deadline path the fold's trap does run; the sweep is
    -- the bound for the stops where it cannot (SIGKILL, a Git Bash kill, a machine that loses power).
    T:arm("11a PREMISE the deadline cut a live fold", fs.exists(w.rel .. "/block/started") and d.code ~= 0 and d.status == "timed_out",
        "residue=" .. residue .. " rc=" .. tostring(d.code) .. " " .. tostring(d.status))
    local after = check(FREE, "export TMPDIR='" .. w.abs .. "/xtmp'\n")
    T:arm("11b the next run sweeps the extract a deadline-killed run left", xleft() == 0 and says(after, 0, "ok:cross-branch-claims:"), xleft() .. " left; " .. after.why)
else
local r = T:run{ SH, "-s", "--", g.abs, w.abs, CHECK, RUNNER, cwd = g.abs, env_unset = { "TILLANDSIAS_*", "GIT_*", "CARGO_TARGET_DIR" }, timeout_ms = 120000, stdin = [==[
cd "$1" || exit 90
W="$2"; mkfifo "$W/block/fifo" || exit 91
left() { n=0; for f in "$W"/xtmp/xbranch.*; do [ -e "$f" ] && n=$((n + 1)); done; echo "$n"; }
TMPDIR="$W/xtmp" TILLANDSIAS_PLAN_BIN="$W/block/tillandsias-plan" "$4" script run "$3" -- SOME-PKT --no-fetch </dev/null >/dev/null 2>&1 & c=$!
i=0; while [ ! -s "$W/block/started" ] && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
live="$(left)"
kill -TERM "$c" 2>/dev/null
[ ! -s "$W/block/started" ] || kill -TERM "$(cat "$W/block/started")" 2>/dev/null
wait "$c" 2>/dev/null; rc=$?
# The extract belongs to the fold's own shell child, whose trap runs as the blocked stub dies;
# allow the few seconds that takes, never longer.
i=0; while [ "$(left)" != 0 ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
echo "live=$live left=$(left) rc=$rc"
]==] }
got = text.trim(r.stdout or "")
T:arm("11a PREMISE the kill reached a live fold", (tonumber(got:match("live=(%d+)")) or 0) > 0, got .. (r.stderr or ""))
T:arm("11b a run killed mid-fold leaves no extract", got:match("left=(%d+)") == "0" and got:match("rc=(%d+)") ~= "0", got)
end
x = check(FREE, "export TMPDIR='" .. w.abs .. "/xtmp'\n")
local n = 0
for _, f in ipairs(fs.list(w.rel .. "/xtmp")) do
    if f:match("^xbranch%.") then n = n + 1 end
end
T:arm("12 nor does a normal run, which still reads ok", says(x, 0, "ok:cross-branch-claims:") and n == 0, n .. " " .. x.why)

sibling(anc)
x = check(HOLD)
T:arm("13 an ancestor sibling holds nothing HEAD has not folded", says(x, 0, "ok:cross-branch-claims:") and not text.contains(x.out, "\nclaimed-elsewhere:"), x.why)
T:must{ "git", "init", "-q", "--bare", w.abs .. "/origin.git" }
git("remote", "add", "origin", w.abs .. "/origin.git")
git("push", "-q", "origin", "HEAD:refs/heads/linux-next", anc .. ":refs/heads/windows-next", anc .. ":refs/heads/osx-next")
x = check(HOLD, nil, "--batch", "SOME-PKT")
T:arm("14 batch skips an ancestor sibling too", x.rc == 0 and not text.contains(x.out, "\nclaimed-elsewhere:"), x.why)
sibling(osx)
x = check(HOLD)
T:arm("15 a diverged sibling's claim is still reported", says(x, 1, "claimed-elsewhere:SOME-PKT:osx-next"), x.why)
fs.mkdir(w.rel .. "/built/release")
exe(w.rel .. "/built/release/tillandsias-plan", [==[#!/bin/sh
[ "$1" = --index ] && shift 2
[ "$1" = --index ] && { echo "error: unknown subcommand '--index'" >&2; exit 2; }
echo "PKT	in_progress	some-packet-name"
]==])
exe(w.rel .. "/indexed-plan", "#!/bin/sh\nexec \"" .. w.abs .. "/built/release/tillandsias-plan\" --index /scratch/index.yaml \"$@\"\n")
x = check(w.abs .. "/indexed-plan", "export CARGO_TARGET_DIR='" .. w.abs .. "/built'\n")
T:arm("16 an override that fixes its own --index does not blind the fold", says(x, 1, "claimed-elsewhere:SOME-PKT:osx-next"), x.why)

-- 17: the contract select-work-batch.sh branches on, from the real decider: 1 held, with the
-- claimed-elsewhere:<id>:<branch> line its sed reads; 0 clean; 2 when it could not fold.
local ST = "export TILLANDSIAS_XBRANCH_ANCESTOR_SKIP=0\n"
local held, clean = check(HOLD, ST, "--batch", "SOME-PKT"), check(FREE, ST, "--batch", "SOME-PKT")
-- --batch always fetches, so blind it by taking the remote away (its refs go with it).
local blind = check(HOLD, ST .. "git remote remove origin 2>/dev/null\n", "--batch", "SOME-PKT")
T:arm("17a selector contract: held is exit 1 with a claimed-elsewhere:<id>:<branch> line", says(held, 1, "claimed-elsewhere:SOME-PKT:"), held.why)
T:arm("17b selector contract: clean is exit 0", says(clean, 0, "ok:cross-branch-claims:"), clean.why)
T:arm("17c selector contract: a blind fold is exit 2, never 0", says(blind, 2, "blocked:"), blind.why)

-- 18 (2392-tv47): the sweep. Stale is a dead owner pid, or a pid-less name over 60 minutes old. A live
-- owner's extract and a fresh pid-less one are kept (the controls: the sweep must not eat a running fold).
fs.mkdir(w.rel .. "/sweep")
local sw = T:run{ SH, "-s", "--", g.abs, w.abs .. "/sweep", CHECK, RUNNER, FREE, cwd = g.abs, env_unset = { "TILLANDSIAS_*", "GIT_*", "CARGO_TARGET_DIR" }, timeout_ms = 300000, stdin = [==[
cd "$1" || exit 90
S="$2"; sleep 120 & live=$!
mkdir -p "$S/xbranch.999999.dead/plan" "$S/xbranch.OLDLEGACY/plan" "$S/xbranch.NEWLEGACY/plan" "$S/xbranch.$live.live/plan"
touch -d '2 hours ago' "$S/xbranch.OLDLEGACY"
TMPDIR="$S" TILLANDSIAS_PLAN_BIN="$5" "$4" script run "$3" -- SOME-PKT --no-fetch </dev/null >"$S/out" 2>"$S/err"; echo "rc=$?"
for n in 999999.dead OLDLEGACY NEWLEGACY "$live.live"; do [ -d "$S/xbranch.$n" ] && echo "kept:${n#$live.}" || echo "gone:${n#$live.}"; done
grep -o 'swept-stale-extracts:[0-9]*' "$S/err"
kill "$live" 2>/dev/null
]==] }
local so = (sw.stdout or ""):gsub("\r", "")
T:arm("18a a dead owner's extract is swept", text.contains(so, "gone:999999.dead"), so)
T:arm("18b a pid-less extract over an hour old is swept", text.contains(so, "gone:OLDLEGACY"), so)
T:arm("18c CONTROL a live owner's extract is kept", text.contains(so, "kept:live"), so)
T:arm("18d CONTROL a fresh pid-less extract is kept", text.contains(so, "kept:NEWLEGACY"), so)
T:arm("18e the sweep says how many it removed", text.contains(so, "swept-stale-extracts:2"), so)
T:finish()
