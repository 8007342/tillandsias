-- @trace spec:inference-container, order:1859-v5iv
-- @env PATH
--
-- test-inference-supervise.lua — the inference entrypoint stops on SIGTERM
-- instead of waiting out the stop timeout (1859-v5iv).
--
-- images/inference/supervise.sh runs with a stub engine (a shell that records
-- the SIGTERM it receives and exits 0) and a second background job, as a plain
-- child and, where `unshare` can make one, as PID 1 of a new PID namespace
-- (the container case: the kernel drops a signal PID 1 has no handler for).
-- The process arms run in bash because the subject is a shell library; this
-- script writes that harness to scratch and owns the verdict.
--   term        SIGTERM reaches the engine and the other job; the supervisor
--               exits 0, the engine's status
--   own-exit    an engine that exits 3 by itself exits the supervisor with 3
--   control     NEGATIVE CONTROL: the old final line, `wait $OLLAMA_PID`,
--               does NOT pass SIGTERM on, so `term` can tell the two apart
--   entrypoint  entrypoint.sh ends by sourcing the path the Containerfile
--               copies supervise.sh to and calling tillandsias_supervise
-- Red before 1859-v5iv: the entrypoint arm (its last line was the bare wait).
--
-- Usage: tillandsias-plan script run scripts/lua/test-inference-supervise.lua

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.status ~= "exited" or top.code ~= 0 or ROOT == "" then
    verdict.could_not_run("inference-supervise", "git rev-parse --show-toplevel did not answer")
end
local LIB = ROOT .. "/images/inference/supervise.sh"
if not fs.exists("images/inference/supervise.sh") then
    verdict.emit("violation:inference-supervise:no-subject", 1, "images/inference/supervise.sh does not exist (1859-v5iv)")
end

local REL = "target/plan-scratch/inference-supervise-" .. time.iso_utc() .. "-" .. tostring(math.random(100000, 999999))
fs.mkdir(REL)

local failed, passed = {}, 0
local function arm(name, cond, got)
    got = got and tostring(got):gsub("\n", " | ") or nil
    if cond then
        passed = passed + 1
        out.line("ok:   " .. name .. (got and (" — " .. got) or ""))
    else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got))
        failed[#failed + 1] = name
    end
end

local HARNESS = [==[
set -uo pipefail
LIB="$1"

pass=0
fail=0
ok() { echo "ok:   $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*" >&2; fail=$((fail + 1)); }

SCRATCH="$(mktemp -d)"
trap 'reap_all; rm -rf "$SCRATCH"' EXIT

# Kill, by the pid each wrote, every stub a run left behind.
reap_all() {
    local f
    for f in "$SCRATCH"/*/*.up; do
        [ -f "$f" ] && kill -KILL "$(cat "$f")" 2>/dev/null
    done
    return 0
}

wait_for() { # path budget-tenths
    local i
    for ((i = 0; i < $2; i++)); do
        [ -e "$1" ] && return 0
        sleep 0.1
    done
    return 1
}

# Wait up to $2 seconds for child pid $1; its status in WAITED_RC, empty on
# timeout. (kill -0 cannot poll a child: it still answers for a zombie.)
wait_pid() {
    WAITED_RC=
    (sleep "$2" && kill -KILL "$1") 2>/dev/null &
    local dog=$!
    wait "$1"
    local rc=$?
    if kill "$dog" 2>/dev/null; then
        WAITED_RC=$rc
    fi
    wait "$dog" 2>/dev/null
    [ -n "$WAITED_RC" ]
}

# start <dir> <final-line> <pid1:0|1> [engine-exit] — sets RUN_PID
start() {
    local dir=$1 tail=$2 pid1=$3 engine_exit=${4:-}
    mkdir -p "$dir"
    cat >"$dir/stub.sh" <<'EOS'
trap 'echo term > "$1"; exit 0' TERM
echo $$ > "$1.up"
while :; do sleep 0.1; done
EOS
    if [ -n "$engine_exit" ]; then
        printf 'echo $$ > "$1.up"; sleep 0.3; exit %d\n' "$engine_exit" >"$dir/engine.sh"
    else
        cp "$dir/stub.sh" "$dir/engine.sh"
    fi
    cat >"$dir/main.sh" <<EOS
. "$LIB"
bash "$dir/engine.sh" "$dir/engine" &
OLLAMA_PID=\$!
bash "$dir/stub.sh" "$dir/job" &
echo \$\$ > "$dir/main.pid"
$tail
EOS
    if [ "$pid1" = 1 ]; then
        unshare --user --map-root-user --pid --fork --kill-child bash "$dir/main.sh" 2>/dev/null &
    else
        bash "$dir/main.sh" 2>/dev/null &
    fi
    RUN_PID=$!
}

# SIGTERM the supervising shell: the unshare child when it is PID 1.
signal_inner() { # run-pid pid1
    if [ "$2" = 1 ]; then
        local inner
        inner="$(pgrep -P "$1" | head -n1)"
        [ -n "$inner" ] && kill -TERM "$inner"
    else
        kill -TERM "$1"
    fi
}

regimes="0"
if command -v unshare >/dev/null 2>&1 \
    && unshare --user --map-root-user --pid --fork true 2>/dev/null; then
    regimes="0 1"
else
    echo "skip: PID-1 regime (unshare cannot make a user+pid namespace here)"
fi

for pid1 in $regimes; do
    if [ "$pid1" = 1 ]; then where="as PID 1"; else where="as a child"; fi

    d="$SCRATCH/term-$pid1"
    start "$d" 'tillandsias_supervise "$OLLAMA_PID"' "$pid1"
    if wait_for "$d/engine.up" 50 && wait_for "$d/job.up" 50; then
        signal_inner "$RUN_PID" "$pid1"
        if wait_pid "$RUN_PID" 5 && [ "$WAITED_RC" = 0 ] && [ -e "$d/engine" ] && [ -e "$d/job" ]; then
            ok "term $where: engine and job got SIGTERM, supervisor exited 0"
        else
            bad "term $where: rc=${WAITED_RC:-timeout} engine-signalled=$([ -e "$d/engine" ] && echo y || echo n) job-signalled=$([ -e "$d/job" ] && echo y || echo n)"
            kill -KILL "$RUN_PID" 2>/dev/null
        fi
    else
        bad "term $where: the stub engine never started"
        kill -KILL "$RUN_PID" 2>/dev/null
    fi

    d="$SCRATCH/own-$pid1"
    start "$d" 'tillandsias_supervise "$OLLAMA_PID"' "$pid1" 3
    if wait_pid "$RUN_PID" 5 && [ "$WAITED_RC" = 3 ]; then
        ok "own-exit $where: the engine's own status 3 is the supervisor's"
    else
        bad "own-exit $where: rc=${WAITED_RC:-timeout}, want 3"
        kill -KILL "$RUN_PID" 2>/dev/null
    fi

    d="$SCRATCH/ctl-$pid1"
    start "$d" 'wait "$OLLAMA_PID"' "$pid1"
    if wait_for "$d/engine.up" 50; then
        signal_inner "$RUN_PID" "$pid1"
        wait_pid "$RUN_PID" 2
        if wait_for "$d/engine" 10; then
            bad "control $where: a bare wait also passed SIGTERM on, so 'term' proves nothing"
        else
            ok "control $where: a bare wait leaves the engine unsignalled (the arm can tell)"
        fi
    else
        bad "control $where: the stub engine never started"
    fi
    kill -KILL "$RUN_PID" 2>/dev/null
    wait "$RUN_PID" 2>/dev/null
    reap_all
done

echo "done:$pass:$fail"
]==]
fs.write(REL .. "/harness.sh", HARNESS)
local r = proc.run({ argv = { "bash", ROOT .. "/" .. REL .. "/harness.sh", LIB }, timeout_ms = 120000 })
local stdout = r.stdout or ""
for line in stdout:gmatch("[^\n]+") do
    local okm = line:match("^ok:   (.*)$")
    if okm then arm(okm, true) end
    local skip = line:match("^skip: (.*)$")
    if skip then out.line("skip: " .. skip) end
end
for line in (r.stderr or ""):gmatch("[^\n]+") do
    local bad = line:match("^FAIL: (.*)$")
    if bad then arm(bad, false, "see the arm") end
end
if not stdout:match("done:%d+:%d+") then
    arm("the process arms ran to the end", false, (r.status or "?") .. " " .. tostring(r.code))
end

-- entrypoint: the real final step, against the real install path.
local cf = fs.read("images/inference/Containerfile") or ""
local dest = cf:match("\nCOPY supervise%.sh (%S+)\n")
local code = {}
for line in (fs.read("images/inference/entrypoint.sh") or ""):gmatch("[^\n]+") do
    local t = text.trim(line)
    if t ~= "" and t:sub(1, 1) ~= "#" then code[#code + 1] = t end
end
local last_two = (code[#code - 1] or "") .. " ; " .. (code[#code] or "")
if not dest then
    arm("entrypoint: the Containerfile copies supervise.sh into the image", false, "no COPY supervise.sh line")
else
    arm("entrypoint: ends by sourcing " .. dest .. " and supervising ollama",
        last_two == ". " .. dest .. ' ; tillandsias_supervise "$OLLAMA_PID"', last_two)
end

proc.run({ argv = { "rm", "-rf", ROOT .. "/" .. REL }, timeout_ms = 30000 })
if #failed > 0 then
    verdict.emit("violation:inference-supervise:" .. #failed .. "-failed", 1)
end
verdict.ok("inference-supervise", passed .. " arms")
