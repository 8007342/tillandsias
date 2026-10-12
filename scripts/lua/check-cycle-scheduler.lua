-- @trace order:856-s56y, order:1624-bv73
-- @env TILLANDSIAS_CYCLE_STATE_DIR XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS HOME USER PATH
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

local function fwd(names)
    local e = {}
    for _, n in ipairs(names) do
        local v = env.get(n)
        if v and v ~= "" then e[n] = v end
    end
    return e
end
local ENV = fwd({ "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS", "HOME", "USER", "PATH" })
ENV.LC_ALL = "C"

local function sh(argv)
    local r = proc.run({ argv = argv, env = ENV, timeout_ms = 15000 })
    local ok = r.status == "exited" and r.code == 0
    return ok, (r.stdout or "")
end
local function first_line(s) return (s or ""):match("^([^\n]*)") or "" end
local function trim(s) return (s or ""):match("^%s*(.-)%s*$") end

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

local dir = env.get("TILLANDSIAS_CYCLE_STATE_DIR")
if not dir or dir == "" then dir = (env.get("HOME") or "") .. "/.cache/tillandsias" end
local LAST, LASTRC = "never", "none"
-- The log lives under $HOME, outside the repo, where fs.read is refused (it
-- widens only to `-- @read-env` roots, and widening to all of $HOME would be
-- far broader than one file). So read its last line the way the .sh did.
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

verdict.ok("cycle-scheduler", "next=" .. NEXT, "last=" .. LAST, "lastrc=" .. LASTRC)
