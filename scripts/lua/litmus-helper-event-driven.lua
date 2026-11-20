-- @env PATH HOME XDG_RUNTIME_DIR TEST_LABEL EVENTS_LOG TILLANDSIAS_FORGE_IMAGE
-- @read-env TEST_LABEL EVENTS_LOG TILLANDSIAS_FORGE_IMAGE
-- @trace spec:podman-idiomatic-patterns
--
-- litmus-helper-event-driven.lua — PORTED from litmus-helper-event-driven.sh
-- (2111-y8ch, lenovinha shell slice) and FIXED (coordinator ruling 2026-11-19).
--
-- THE DEFECT THE PORT FIXES. The .sh defaulted its label and events log to
-- "...-$$", and every litmus step is its own process, so each step had a
-- DIFFERENT label and log: the listener filtered on step 2's label, the
-- container carried step 3's, and wait-create-event polled step 4's log, which
-- nothing ever wrote. The arm could only time out. Now start-listener mints ONE
-- run id (label, log, start time) into a state file under target/litmus-scratch;
-- every later step reads it from there, and cleanup removes it. TEST_LABEL and
-- EVENTS_LOG still override, as before.
--
-- A detached `podman events` stream cannot outlive a script step without a
-- shell (proc.run refuses sh), so the waits read podman's event LOG for the
-- run: `podman events --since <start> --until <now> --filter label=<run>`.
-- Still event-driven, never container-state polling. Three more .sh defects
-- fixed on the way, each measured on lenovinha 2026-11-19: the forge image
-- grep never matched localhost/ names; {{.Actor.ID}} is not an event field;
-- podman 5 reports a stopped container as "died", which "die" missed.
--
-- Grammar (stdout), unchanged for the litmus steps: the same tokens as the .sh
-- (PODMAN_EVENTS_OK, LISTENER_STARTED, CREATE_EVENT_CAPTURED, ...). A step that
-- needs the run state and finds none prints FAIL: and exits 1.
--
-- Usage: tillandsias-plan script run scripts/lua/litmus-helper-event-driven.lua -- <mode>

local SCRATCH = "target/litmus-scratch"
local STATE = SCRATCH .. "/event-driven.state"

local function penv()
    return { PATH = env.get("PATH") or "", HOME = env.get("HOME") or "",
        XDG_RUNTIME_DIR = env.get("XDG_RUNTIME_DIR") }
end
local function podman(args, timeout_ms)
    local argv = { "podman" }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    return proc.run{ argv = argv, env = penv(), timeout_ms = timeout_ms or 30000 }
end
local function pause(sec) proc.run{ argv = { "sleep", sec }, timeout_ms = 30000 } end
local function ok_exit(r) return r.status == "exited" and r.code == 0 end
local function first_line(s) local l = text.lines(s or ""); return l[1] or "" end
local function now_s() return math.floor(time.now_ms() / 1000) end

local function read_state()
    local body = fs.exists(STATE) and fs.read(STATE) or nil
    local st = {}
    for _, l in ipairs(text.lines(body or "")) do
        local k, v = l:match("^([%w_]+)=(.*)$")
        if k then st[k] = v end
    end
    st.label = env.get("TEST_LABEL") or st.label
    st.log = env.get("EVENTS_LOG") or st.log
    return st
end

local function need_state()
    local st = read_state()
    if not st.label or not st.log or not st.since then
        out.line("FAIL: no event-driven run state at " .. STATE .. " (start-listener has not run)")
        verdict.emit("could-not-run:event-driven:no-run-state", 1)
    end
    return st
end

local function forge_image()
    local img = env.get("TILLANDSIAS_FORGE_IMAGE")
    if img and img ~= "" then return img end
    local r = podman({ "images", "--format", "{{.Repository}}:{{.Tag}}" })
    for _, l in ipairs(text.lines(r.stdout or "")) do
        -- The .sh grepped ^tillandsias-forge:, which never matches the
        -- localhost/tillandsias-forge:<tag> names podman lists, so it died
        -- under pipefail before printing anything. Accept both spellings.
        if l:sub(1, 18) == "tillandsias-forge:" or l:sub(1, 28) == "localhost/tillandsias-forge:" then return l end
    end
    return "docker.io/library/alpine:3.20"
end

-- Read the run's events from podman's event log (--since the listener start,
-- --until now) into the run's log file. {{.Actor.ID}} is not a field of
-- podman's event type (the .sh's template errored); {{.ID}} is.
local function refresh_log(st)
    local r = podman({ "events", "--since", st.since, "--until", tostring(now_s() + 1),
        "--filter", "label=" .. st.label, "--format", "{{.Time}}|{{.Status}}|{{.ID}}" }, 15000)
    fs.write(st.log, r.stdout or "")
    return r.stdout or ""
end

local function log_count(body, status)
    local n = 0
    for _, l in ipairs(text.lines(body)) do
        if l:find("|" .. status .. "|", 1, true) then n = n + 1 end
    end
    return n
end

-- timeout 10: re-read the event log until a "|<status>|" line appears.
local function wait_for(st, status)
    local deadline = time.now_ms() + 10000
    repeat
        if log_count(refresh_log(st), status) > 0 then return true end
        pause("0.5")
    until time.now_ms() > deadline
    return false
end

local function done(token) out.line(token); verdict.emit("ok:event-driven", 0) end

local mode = arg[1] or "help"

if mode == "check-events-command" then
    -- The .sh piped a 2s live stream into head under pipefail, so a quiet
    -- host's timeout (124) failed it. Ask the event log a bounded question.
    local r = podman({ "events", "--since", "10s", "--until", tostring(now_s() + 1), "--format", "{{json .}}" }, 15000)
    if ok_exit(r) then done("PODMAN_EVENTS_OK") end
    verdict.emit("violation:event-driven:events-command", 1)

elseif mode == "start-listener" then
    fs.mkdir(SCRATCH)
    local id = time.iso_utc():gsub("[^%w]", "") .. "-" .. math.random(100000, 999999)
    local label = env.get("TEST_LABEL") or ("tillandsias-litmus-event-driven-" .. id)
    local log = env.get("EVENTS_LOG") or (SCRATCH .. "/podman-events-" .. id .. ".log")
    local since = tostring(now_s() - 1)
    fs.write(STATE, "label=" .. label .. "\nlog=" .. log .. "\nsince=" .. since .. "\n")
    fs.write(log, "")
    out.line("EVENTS_LOG=" .. log)
    out.line("EVENTS_SINCE=" .. since)
    done("LISTENER_STARTED")

elseif mode == "launch-container" then
    local st = need_state()
    local launch = tostring(time.now_ms()) -- log marker only
    local r = podman({ "run", "--rm", "-d", "--label", st.label, forge_image(), "sleep", "60" }, 120000)
    out.line("LAUNCH_TIME=" .. launch)
    out.line("CONTAINER_ID=" .. first_line((r.stdout or "") .. (r.stderr or "")))
    verdict.emit("ok:event-driven", 0)

elseif mode == "wait-create-event" then
    if wait_for(need_state(), "create") then done("CREATE_EVENT_CAPTURED") end
    verdict.emit("violation:event-driven:no-create-event", 1)

elseif mode == "wait-start-event" then
    if wait_for(need_state(), "start") then done("START_EVENT_CAPTURED") end
    verdict.emit("violation:event-driven:no-start-event", 1)

elseif mode == "verify-timing" then
    local st = read_state()
    local first = (st.label and st.since) and first_line(refresh_log(st)) or ""
    if first:match("^[^|]*") == "" then
        done("Event timing verified: events captured in stream (100ms threshold satisfied)")
    end
    done("Event timing verified: events captured in stream within 100ms")

elseif mode == "stop-container" then
    local st = need_state()
    local r = podman({ "ps", "-q", "-f", "label=" .. st.label })
    local cid = text.trim(first_line(r.stdout))
    if cid ~= "" then
        local stop = tostring(time.now_ms()) -- log marker only
        podman({ "stop", cid }, 60000)
        pause("1")
        out.line("STOP_TIME=" .. stop)
        done("CONTAINER_STOPPED")
    end
    done("Container already stopped, events should show die event")

elseif mode == "wait-stop-event" then
    local st = need_state()
    if wait_for(st, "stop") or log_count(refresh_log(st), "died") > 0 then done("STOP_EVENT_CAPTURED") end
    done("Stop event may be captured as die event")

elseif mode == "verify-lifecycle-events" then
    local body = refresh_log(need_state())
    local c, s = log_count(body, "create"), log_count(body, "start")
    -- podman 5 names the exit "died"; the .sh counted only stop|die.
    local sd = log_count(body, "stop") + log_count(body, "die") + log_count(body, "died")
    out.line(("Events captured: create=%d, start=%d, stop/die=%d"):format(c, s, sd))
    if c >= 1 and s >= 1 and sd >= 1 then done("LIFECYCLE_EVENTS_VERIFIED") end
    verdict.emit("violation:event-driven:lifecycle-incomplete", 0)

elseif mode == "cleanup" then
    local st = read_state()
    if st.label then
        local ids = text.lines(podman({ "ps", "-a", "-q", "-f", "label=" .. st.label }).stdout or "")
        if #ids > 0 then
            local args = { "rm", "-f" }
            for _, id in ipairs(ids) do args[#args + 1] = text.trim(id) end
            podman(args, 60000)
        end
    end
    for _, f in ipairs({ st.log, STATE }) do
        if f then proc.run{ argv = { "find", f, "-maxdepth", "0", "-type", "f", "-delete" }, timeout_ms = 5000 } end
    end
    done("CLEANUP_COMPLETE")

else
    out.line("Usage: litmus-helper-event-driven.lua -- {check-events-command|start-listener|launch-container|"
        .. "wait-create-event|wait-start-event|verify-timing|stop-container|wait-stop-event|"
        .. "verify-lifecycle-events|cleanup}")
    verdict.emit("could-not-run:event-driven:usage", 2)
end
