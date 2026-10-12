-- @trace order:856-s56y, order:1624-bv73, order:858-3v74
-- @env TILLANDSIAS_CYCLE_STATE_DIR XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS HOME USER PATH OS SystemRoot USERPROFILE TILLANDSIAS_CYCLE_TASK_NAME
--
-- check-cycle-scheduler.lua — is a durable unattended-cycle scheduler armed on
-- THIS host, and what did it last do? (856-s56y exit criterion 5: an operator
-- asks "when did you last fire, when do you fire next, did the last one
-- succeed" without reading a transcript.) ADVISORY, never a gate.
--
-- Ported from scripts/check-cycle-scheduler.sh as the carried shell-to-lua item
-- of 1624-bv73. Linux/systemd implementation; the launchd and Task Scheduler
-- children of 856-s56y answer the same grammar on their platforms.
--
-- Verdict grammar (exactly one line on stdout). Exit codes are the .sh's;
-- only the non-ok TOKENS changed, because a Lua decider must end on a verdict
-- prefix and `due:` / `unavailable:` are not ones:
--   ok:cycle-scheduler:next=<ts|pending-current-cycle>:last=<ts|never>:lastrc=<n|none>   exit 0  (unchanged)
--   blocked:cycle-scheduler:not-installed     exit 1  (was due:not-installed)  run scripts/install-cycle-timer.sh
--   blocked:cycle-scheduler:timer-inactive    exit 1  (was due:timer-inactive) systemctl --user start
--   blocked:cycle-scheduler:linger-off        exit 1  (was due:linger-off)     loginctl enable-linger
--   could-not-run:cycle-scheduler:no-systemd-user  exit 2  (was unavailable:no-systemd-user)
--
-- proc.run children start from a scrubbed environment, and `systemctl --user`
-- needs the session bus, so the variables it reads are forwarded explicitly.
--
-- WINDOWS (858-3v74): the scheduler is the Task Scheduler task that
-- packaging/windows/install-cycle-task.ps1 registers (TillandsiasCycle, or
-- TILLANDSIAS_CYCLE_TASK_NAME), asked through schtasks.exe. The same ok line;
-- the non-ok lines are the Linux ones' analogues:
--   blocked:cycle-scheduler:not-installed       exit 1  run install-cycle-task.ps1
--   blocked:cycle-scheduler:task-disabled       exit 1  schtasks /change /tn <task> /enable
--   blocked:cycle-scheduler:logon-interactive   exit 1  the task runs only while you are logged
--                                                       on (linger-off's analogue): re-run the
--                                                       installer with -LogonType S4U or Password
--   could-not-run:cycle-scheduler:no-schtasks   exit 2
-- PowerShell would be the natural reader, but proc.run refuses a shell given a
-- command string (command_policy SHELL_PROGRAMS), so schtasks it is. Its CSV
-- prints dates in the user's short-date and time formats, so those formats
-- are read from the registry and turned into a pattern; a format with month
-- names reads as next=unparseable, never as a guessed date.

local function fwd(names)
    local e = {}
    for _, n in ipairs(names) do
        local v = env.get(n)
        if v and v ~= "" then e[n] = v end
    end
    return e
end
local ENV = fwd({ "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS", "HOME", "USER", "PATH", "SystemRoot" })
ENV.LC_ALL = "C"

local function sh(argv)
    local r = proc.run({ argv = argv, env = ENV, timeout_ms = 15000 })
    local ok = r.status == "exited" and r.code == 0
    return ok, (r.stdout or "")
end
local function first_line(s) return (s or ""):match("^([^\n]*)") or "" end
local function trim(s) return (s or ""):match("^%s*(.-)%s*$") end

-- The driver's last JSONL record: when the last fire ended and its exit code.
-- The log lives under $HOME, outside the repo, where fs.read is refused (it
-- widens only to `-- @read-env` roots, and widening to all of $HOME would be
-- far broader than one file). So read its last line the way the .sh did.
local function read_last()
    local dir = env.get("TILLANDSIAS_CYCLE_STATE_DIR")
    if not dir or dir == "" then
        local home = env.get("HOME")
        if not home or home == "" then home = env.get("USERPROFILE") or "" end
        dir = home .. "/.cache/tillandsias"
    end
    local LAST, LASTRC = "never", "none"
    local tok, last = sh({ "tail", "-n", "1", dir .. "/cycle-scheduler.jsonl" })
    last = first_line(last)
    if tok and last ~= "" then
        -- The .sh's `sed -n 's/.*"key":…/'` is greedy: it reads the LAST occurrence.
        LAST, LASTRC = "", ""
        for v in last:gmatch('"ts_end":"([^"]*)"') do LAST = v end
        for v in last:gmatch('"rc":(%d*)') do LASTRC = v end
        if LAST == "" then LAST = "never" end
        if LASTRC == "" then LASTRC = "none" end
    end
    return LAST, LASTRC
end

-- ── Windows: Task Scheduler (858-3v74) ──────────────────────────────────────
-- A Windows date/time format string (sShortDate, sTimeFormat) -> an anchored
-- Lua pattern and the field each capture fills; nil for a format this cannot
-- read numerically (month or day names).
local function win_pattern(fmt, fields)
    local pat, i = "", 1
    while i <= #fmt do
        local c = fmt:sub(i, i)
        local j = i
        while fmt:sub(j + 1, j + 1) == c do j = j + 1 end
        local n = j - i + 1
        local field = ({ d = "day", M = "month", y = "year", H = "hour24", h = "hour12",
            m = "min", s = "sec", t = "ampm" })[c]
        if field then
            if (c == "d" or c == "M") and n > 2 then return nil end
            fields[#fields + 1] = field
            pat = pat .. (field == "ampm" and "(%S+)" or "(%d+)")
        else
            pat = pat .. fmt:sub(i, j):gsub("%p", "%%%0")
        end
        i = j + 1
    end
    return pat
end

local function win_date_to_utc(s, datefmt, timefmt)
    local fields = {}
    local dp = win_pattern(datefmt, fields)
    local tp = dp and win_pattern(timefmt, fields)
    if not tp then return nil end
    local caps = { s:match("^" .. dp .. "%s+" .. tp .. "$") }
    if #caps ~= #fields then return nil end
    local v = {}
    for k, f in ipairs(fields) do v[f] = caps[k] end
    local year, month, day = tonumber(v.year), tonumber(v.month), tonumber(v.day)
    local hour, min, sec = tonumber(v.hour24 or v.hour12), tonumber(v.min), tonumber(v.sec or "0")
    if not (year and month and day and hour and min and sec) then return nil end
    if year < 100 then year = year + 2000 end
    if v.hour12 and v.ampm then
        if v.ampm:match("^[Pp]") and hour < 12 then hour = hour + 12 end
        if v.ampm:match("^[Aa]") and hour == 12 then hour = 0 end
    end
    -- os.time reads the table as LOCAL time, which is what schtasks printed.
    local t = os.time({ year = year, month = month, day = day, hour = hour, min = min, sec = sec })
    return os.date("!%Y-%m-%dT%H:%M:%SZ", t)
end

local function reg_value(name)
    local _, out = sh({ "reg.exe", "query", [[HKCU\Control Panel\International]], "/v", name })
    return out:match(name .. "%s+REG_SZ%s+([^\r\n]+)")
end

if env.get("OS") == "Windows_NT" then
    local task = env.get("TILLANDSIAS_CYCLE_TASK_NAME")
    if not task or task == "" then task = "TillandsiasCycle" end
    local r = proc.run({ argv = { "schtasks.exe", "/query", "/tn", task, "/fo", "csv", "/v", "/nh" },
        env = ENV, timeout_ms = 15000 })
    if r.status ~= "exited" then verdict.emit("could-not-run:cycle-scheduler:no-schtasks", 2) end
    if r.code ~= 0 then verdict.emit("blocked:cycle-scheduler:not-installed", 1) end
    -- One CSV row per trigger; columns: 3 Next Run Time, 4 Status.
    local rows = {}
    for line in (r.stdout or ""):gmatch("[^\r\n]+") do
        local cols, inner = {}, line:match('^"(.*)"$')
        if inner then
            for f in (inner .. '","'):gmatch('(.-)","') do cols[#cols + 1] = f end
            rows[#rows + 1] = cols
        end
    end
    if #rows == 0 then verdict.emit("blocked:cycle-scheduler:not-installed", 1) end
    local _, xml = sh({ "schtasks.exe", "/query", "/tn", task, "/xml" })
    if rows[1][4] == "Disabled" or xml:match("<Settings>.-<Enabled>false</Enabled>") then
        verdict.emit("blocked:cycle-scheduler:task-disabled", 1)
    end
    local logon = xml:match("<LogonType>(%w+)</LogonType>") or "InteractiveToken"
    if logon == "InteractiveToken" then verdict.emit("blocked:cycle-scheduler:logon-interactive", 1) end

    local NEXT
    for _, cols in ipairs(rows) do
        if cols[4] == "Running" then NEXT = "pending-current-cycle" end
    end
    if not NEXT then
        local datefmt, timefmt = reg_value("sShortDate"), reg_value("sTimeFormat")
        local best, seen = nil, false
        for _, cols in ipairs(rows) do
            local raw = cols[3] or ""
            if raw ~= "" and raw ~= "N/A" then
                seen = true
                local iso = datefmt and timefmt and win_date_to_utc(raw, datefmt, timefmt)
                if iso and (not best or iso < best) then best = iso end
            end
        end
        NEXT = best or (seen and "unparseable" or "unscheduled")
    end
    local LAST, LASTRC = read_last()
    verdict.ok("cycle-scheduler", "next=" .. NEXT, "last=" .. LAST, "lastrc=" .. LASTRC)
end

local NO_SYSTEMD = "could-not-run:cycle-scheduler:no-systemd-user"
local ok_sc = sh({ "systemctl", "--version" })
if not ok_sc then verdict.emit(NO_SYSTEMD, 2) end
if not sh({ "systemctl", "--user", "show-environment" }) then verdict.emit(NO_SYSTEMD, 2) end

local _, state = sh({ "systemctl", "--user", "show", "tillandsias-cycle.timer", "--property=ActiveState", "--value" })
state = trim(state)
-- The .sh read `[ -z "$state" ] || [ "$state" = inactive ] && ! systemctl --user cat …`,
-- i.e. (empty OR inactive) AND the unit file is absent.
if (state == "" or state == "inactive") and not sh({ "systemctl", "--user", "cat", "tillandsias-cycle.timer" }) then
    verdict.emit("blocked:cycle-scheduler:not-installed", 1)
end
if state ~= "active" then verdict.emit("blocked:cycle-scheduler:timer-inactive", 1) end

local user = env.get("USER") or ""
local _, linger = sh({ "loginctl", "show-user", user, "--property=Linger", "--value" })
if trim(linger) ~= "yes" then verdict.emit("blocked:cycle-scheduler:linger-off", 1) end

-- Two systemd property traps, both measured live on systemd 258: `show` prints
-- timestamp properties as FORMATTED strings despite the USec name, and for a
-- monotonic (OnUnitInactiveSec) timer NextElapseUSecRealtime is UNSET even
-- while `list-timers` computes the wall-clock NEXT. So read list-timers
-- (LC_ALL=C pins the column format), whose NEXT is `-` exactly when the
-- service is currently running.
local _, lt = sh({ "systemctl", "--user", "list-timers", "tillandsias-cycle.timer", "--no-legend", "--no-pager" })
local cols = {}
for w in first_line(lt):gmatch("%S+") do cols[#cols + 1] = w end
local next_raw = table.concat({ cols[1] or "", cols[2] or "", cols[3] or "", cols[4] or "" }, " ")
local NEXT
if next_raw:match("^%- ") or trim(next_raw) == "" then
    NEXT = "pending-current-cycle"
else
    -- gnu-date: reachable only on Linux, past the systemctl --user guards above.
    local dok, d = sh({ "date", "-u", "-d", next_raw, "+%FT%TZ" })
    NEXT = dok and trim(d) ~= "" and trim(d) or "unparseable"
end

local LAST, LASTRC = read_last()
verdict.ok("cycle-scheduler", "next=" .. NEXT, "last=" .. LAST, "lastrc=" .. LASTRC)
