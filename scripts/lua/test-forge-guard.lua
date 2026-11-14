-- @trace order:2067-dwqd
-- @env PATH HOME XDG_RUNTIME_DIR
--
-- test-forge-guard.lua — images/default/cli/forge-guard, run where it ships:
-- inside the forge base image (stock Lua 5.4, flock, no luaposix), in ONE
-- container with --cpus=2, --memory=512m and memory.high 256 MiB, so the
-- budget arms read a real cgroup.
--   1 HELP      --help prints the usage, exit 0
--   2 CPUS      budget reports cpus=2 (cpu.max), not the host's count
--   3 THREADS   run --threads 3 gives the job OMP/RAYON/GOMAXPROCS/CARGO=3
--   4 DEFAULT   without --threads the caps are the CPU budget (2), and the job
--               sees TILLANDSIAS_CPUS=2 and TILLANDSIAS_MEM_BUDGET_MB=256
--   5 EXIT      the job's exit code is forge-guard's (7)
--   6 HEADROOM  --need-mb 100000 refuses with refused:forge-guard:headroom,
--               exit 75, and the job never runs
--   7 ROOM      --need-mb 1 runs the job (control for 6)
--   8 QUEUE     a second job on the same slot starts after the first ends,
--               and says it waited
--   9 PARALLEL  a job on another slot overlaps (control for 8)
--  10 KILL      sustained full pressure (a fake pressure file) kills the job's
--               whole tree, grandchild included: exit 137,
--               killed:forge-guard:memory-pressure
--  11 NO-KILL   --no-kill leaves the job running and warns (control for 10)
--  12 WAIT-PID  wait --pid returns once the process is gone
--  13 WAIT-TO   wait --file on a missing file times out with exit 124
-- Red before 2067-dwqd: the tool did not exist.
--
-- Usage: tillandsias-plan script run scripts/lua/test-forge-guard.lua

local NAME = "forge-guard"
local TOOL = "images/default/cli/forge-guard"
if not fs.exists(TOOL) then
    verdict.emit("violation:forge-guard:no-subject", 1, TOOL .. " does not exist")
end
local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.code ~= 0 or ROOT == "" then verdict.could_not_run(NAME, "git rev-parse --show-toplevel did not answer") end

-- A VERSIONED forge-base tag, never the mutable one (check-container-bases).
local REPO = "localhost/tillandsias-forge-base"
local tags = proc.run({ argv = { "podman", "images", "--filter", "reference=" .. REPO, "--format", "{{.Tag}}" }, timeout_ms = 30000 })
local IMG
for _, t in ipairs(text.lines(tags.stdout or "")) do
    if t:match("^v%d") then IMG = REPO .. ":" .. t; break end
end
if not IMG then verdict.could_not_run(NAME, "no versioned " .. REPO .. " tag in the store (tillandsias --init builds it)") end

-- The arms run inside the container as one script, each printing ARM<n>:<fields>.
local INNER = [[
G=/opt/fg/forge-guard
export FORGE_GUARD_LOCK_DIR=/tmp/fg-locks
o=$(lua $G --help); echo "ARM1:rc=$?:usage=$(printf '%s' "$o" | grep -c '^Usage:')"
echo "ARM2:$(lua $G budget | tr '\n' ' ')"
o=$(lua $G run --threads 3 -- env); echo "ARM3:$(printf '%s\n' "$o" | grep -E '^(OMP_NUM_THREADS|RAYON_NUM_THREADS|GOMAXPROCS|CARGO_BUILD_JOBS)=' | sort | tr '\n' ' ')"
o=$(lua $G run -- env); echo "ARM4:$(printf '%s\n' "$o" | grep -E '^(OMP_NUM_THREADS|TILLANDSIAS_CPUS|TILLANDSIAS_MEM_BUDGET_MB)=' | sort | tr '\n' ' ')"
lua $G run -- sh -c 'exit 7'; echo "ARM5:rc=$?"
o=$(lua $G run --need-mb 100000 -- touch /tmp/ran6); rc=$?; echo "ARM6:rc=$rc:ran=$(test -e /tmp/ran6 && echo yes || echo no):$o" | head -1
lua $G run --need-mb 1 -- touch /tmp/ran7; echo "ARM7:rc=$?:ran=$(test -e /tmp/ran7 && echo yes || echo no)"
lua $G run --slot q -- sh -c 'date +%s%N > /tmp/a1; sleep 2; date +%s%N > /tmp/a2' &
sleep 0.5
lua $G run --slot q -- sh -c 'date +%s%N > /tmp/b1' 2> /tmp/b.err
wait
echo "ARM8:after=$( [ "$(cat /tmp/b1)" -ge "$(cat /tmp/a2)" ] && echo yes || echo no):waited=$(grep -c 'is busy; waiting' /tmp/b.err)"
lua $G run --slot p1 -- sh -c 'date +%s%N > /tmp/c1; sleep 2; date +%s%N > /tmp/c2' &
sleep 0.5
lua $G run --slot p2 -- sh -c 'date +%s%N > /tmp/d1'
wait
echo "ARM9:overlap=$( [ "$(cat /tmp/d1)" -lt "$(cat /tmp/c2)" ] && echo yes || echo no)"
mkdir -p /tmp/fakecg
printf 'some avg10=95.00 avg60=90.00 avg300=50.00 total=1\nfull avg10=90.00 avg60=80.00 avg300=40.00 total=1\n' > /tmp/fakecg/memory.pressure
t0=$(date +%s)
# Bounded: a guard that fails to kill must fail THIS arm, not time out the container.
FORGE_GUARD_CGROUP=/tmp/fakecg timeout -s KILL 25 lua $G run --sustain 2 -- sh -c 'sleep 301 & sleep 302' 2> /tmp/k.err; rc=$?
sleep 1
left=$(grep -l 'sleep30[12]' /proc/[0-9]*/cmdline 2>/dev/null | wc -l)
echo "ARM10:rc=$rc:secs=$(( $(date +%s) - t0 )):left=$left:line=$(grep -c '^killed:forge-guard:memory-pressure' /tmp/k.err)"
FORGE_GUARD_CGROUP=/tmp/fakecg lua $G run --no-kill --sustain 1 -- sleep 4 2> /tmp/n.err; echo "ARM11:rc=$?:warn=$(grep -c '^warn:forge-guard:memory-pressure' /tmp/n.err)"
sleep 2 & p=$!
o=$(lua $G wait --pid $p); echo "ARM12:rc=$?:$o"
o=$(lua $G wait --file /tmp/never --timeout 2); echo "ARM13:rc=$?:$o"
]]
local REL = "target/plan-scratch/forge-guard-" .. time.iso_utc():gsub("[^%w]", "") .. "-" .. tostring(math.random(100000, 999999))
fs.mkdir(REL)
fs.write(REL .. "/arms.sh", INNER)
local r = proc.run({ argv = { "podman", "run", "--rm", "--pull=never", "--network=none", "--cap-drop=ALL",
    "--security-opt=no-new-privileges", "--security-opt=label=disable", "--cpus=2", "--memory=512m",
    "--cgroup-conf=memory.high=268435456",
    "-v", ROOT .. "/" .. TOOL .. ":/opt/fg/forge-guard:ro", "-v", ROOT .. "/" .. REL .. ":/opt/fg/t:ro",
    "--entrypoint", "/bin/sh", IMG, "/opt/fg/t/arms.sh" }, timeout_ms = 240000 })
if r.code == nil then verdict.could_not_run(NAME, "podman run did not finish") end
local o = r.stdout or ""
local function A(n) return o:match("ARM" .. n .. ":([^\n]*)") or "" end

local failed, passes = {}, 0
local function arm(name, cond, got)
    if cond then passes = passes + 1; out.line("ok:   " .. name) else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got))
        failed[#failed + 1] = name
    end
end
arm("1 HELP --help prints the usage, exit 0", A(1) == "rc=0:usage=1", A(1))
arm("2 CPUS budget reports cpus=2 from cpu.max", A(2):find("cpus=2 ", 1, true) ~= nil and A(2):find("memory_budget_mb=256", 1, true) ~= nil, A(2))
arm("3 THREADS --threads 3 caps OMP/RAYON/GOMAXPROCS/CARGO",
    A(3) == "CARGO_BUILD_JOBS=3 GOMAXPROCS=3 OMP_NUM_THREADS=3 RAYON_NUM_THREADS=3 ", A(3))
arm("4 DEFAULT caps follow the CPU budget and the budget is exported",
    A(4) == "OMP_NUM_THREADS=2 TILLANDSIAS_CPUS=2 TILLANDSIAS_MEM_BUDGET_MB=256 ", A(4))
arm("5 EXIT the job's exit code is forge-guard's", A(5) == "rc=7", A(5))
arm("6 HEADROOM --need-mb 100000 refuses, exit 75, job not run",
    A(6):match("^rc=75:ran=no:refused:forge%-guard:headroom:need=100000MiB:free=%d+MiB:budget=256MiB") ~= nil, A(6))
arm("7 ROOM --need-mb 1 runs the job", A(7) == "rc=0:ran=yes", A(7))
arm("8 QUEUE the same slot waits for the first job and says so", A(8) == "after=yes:waited=1", A(8))
arm("9 PARALLEL another slot overlaps", A(9) == "overlap=yes", A(9))
local secs = tonumber(A(10):match("secs=(%d+)") or "999")
arm("10 KILL sustained pressure kills the tree, grandchild too: exit 137",
    A(10):match("^rc=137:") ~= nil and A(10):find(":left=0:line=1", 1, true) ~= nil and secs < 20, A(10))
arm("11 NO-KILL --no-kill warns and lets the job finish", A(11) == "rc=0:warn=1", A(11))
arm("12 WAIT-PID wait --pid returns once the process is gone", A(12):match("^rc=0:ok:forge%-guard:wait:pid=%d+:after=[12]s$") ~= nil, A(12))
arm("13 WAIT-TO wait --file times out with 124", A(13) == "rc=124:timeout:forge-guard:wait:2s", A(13))
if #failed > 0 then
    log.raw(text.trim(o .. "\n" .. (r.stderr or "")))
    verdict.emit("refused:" .. NAME .. ":" .. #failed .. "-of-13", 1)
end
verdict.emit("ok:" .. NAME .. ":13", 0)
