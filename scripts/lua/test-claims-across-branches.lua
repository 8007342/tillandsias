-- @env PATH HOME
-- @trace order:1034-whsp, order:1948-xbaf, order:2372-snfs
--
-- test-claims-across-branches.lua — check-claims-across-branches.sh reports a packet a sibling
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
--
-- Usage: tillandsias-plan script run scripts/lua/test-claims-across-branches.lua
-- Verdict: ok:claims-across-branches:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("claims-across-branches")
local SH, CHECK = fixture.posix_shell(), "scripts/check-claims-across-branches.sh"
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
fs.mkdir(g.rel .. "/scripts"); fs.mkdir(g.rel .. "/plan/index.d")
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
    local pre = "unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE CARGO_TARGET_DIR\n" .. (bin and "export TILLANDSIAS_PLAN_BIN='" .. bin .. "'\n" or "") .. (more or "")
    local a = { SH, "-s", "--", g.abs .. "/" .. CHECK }
    for _, v in ipairs{ ... } do a[#a + 1] = v end
    if #a == 4 then a[5] = "SOME-PKT"; a[6] = "--no-fetch" end
    local r = proc.run{ argv = a, cwd = g.abs, env = { PATH = env.get("PATH"), HOME = env.get("HOME") }, env_unset = { "TILLANDSIAS_*", "GIT_*", "CARGO_TARGET_DIR" }, timeout_ms = 120000, stdin = pre .. 'exec bash "$@" </dev/null\n' }
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
x = check(nil, "export PATH=/usr/bin:/bin HOME='" .. w.abs .. "'\n")
T:arm("8 no plan binary blocks rather than reporting unclaimed", says(x, 2, "blocked:no-plan-binary"), x.why)
T:arm("9 a run prints a machine-readable verdict line", text.contains(free.out, "\nok:") or text.contains(free.out, "\nblocked:"), free.why)
x = check(NONE, nil, "NO-SUCH-PACKET-1091", "--no-fetch")
T:arm("10 a packet nothing knows is unknown, not ok", says(x, 2, "unknown-packet:"), x.why)

fs.mkdir(w.rel .. "/xtmp"); fs.mkdir(w.rel .. "/block")
exe(w.rel .. "/block/tillandsias-plan", "#!/bin/sh\necho $$ >\"" .. w.abs .. "/block/started\"\nread _ <\"" .. w.abs .. "/block/fifo\"\n")
local r = T:run{ SH, "-s", "--", g.abs, w.abs, CHECK, cwd = g.abs, env_unset = { "TILLANDSIAS_*", "GIT_*", "CARGO_TARGET_DIR" }, timeout_ms = 120000, stdin = [==[
cd "$1" || exit 90
W="$2"; mkfifo "$W/block/fifo" || exit 91
left() { n=0; for f in "$W"/xtmp/xbranch.*; do [ -e "$f" ] && n=$((n + 1)); done; echo "$n"; }
TMPDIR="$W/xtmp" TILLANDSIAS_PLAN_BIN="$W/block/tillandsias-plan" bash "$3" SOME-PKT --no-fetch </dev/null >/dev/null 2>&1 & c=$!
i=0; while [ ! -s "$W/block/started" ] && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
live="$(left)"
kill -TERM "$c" 2>/dev/null
[ ! -s "$W/block/started" ] || kill -TERM "$(cat "$W/block/started")" 2>/dev/null
wait "$c" 2>/dev/null; rc=$?
echo "live=$live left=$(left) rc=$rc"
]==] }
got = text.trim(r.stdout or "")
T:arm("11a PREMISE the kill reached a live fold", (tonumber(got:match("live=(%d+)")) or 0) > 0, got .. (r.stderr or ""))
T:arm("11b a run killed mid-fold leaves no extract", got:match("left=(%d+)") == "0" and got:match("rc=(%d+)") ~= "0", got)
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
T:finish()
