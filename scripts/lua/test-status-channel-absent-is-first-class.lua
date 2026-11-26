-- @trace order:1260-2qgi, spec:meta-orchestration, order:2385-psbb
-- @env PATH HOME TILLANDSIAS_WSL_DISTRO
--
-- test-status-channel-absent-is-first-class.lua — fixture for methodology/convergence.yaml ->
-- status_channel_policy (1260-2qgi): a status carried by a channel is PRESERVED or DECLARED
-- ABSENT, never a substituted integer; the verdict is ternary green / red / absent. Ported
-- from test-status-channel-absent-is-first-class.sh (2385-psbb); same four arms.
--
-- The channel is the agent door, `tillandsias-plan run --json` (1443-8pur slice 2); on a
-- binary whose `run` lacks --json the fixture drives the improvised `echo "rc=$?"` recipe
-- (the pre-fix evidence: arms 1/3/4 FAIL against it). Each arm reads three children:
--   rc1 exits 1 -> RED;  killed never reports -> ABSENT;  ok exits 0 -> GREEN (NEGATIVE CONTROL)
--
--   1  a DETACHED run's terminal line
--   2  the wsl.exe hop (scripts/lib-wsl-exec.sh's canary) carries the status or refuses
--      naming the drop; a named SKIP where there is no wsl.exe
--   3  `producer | tee log`: the status is the PRODUCER's, not tee's
--   4  a child killed mid-run from outside: ABSENT, not 128+N
-- On Windows, arms 1/3/4 skip BY NAME (limit:windows-external-kill-reads-as-exited) when
-- the verb declares that limit; never read as absent, never as a pass.
--
-- The detach (nohup ... & disown, an outside kill -KILL) runs in a short posix_shell driver.
-- TILLANDSIAS_* is stripped from every child; TILLANDSIAS_WSL_DISTRO is read here only.
-- No build.sh child: gate_inherit n/a.
--
-- GRAMMAR ok:status-channel:<n> arms | violation:status-channel:<n>-failed
--       | skip:status-channel:<reason>   (a skipped arm prints "skip: ..." and is not counted)

local fixture = require "common.fixture"
local T = fixture.new("status-channel")
local ROOT, SH = fixture.repo_root(), fixture.posix_shell()
local WIN_LIMIT = "limit:windows-external-kill-reads-as-exited"
local ON_WINDOWS = SH ~= "bash"
local PLAN = fixture.plan_binary()
local UNSET = { "TILLANDSIAS_*" }
local W = T:scratch()
local skipped, ran = 0, 0
local function arm(name, cond, got) ran = ran + 1; return T:arm(name, cond, got) end
local function skip(msg) skipped = skipped + 1; out.line("skip: " .. msg) end

-- The children, as script FILES (the door refuses command strings).
local function child(name, body) fs.write(W.rel .. "/" .. name, "#!/bin/bash\n" .. body .. "\n"); return W.abs .. "/" .. name end
local RC1 = child("rc1.sh", "exit 1")
local OK = child("ok.sh", "exit 0")
local KILLME = child("killme.sh", 'echo $$ > "' .. W.abs .. '/killme.pid"\nexec sleep 60')
local PFAIL = child("producer-fails.sh", "echo produced\nexit 1")
local POK = child("producer-ok.sh", "echo produced\nexit 0")

local function run(spec) spec.env_unset = UNSET; spec.timeout_ms = spec.timeout_ms or 120000; return T:run(spec) end

-- Does the door speak --json? Asked by running it.
local DOOR = false
if PLAN ~= "" then
    local r = run{ PLAN, "run", "--json", "--", SH, OK }
    DOOR = text.contains(r.stdout or "", '"status"')
end
local LIMIT_DECLARED = false
if ON_WINDOWS and PLAN ~= "" then
    local r = run{ PLAN, "run", "--help" }
    LIMIT_DECLARED = text.contains((r.stdout or "") .. (r.stderr or ""), WIN_LIMIT)
end
out.line("channel: " .. (DOOR and "agent door (tillandsias-plan run --json)"
    or "improvised recipe (pre-fix: the door has no --json on this binary)"))

local function jget(line, path)
    local r = run{ PLAN, "json", "get", "-r", path, stdin = line, timeout_ms = 30000 }
    return text.trim(r.stdout or "")
end
local NON_EXITED = { signaled = 1, timed_out = 1, no_status = 1, spawn_failed = 1, policy_denied = 1, policy_consent = 1 }
-- verdict(terminal line) -> green | red:<n> | absent:<why> | unparsed:<line>
local function verdict(line)
    if text.contains(line, '"status"') then
        local st = jget(line, ".status")
        if st == "exited" then
            local code = jget(line, ".code")
            return code == "0" and "green" or ("red:" .. code)
        end
        -- `code` is an integer ONLY for exited (1443-8pur vocabulary): every other status is absent.
        if NON_EXITED[st] then return "absent:" .. st end
        return "unparsed:" .. line
    end
    if line:find("^rc=absent") then return "absent:" .. line:gsub("^rc=absent:", "") end
    if line == "rc=0" then return "green" end
    if line:find("^rc=%d") then return "red:" .. line:sub(4) end
    if line == "" then return "absent:no-terminal-line" end
    return "unparsed:" .. line
end
local function killed_verdict(line)
    local v = verdict(line)
    if v == "red:2304" and ON_WINDOWS and LIMIT_DECLARED then return WIN_LIMIT end
    return v
end
local function last_line(s)
    local l = ""
    for _, x in ipairs(text.lines(s or "")) do if x:find("%S") then l = x end end
    return l
end

-- The DETACHED recipe, run to completion: its terminal line.
--   door: tillandsias-plan run --json -- <argv>;  improvised: `nohup launcher & disown`, echo "rc=$?"
local DETACH = [[
W="$1"; name="$2"; door="$3"; plan="$4"; sh="$5"; shift 5
log="$W/$name.log"; launcher="$W/$name.launch.sh"
if [ "$door" = 1 ]; then
    printf '#!/bin/bash\n"%s" run --json -- %s\n' "$plan" "$*" > "$launcher"
else
    printf '#!/bin/bash\n%s\necho "rc=$?"\n' "$*" > "$launcher"
fi
nohup "$sh" "$launcher" </dev/null >"$log" 2>&1 &
pid=$!
disown 2>/dev/null || true
if [ "$name" = killed ]; then
    i=0
    while [ ! -s "$W/killme.pid" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i+1)); done
    kill -KILL "$(cat "$W/killme.pid" 2>/dev/null)" 2>/dev/null
    rm -f "$W/killme.pid"
fi
while kill -0 "$pid" 2>/dev/null; do sleep 0.05; done
cat "$log"
]]
local function detached(name, script)
    local r = run{ SH, "-s", "--", W.abs, name, DOOR and "1" or "0", PLAN, SH, SH, script, stdin = DETACH }
    return last_line(r.stdout)
end

local function expect_arm(label, red_line, killed_line, ok_line)
    local v_red, v_abs, v_ok = verdict(red_line), killed_verdict(killed_line), verdict(ok_line)
    if v_abs == WIN_LIMIT then
        if v_red == "red:1" and v_ok == "green" then
            skip(label .. ": killed-from-outside leg is " .. WIN_LIMIT .. " (declared by the verb); rc1 -> red:1, exit 0 -> green")
        else
            arm(label .. ": rc1 -> red:1, exit 0 -> green (killed leg " .. WIN_LIMIT .. ")", false,
                v_red .. " / " .. v_ok)
        end
        return
    end
    arm(label .. ": rc1 -> red:1, killed -> absent, exit 0 -> green",
        v_red == "red:1" and v_abs:match("^[^:]*") == "absent" and v_ok == "green",
        "rc1 -> " .. v_red .. ", killed -> " .. v_abs .. ", exit 0 -> " .. v_ok)
end

-- 1
expect_arm("arm 1 (detached terminal line)", detached("rc1", RC1), detached("killed", KILLME), detached("ok", OK))

-- 2 the wsl.exe hop
if not fixture.which("wsl.exe") then
    skip("arm 2 (wsl.exe hop): no wsl.exe on this host — yolanda runs this arm on Windows")
else
    local distro = env.get("TILLANDSIAS_WSL_DISTRO")
    if not distro or distro == "" then distro = "tillandsias" end
    local r = run{ SH, "-s", "--", ROOT .. "/scripts/lib-wsl-exec.sh", distro,
        stdin = '. "$1" && wsl_exec_transport_ok "$2" 2>&1\n' }
    local o2, rc2 = (r.stdout or "") .. (r.stderr or ""), r.code
    if text.contains(o2, "ok:wsl-exec-transport:carries-exit-status") then
        arm("arm 2 (wsl.exe hop): the status is carried", rc2 == 0, "carried, but rc=" .. tostring(rc2))
    elseif text.contains(o2, "refused:wsl-exec-transport:drops-exit-status") then
        arm("arm 2 (wsl.exe hop): the drop is DECLARED (refused), not substituted", rc2 ~= 0, "declared a drop but exited 0")
    else
        arm("arm 2 (wsl.exe hop): carried or declared", false, "[" .. o2 .. "] rc=" .. tostring(rc2))
    end
end

-- 3 producer | tee
local IMPROVISED = 'bash "$1" | tee "$2" >/dev/null; echo "rc=$?"\n'
local function pipeline(producer)
    if DOOR then
        local r = run{ SH, "-s", "--", PLAN, SH, producer, W.abs .. "/tee.log",
            stdin = '"$1" run --json -- "$2" "$3" 2>/dev/null | tee "$4"\n' }
        return last_line(r.stdout)
    end
    -- A FRESH shell without pipefail, as an agent's shell runs it.
    return last_line(run{ SH, "-s", "--", producer, W.abs .. "/tee.log", stdin = IMPROVISED }.stdout)
end
expect_arm("arm 3 (producer | tee)", pipeline(PFAIL), detached("killed", KILLME), pipeline(POK))

-- 4 killed mid-run from outside
local k4 = detached("killed", KILLME)
local v4 = killed_verdict(k4)
if v4 == WIN_LIMIT then
    skip("arm 4 (killed mid-run): " .. WIN_LIMIT .. " — an external kill on Windows reads as exited 2304; declared by the verb, not decoded")
else
    arm("arm 4 (killed mid-run): absent", v4:match("^[^:]*") == "absent",
        "read as " .. v4 .. " from [" .. k4 .. "] — a substituted integer, not absent")
end

if skipped > 0 then out.line("skipped=" .. skipped) end
if ran == 0 then T:skip("no-arm-ran") end
T:finish()
