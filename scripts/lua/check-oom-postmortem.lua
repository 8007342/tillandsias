-- @trace order:1176-fn2p, order:1526-gv3t
--
-- check-oom-postmortem.lua — PORTED from check-oom-postmortem.sh, byte for
-- byte. After a child dies on a signal, ask the KERNEL whether it killed it
-- for memory — so a gate can say refused:gate:oom-killed instead of stopping
-- mid-line. SIGKILL leaves no exit path, so the victim writes nothing; the
-- kernel does record the kill, and this reads it back.
--
-- THREE STATES, NEVER TWO (965-sxec): "no OOM record" and "could not look"
-- must not collapse — a host whose journal this user cannot read would
-- otherwise report a confident not-OOM for every kill.
--
--   0  ok:no-oom-record         looked, and the kernel records no kill
--   1  refused:gate:oom-killed  the kernel records an OOM kill in the window
--   3  could-not-run:...        could not look, and says so
--
-- THE POSITIVE CONTROL IS NOT OPTIONAL (see the .sh's header for the
-- `journalctl -k -g <pattern>` "No entries" ambiguity this guards against).
--
-- proc.run replaces the .sh's three `journalctl` invocations one for one: an
-- existence+readability probe (--since SINCE), a widened retry (no --since)
-- when the first is empty, and the real fetch. `journalctl` not existing on
-- PATH is distinguished from it existing but the journal being unreadable by
-- proc.run's own `status == "spawn_failed"` — the Rust equivalent of the .sh's
-- separate `command -v journalctl` check — collapsed into one spawn attempt
-- rather than two, with the same three-way outcome.
--
-- --journal-from FILE (the fixture seam) reads the file with fs.read, which
-- is repo-rooted: a fixture plants its stand-in journal under
-- target/plan-scratch, inside the repository, rather than outside it.
--
-- WHAT THE PORT MAKES UNREPRESENTABLE RATHER THAN AVOIDS, TWO THINGS:
--
-- (1) the .sh's usage error (`check-oom-postmortem.sh --bad-flag`) printed
-- NOTHING on stdout, only a usage line to stderr, exit 2. The runner that
-- hosts every Lua decider always emits exactly one stdout verdict line, so
-- this port prints one new stdout line (`blocked:oom-postmortem:usage`) on
-- that path only. This flag-parsing branch has no caller that passes an
-- unrecognised flag (build.sh and land-on-platform-branch.sh both call with
-- fixed, valid arguments) and no fixture exercises it.
--
-- (2) on refused:gate:oom-killed, the .sh printed its verdict line FIRST on
-- stdout and then `tail -3` of the matching kernel lines ALSO on stdout, with
-- no redirect — three more stdout lines than its own documented "one line on
-- stdout" grammar promised. The runner's verdict call is terminal (the first
-- call ends the script), so it cannot emit a line and then more lines after
-- it the way the .sh's straight-line code could. This port keeps the exact
-- verdict line and moves the tail-3 detail lines to stderr via log.raw
-- instead. SWEPT: both live callers (build.sh's `_run`, 1176-fn2p;
-- land-on-platform-branch.sh) capture the checker's stdout+stderr TOGETHER
-- (`2>&1`) into one variable and branch only on the exit code — the detail
-- lines are dumped back out verbatim either way, so which stream they
-- originated on is unobservable to either consumer.
--
-- Verdict grammar, one line on stdout (unchanged on every exercised path):
--   ok:no-oom-record (kernel journal readable and records no OOM kill in the last <since>...)
--   refused:gate:oom-killed (the kernel records an OOM kill in the last <since>...)
--   could-not-run:oom-postmortem:unreadable-seam:<file>
--   could-not-run:oom-postmortem:no-journalctl (...)
--   could-not-run:oom-postmortem:kernel-journal-unreadable (...)
local SINCE = "-15min"
local VICTIM = ""
local JOURNAL_FROM = nil

local i = 1
while i <= #arg do
    local a = arg[i]
    if a == "--since" then
        SINCE = arg[i + 1] or ""
        i = i + 2
    elseif a == "--victim" then
        VICTIM = arg[i + 1] or ""
        i = i + 2
    elseif a == "--journal-from" then
        JOURNAL_FROM = arg[i + 1] or ""
        i = i + 2
    else
        log.raw("usage: check-oom-postmortem.sh [--since SPEC] [--victim NAME] [--journal-from FILE]")
        verdict.emit("blocked:oom-postmortem:usage", 2)
    end
end

local OOM_PATTERN = [[Out of memory|oom-kill|Killed process|oom_reaper]]

local function strip_separator_lines(s)
    local kept = {}
    for _, l in ipairs(text.lines(s)) do
        if not text.is_match(l, [=[^-- ]=]) then kept[#kept + 1] = l end
    end
    return table.concat(kept, "\n")
end

local lines_text
local control_ok = false

if JOURNAL_FROM ~= nil and JOURNAL_FROM ~= "" then
    local ok, content = pcall(fs.read, JOURNAL_FROM)
    if not ok then
        verdict.emit("could-not-run:oom-postmortem:unreadable-seam:" .. JOURNAL_FROM, 3)
    end
    lines_text = content
    control_ok = true
else
    local p1 = proc.run({ argv = { "journalctl", "-k", "--since", SINCE, "-n", "1", "--no-pager" } })
    if p1.status == "spawn_failed" then
        verdict.emit(
            "could-not-run:oom-postmortem:no-journalctl (this host records no readable kernel log here; nothing is asserted about why the child died)",
            3
        )
    end
    local probe = (p1.status == "exited") and strip_separator_lines(p1.stdout) or ""
    if probe == "" then
        -- Widen once before concluding: a genuinely quiet window on an idle
        -- host is possible, and would otherwise read as "cannot see".
        local p2 = proc.run({ argv = { "journalctl", "-k", "-n", "1", "--no-pager" } })
        probe = (p2.status == "exited") and strip_separator_lines(p2.stdout) or ""
    end
    if probe == "" then
        verdict.emit(
            "could-not-run:oom-postmortem:kernel-journal-unreadable (no kernel line is readable by this user, so an empty OOM search proves nothing)",
            3
        )
    end
    control_ok = true
    local r = proc.run({ argv = { "journalctl", "-k", "--since", SINCE, "--no-pager" } })
    lines_text = (r.status == "exited") and r.stdout or ""
end

if not control_ok then
    verdict.emit("could-not-run:oom-postmortem:no-control", 3)
end

local hits = {}
for _, l in ipairs(text.lines(lines_text)) do
    if text.is_match(l, OOM_PATTERN) then hits[#hits + 1] = l end
end

if VICTIM ~= "" and #hits > 0 then
    local filtered = {}
    for _, l in ipairs(hits) do
        if text.contains(l, VICTIM) then filtered[#filtered + 1] = l end
    end
    hits = filtered
end

local function victim_suffix()
    if VICTIM ~= "" then return " naming " .. VICTIM end
    return ""
end

if #hits > 0 then
    local tail_start = math.max(1, #hits - 2)
    for j = tail_start, #hits do log.raw("  " .. hits[j]) end
    verdict.emit(
        "refused:gate:oom-killed (the kernel records an OOM kill in the last " .. SINCE .. victim_suffix() .. ")",
        1
    )
end

verdict.emit(
    "ok:no-oom-record (kernel journal readable and records no OOM kill in the last " .. SINCE .. victim_suffix() .. ")",
    0
)
