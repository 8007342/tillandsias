-- @trace order:1310-rec6, spec:git-mirror-service
-- @env TILLANDSIAS_GIT_IMAGE
-- inputs: scripts/lua/test-mirror-healthcheck-quiet.lua images/git/healthcheck.sh VERSION lib/lua/common/ crates/tillandsias-plan/
--
-- test-mirror-healthcheck-quiet.lua — the git mirror's HEALTHCHECK must not
-- make git-daemon log a fatal line, and must still fail when git is not served.
-- Ported from the .sh (2274-i758); the in-container payload
-- stays POSIX sh: it runs inside the tillandsias-git image, where only sh is.
--
-- MEASURED on lenovinha 2026-09-29: 23,209 `fatal: the remote end hung up
-- unexpectedly` lines in one tillandsias-git container log, EVERY one directly
-- after a `Connection from 127.0.0.1` made by the 2 s `nc -w 1 127.0.0.1 9418`
-- healthcheck, NONE from a relay. A healthy mirror's log could not be told from
-- a failing one (1310-rec6 step 1: separate noise from failure first).
--
-- Runs INSIDE the tillandsias-git image (the only place git-daemon exists on
-- these hosts) against a scratch bare repository and a verbose daemon in the
-- container's own network namespace. Skips by name without podman or the image.
--
-- A probe that CONNECTS always writes to the daemon log, and even a real git
-- request leaves the fatal on ~1-3% of runs (measured, v0 and v2). The probe
-- checks the LISTEN socket in /proc/net/tcp and never connects.
--
-- Arms (inside the container):
--   1 OLD      (negative control) 5 bare-TCP probes produce 5 hung-up fatals,
--              so the measurement can see the noise at all
--   2 NEW      20 runs of images/git/healthcheck.sh exit 0 and add NO line at
--              all to the daemon log (not even `Connection from`)
--   3 LIVENESS with the daemon stopped the probe FAILS: still a real check
--
-- Verdict: ok:mirror-healthcheck-quiet:<n> | violation:…:<n> | skip:…:<reason>

local fixture = require "common.fixture"
local T = fixture.new("mirror-healthcheck-quiet")

local function run(argv, ms) return proc.run{ argv = argv, timeout_ms = ms or 60000 } end

if not run({ "podman", "--version" }, 30000).ok then
    T:skip("no-podman (named skip, not a pass)")
end

-- A VERSIONED image, never a mutable tag (check-container-bases). The exact
-- VERSION tag may not be built yet on a fresh bump, so fall back to the newest
-- versioned git image: this tests git-daemon's behaviour, not version freshness.
local function vkey(tag) -- "localhost/tillandsias-git:v0.5.2.1" -> comparable parts
    local parts = {}
    for n in (tag:match(":v(.*)$") or ""):gmatch("%d+") do parts[#parts + 1] = tonumber(n) end
    return parts
end
local function vless(a, b)
    local x, y = vkey(a), vkey(b)
    for i = 1, math.max(#x, #y) do
        local p, q = x[i] or -1, y[i] or -1
        if p ~= q then return p < q end
    end
    return a < b
end
local IMAGE = env.get("TILLANDSIAS_GIT_IMAGE")
if not IMAGE or IMAGE == "" then
    IMAGE = "localhost/tillandsias-git:v" .. text.trim(fs.read("VERSION") or "")
end
if not run({ "podman", "image", "exists", IMAGE }, 30000).ok then
    local ls = run({ "podman", "images", "--format", "{{.Repository}}:{{.Tag}}" }, 60000)
    local cands = {}
    for line in ((ls.stdout or "") .. "\n"):gmatch("(.-)\n") do
        if line:match("^localhost/tillandsias%-git:v%d") then cands[#cands + 1] = line end
    end
    table.sort(cands, vless)
    IMAGE = cands[#cands]
end
if not IMAGE or IMAGE == "" then T:skip("no-versioned-git-image (named skip, not a pass)") end

local W = T:scratch("hc")
fs.write(W.rel .. "/healthcheck.sh", fs.read("images/git/healthcheck.sh") or "")
fs.write(W.rel .. "/inner.sh", [[
#!/bin/sh
set -u
export GIT_SERVICE_ROOT=/tmp/srv
mkdir -p "$GIT_SERVICE_ROOT"
git init -q --bare "$GIT_SERVICE_ROOT/proj"
git -C "$GIT_SERVICE_ROOT/proj" symbolic-ref HEAD refs/heads/main
t=/tmp/t; git init -q -b main "$t"; git -C "$t" -c user.email=f@f -c user.name=f commit -q --allow-empty -m x
git -C "$t" push -q "$GIT_SERVICE_ROOT/proj" main
git daemon --verbose --reuseaddr --export-all --base-path="$GIT_SERVICE_ROOT" \
    --listen=127.0.0.1 --port=9418 2>/tmp/daemon.log &
dpid=$!
# Wait for the LISTEN socket with the socket probe itself: an nc-based wait
# would leave a connection whose disconnect lands, late, in a later window.
i=0; while ! sh /hc/healthcheck.sh; do i=$((i+1)); [ "$i" -gt 50 ] && break; sleep 0.1; done
# Each phase SETTLES before the next is counted: git-daemon logs a probe's
# disconnect asynchronously, and a straggler from one phase must not be
# charged to the next. Counted by line number, never by truncating the log.
sleep 2
fatals() { grep -c 'hung up unexpectedly' /tmp/daemon.log; }
lines() { grep -c . /tmp/daemon.log; }
# NEW first, so no nc connection exists yet to straggle into its window.
l0="$(lines)"
ok=0; for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do sh /hc/healthcheck.sh && ok=$((ok+1)); done
sleep 2; new=$(( $(lines) - l0 ))
f0="$(fatals)"
for n in 1 2 3 4 5; do nc -w 1 127.0.0.1 9418 </dev/null; done
sleep 2; old=$(( $(fatals) - f0 ))
kill "$dpid"; wait "$dpid" 2>/dev/null; sleep 0.5
sh /hc/healthcheck.sh; down=$?
echo "OLD=$old NEW=$new NEW_OK=$ok DOWN_RC=$down"
]])
-- The image runs as user git: a 0700 scratch would hide the mount from it.
run({ "chmod", "0755", W.abs })
run({ "chmod", "0644", W.abs .. "/healthcheck.sh" })
run({ "chmod", "0755", W.abs .. "/inner.sh" })

-- --no-healthcheck: the image's own HEALTHCHECK would otherwise connect during
-- the measurement: the very noise measured. The verdict is read from STDOUT
-- only (an uncached pull's progress goes to stderr).
local r = run({ "podman", "run", "--rm", "--no-healthcheck", "--network", "none", "--entrypoint", "sh",
    "-v", W.abs .. ":/hc:ro,Z", IMAGE, "/hc/inner.sh" }, 180000)
local res = (r.stdout or ""):match("OLD=[^\n]*")
if not res then
    T:arm("the in-container probe produced a result", false,
        "rc=" .. tostring(r.code) .. " " .. tostring(r.status) .. " stderr=" .. (r.stderr or ""):sub(1, 300))
    T:finish()
end
local OLD = tonumber(res:match("OLD=(%-?%d+)"))
local NEW = tonumber(res:match("NEW=(%-?%d+)"))
local NEW_OK = tonumber(res:match("NEW_OK=(%-?%d+)"))
local DOWN = tonumber(res:match("DOWN_RC=(%-?%d+)"))
if not (OLD and NEW and NEW_OK and DOWN) then
    T:arm("the in-container result line parses", false, res)
    T:finish()
end

T:arm("ARM1 negative control: 5 bare-TCP probes made " .. OLD .. " hung-up fatals (the old healthcheck's noise is measurable)",
    OLD >= 5, "OLD=" .. OLD)
T:arm("ARM2 20 runs of healthcheck.sh: all exit 0, 0 lines added to the daemon log",
    NEW == 0 and NEW_OK == 20, NEW_OK .. "/20 ok, " .. NEW .. " daemon log lines")
T:arm("ARM3 with git-daemon stopped the probe fails (rc=" .. DOWN .. "): still a liveness check",
    DOWN ~= 0, "DOWN_RC=" .. DOWN)
T:finish()
