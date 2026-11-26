-- @trace order:2231-zmzd, spec:ci-release
-- @env TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-local-ci-landed-guards.lua — pins scripts/lua/local-ci-landed-guards.lua
-- and the loop in local-ci.sh that runs it (2231-zmzd, local-ci.sh to Lua
-- slice 5). Expectations are written out by hand, so the fixture keeps its
-- meaning after the eighteen bash copies it replaced are gone. At port time the
-- loop was also compared with those copies call for call, in four scenarios
-- (recorded on the PR).
--
-- Arms 2-5 run local-ci.sh's REAL block, extracted from the script, in a
-- git-init'd scratch repo: stub guards, a stub runner (the roster itself is
-- read by the real one), and recording stubs for log_* / archive_check_log.
--
--   1 the roster: 18 rows of 9 fields, unique ids, two reports, every guard present in this tree
--   2 a gate that exits 1 fails with its own message; a report that exits 1 still passes
--   3 a Lua guard gets its arguments after `--`, and its output is its log
--   4 an absent guard is a missing guard (archived skipped) naming its path
--   5 no runner: ONE tracked failure, landed-guards, and no guard runs
--
-- Verdict: ok:local-ci-landed-guards:5 arms | violation:local-ci-landed-guards:<n> failed

local fixture = require "common.fixture"
local SH = fixture.posix_shell()
local root = fixture.repo_root()
local failn = 0
local function ok(m) out.line("ok:   " .. m) end
local function bad(m) out.line("FAIL: " .. m); failn = failn + 1 end

local rel = "target/plan-scratch/local-ci-landed-guards-" .. tostring(time.now_ms())
local W = root .. "/" .. rel
proc.run{ argv = { "mkdir", "-p", W } }
local function cleanup() proc.run{ argv = { "find", W, "-delete" }, timeout_ms = 60000 } end

local RUNNER = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") or ""
if RUNNER == "" then
    fs.write(rel .. "/resolve.sh", ". scripts/plan-binary-probe.sh && resolve_plan_binary\n")
    RUNNER = text.trim(proc.run{ argv = { SH, W .. "/resolve.sh" } }.stdout or "")
    if RUNNER:sub(1, 2) == "./" then RUNNER = root .. "/" .. RUNNER:sub(3) end
end
if RUNNER == "" then cleanup(); verdict.could_not_run("local-ci-landed-guards:no-runner") end

-- 1 the roster
local r = proc.run{ argv = { RUNNER, "script", "run", "--helper", root .. "/scripts/lua/local-ci-landed-guards.lua" }, timeout_ms = 60000 }
local rows, ids, reports, shape, absent = {}, {}, 0, r.code == 0, {}
local B -- the roster's first bash gate, the one arms 2 and 4 break (no name here goes stale when it is ported)
for _, l in ipairs(text.lines(r.stdout or "")) do
    if l ~= "" then
        local f = {}
        for cell in (l .. "\31"):gmatch("([^\31]*)\31") do f[#f + 1] = cell end
        rows[#rows + 1] = f
        if #f ~= 9 or ids[f[1]] or not (f[2] == "gate" or f[2] == "report")
            or not (f[3] == "bash" or f[3] == "lua") then shape = false end
        ids[f[1] or ""] = true
        if f[2] == "report" then reports = reports + 1 end
        if not B and f[2] == "gate" and f[3] == "bash" then B = { id = f[1], path = f[4], log = (f[6] or ""):match("[^/]+$"), fail = f[8] } end
        if f[4] and not fs.exists(f[4]) then absent[#absent + 1] = f[4] end
    end
end
if shape and #rows == 18 and reports == 2 and #absent == 0 then
    ok("1 the roster: 18 rows of 9 fields, unique ids, two reports, every guard present")
else
    bad("1 rc=" .. tostring(r.code) .. " rows=" .. #rows .. " reports=" .. reports
        .. " absent=" .. table.concat(absent, ","))
end

-- 2412-ewmt ported the last bash gate. "Every gate is Lua" is the goal, not a fault, and arms 2 and
-- 4 (a failing gate, a missing gate) do not depend on the runtime: they then break the Lua gate the
-- stub runner already fails, litmus-dead-inputs. Only if that row is gone too is there no subject.
if not B then
    for _, f in ipairs(rows) do
        if f[1] == "litmus-dead-inputs" and f[2] == "gate" then B = { id = f[1], path = f[4], log = (f[6] or ""):match("[^/]+$"), fail = f[8] } end
    end
end
if not B then cleanup(); verdict.could_not_run("local-ci-landed-guards:no-gate-for-arms-2-and-4") end

-- the harness: local-ci.sh's block over stubs in a scratch repo
fs.write(rel .. "/harness.sh", [==[
set -uo pipefail
W="$1"; REAL="$2"; RBIN="$3"; sc="$4"; gate="$5"
mkdir -p "$W/scripts/lua" "$W/tmp"
(unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE; git init -q "$W")
sed "s#/tmp/#$W/tmp/#g" "$REAL/scripts/lua/local-ci-landed-guards.lua" > "$W/scripts/lua/local-ci-landed-guards.lua"
cat > "$W/runner" <<EOF
#!/usr/bin/env bash
[ "\$1" = capabilities ] && { echo script; exit 0; }
case "\$*" in *local-ci-landed-guards.lua*) exec "$RBIN" "\$@" ;; esac
echo "lua-guard \$*"
case "\$*" in *dead-inputs*|*deslop*) exit 1 ;; esac
exit 0
EOF
chmod +x "$W/runner"
if [ "$sc" = norunner ]; then
    printf 'resolve_plan_binary() { return 1; }\n' > "$W/scripts/plan-binary-probe.sh"
    unset TILLANDSIAS_SCRIPT_RUNNER_BIN
else
    printf 'resolve_plan_binary() { echo "%s/runner"; }\n' "$W" > "$W/scripts/plan-binary-probe.sh"
    export TILLANDSIAS_SCRIPT_RUNNER_BIN="$W/runner"
fi
"$RBIN" script run --helper "$REAL/scripts/lua/local-ci-landed-guards.lua" | cut -d$'\x1f' -f4 | while read -r p; do
    mkdir -p "$W/$(dirname "$p")"
    case "$p" in
        *.lua) printf 'fake\n' > "$W/$p" ;;
        *) printf 'echo "bash-guard %s"\ncase "%s" in %s) exit 1 ;; esac\nexit 0\n' "$p" "$p" "$gate" > "$W/$p" ;;
    esac
done
[ "$sc" = missing ] && rm -f "$W/$gate"
block="$(sed -n '/^    log_section "Recently Landed Guards"$/,/^    # Guard activation audit (order 599-4wzr)/p' "$REAL/scripts/local-ci.sh" | sed '$d')"
REPO_ROOT="$W"; cd "$W" || exit 2
log_section() { echo "SECTION $*"; }
log_pass() { echo "PASS $*"; }
log_fail_tracked() { echo "FAIL [$1] $2"; }
log_fail_missing_guard() { echo "MISSING [$1] $2"; }
archive_check_log() { echo "ARCHIVE $1 $2 ${3:+$(basename "$3")}"; }
eval "$block" > "$W/out.txt" 2>&1
grep -E '^(PASS|FAIL|MISSING|ARCHIVE) ' "$W/out.txt"
for l in "$W"/tmp/*.log; do [ -f "$l" ] && echo "LOG $(basename "$l"): $(tr '\n' '|' < "$l")"; done
exit 0
]==])

local function run(sc)
    local x = proc.run{ argv = { SH, W .. "/harness.sh", W .. "/" .. sc, root, RUNNER, sc, B.path }, timeout_ms = 120000 }
    local lit = (W .. "/" .. sc):gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
    return (x.stdout or ""):gsub(lit, "W"), x.stderr or ""
end
local function has(s, line) return s:find(line, 1, true) ~= nil end

local o = run("mixed")
if has(o, "FAIL [" .. B.id .. "] " .. B.fail:gsub("/tmp/", "W/tmp/") .. "\n")
    and has(o, "ARCHIVE " .. B.id .. " fail " .. B.log .. "\n")
    and has(o, "PASS De-slop sweep health reported (829-dkuc, informational)\n")
    and has(o, "ARCHIVE deslop-sweep-health pass deslop-sweep-health.log\n")
    and has(o, "PASS Litmus grep patterns use escapes GNU grep actually defines\n") then
    ok("2 a gate exiting 1 fails with its own message; a report exiting 1 still passes")
else bad("2 " .. o) end

if has(o, "LOG dev-embed-model-agreement.log: lua-guard script run scripts/lua/source-agreements.lua -- dev_embed_model_agreement images/default/config-overlay/mcp/lib-dev-env.sh scripts/dev-inference-ensure.sh|")
    and has(o, "FAIL [litmus-dead-inputs] Dead litmus inputs glob (see W/tmp/litmus-dead-inputs.log)\n")
    and has(o, "LOG litmus-dead-inputs.log: lua-guard script run scripts/lua/check-litmus-dead-inputs.lua|") then
    ok("3 a Lua guard gets its arguments after --, and its output is its log")
else bad("3 " .. o) end

o = run("missing")
if has(o, "MISSING [" .. B.id .. "] " .. B.path .. "\n")
    and has(o, "ARCHIVE " .. B.id .. " skipped \n") and not has(o, B.log) then
    ok("4 an absent guard is a missing guard, archived skipped, naming its path")
else bad("4 " .. o) end

o = run("norunner")
local _, nlines = o:gsub("\n", "")
if has(o, "MISSING [landed-guards] a runnable tillandsias-plan to read scripts/lua/local-ci-landed-guards.lua (2231-zmzd)\n")
    and has(o, "ARCHIVE landed-guards skipped \n") and nlines == 2 then
    ok("5 no runner: one tracked failure, landed-guards, and no guard runs")
else bad("5 lines=" .. nlines .. " " .. o) end

cleanup()
if failn == 0 then verdict.ok("local-ci-landed-guards:5 arms") end
verdict.emit("violation:local-ci-landed-guards:" .. failn .. " failed", 1)
