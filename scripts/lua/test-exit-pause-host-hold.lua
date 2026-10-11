-- @trace order:1457-r8yi, order:1600-h359, spec:simplified-tray-ux
--
-- test-exit-pause-host-hold.lua — the Lua port of test-exit-pause-host-hold.sh.
--
-- A Linux lane that fails inside the container used to ask for TWO keypresses:
-- the entrypoint's exit_pause ("Press any key") and then the host's
-- `tillandsias --hold-window` ("Press Enter"). The host now passes
-- TILLANDSIAS_HOST_HOLDS_WINDOW=1 into the forge by name, and exit_pause skips
-- its own pause when it is set. It does NOT delete the traps (828-h7kw: all six
-- are live, and they are the only hold on the macOS and Windows lanes).
--
-- For EACH of the six entrypoints, its real exit_pause is extracted and run on a
-- real pseudo-terminal (script(1)), since the pause only happens when stdin is a
-- TTY, after a failing command:
--   held   -> the error banner is printed, no "Press any key", returns before the deadline
--   unheld -> CONTROL: it still blocks on the keypress (the deadline fires), so the
--             pause exists and only the held case skips it
-- PLANTED FAILURES (1600-h359), through the same arms: an exit_pause that
-- ignores the hold must red the held arm, and one that never pauses must red the
-- unheld control. If either is not caught, the arms cannot see what they claim.
--
-- PORTABILITY. The .sh called the util-linux form `script -qec CMD /dev/null`,
-- which BSD script (darwin) refuses with `illegal option -- c`. So on darwin it
-- printed fail:exit-pause-host-hold:0/6 and still exited 0. The flavor is now
-- PROBED: util-linux `-qec CMD FILE`, or BSD `-q FILE CMD...`. The deadline is
-- proc.run's timeout_ms, so timeout(1) is not needed. stdin must stay OPEN past
-- the deadline: with /dev/null the pty sees EOF at once, `read` returns, and
-- neither arm could tell a pause from none. proc.run gives a child only
-- /dev/null or fixed bytes, so each arm runs a generated runner FILE (argv
-- `bash <file>`, never a `-c` string) that feeds script(1) from `< <(sleep 8)`
-- and writes its pty output to a file. proc.run does not keep a timed-out
-- child's stdout, and the file does.
--
-- Verdicts (as the .sh):
--   ok:exit-pause-host-hold:<n>/<n>                        exit 0
--   violation:exit-pause-host-hold:<pass>/<total>          exit 1  (the .sh said fail:,
--                                                         which verdict.emit does not accept)
--   could-not-run:exit-pause-host-hold:no-repo-root       exit 3
--   skip:exit-pause-host-hold:no-script                    exit 3
--
-- Usage: tillandsias-plan script run scripts/lua/test-exit-pause-host-hold.lua

local ENTRYPOINTS = {
    "entrypoint-forge-antigravity", "entrypoint-forge-claude", "entrypoint-forge-codex",
    "entrypoint-forge-opencode", "entrypoint-forge-opencode-web", "entrypoint-terminal",
}

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
-- An unanswered git (e.g. "dubious ownership" in a container) must not become
-- six false "no exit_pause function found" premises read from /images/... .
if top.status ~= "exited" or top.code ~= 0 or ROOT == "" then
    verdict.emit("could-not-run:exit-pause-host-hold:no-repo-root", 3,
        "git rev-parse --show-toplevel did not answer (" .. tostring(top.status) .. "/" .. tostring(top.code) .. "): " .. text.trim(top.stderr or ""))
end
local REL = "target/plan-scratch/exit-pause-hold-" .. time.iso_utc() .. "-" .. tostring(math.random(100000, 999999))
local W = ROOT .. "/" .. REL
fs.mkdir(REL)

-- ── which script(1) ────────────────────────────────────────────────────────
local function rc0(argv)
    local r = proc.run({ argv = argv, timeout_ms = 10000 })
    return r.status == "exited" and r.code == 0
end
local FLAVOR
if rc0({ "script", "-qec", "true", "/dev/null" }) then FLAVOR = "util-linux"
elseif rc0({ "script", "-q", "/dev/null", "true" }) then FLAVOR = "bsd" end
if not FLAVOR then
    verdict.emit("skip:exit-pause-host-hold:no-script", 3,
        "no script(1) in either the util-linux (-qec CMD FILE) or the BSD (-q FILE CMD) form: no pty to run exit_pause on")
end
out.line("# script(1) flavor: " .. FLAVOR)

local pass, fail = 0, 0
-- pty output is raw bytes (escape sequences, ^D, partial UTF-8): printing it
-- unsanitised aborts out.line on invalid UTF-8, which turned a red arm into a
-- script error instead of a verdict.
local function clean(s) return (tostring(s or ""):gsub("\r", ""):gsub("\n", " "):gsub("[^\32-\126]", "?")) end
local function ok(s) out.line("ok:   " .. s); pass = pass + 1 end
local function bad(s) out.line("FAIL: " .. s); fail = fail + 1 end

-- The exit_pause function, from `exit_pause() {` to the first `}` line, as the
-- .sh's awk extracted it.
local function extract(src)
    local okr, text_ = pcall(fs.read, src)
    if not okr then return nil end
    local acc, on = {}, false
    for l in (text_ .. "\n"):gmatch("(.-)\n") do
        if l:match("^exit_pause%(%) {") then on = true end
        if on then
            acc[#acc + 1] = l
            if l == "}" then break end
        end
    end
    if #acc == 0 then return nil end
    return table.concat(acc, "\n")
end

-- One arm: run `name`'s harness on a pty and report (timed_out, output).
local function on_pty(name, held, deadline_ms)
    local harness, outf = W .. "/" .. name .. ".sh", W .. "/" .. name .. (held and ".held" or ".unheld")
    local cmd
    if FLAVOR == "util-linux" then
        cmd = "script -qec 'bash " .. harness .. "' /dev/null"
    else
        cmd = "script -q /dev/null bash " .. harness
    end
    local runner = REL .. "/" .. name .. (held and ".held" or ".unheld") .. ".run"
    fs.write(runner, "exec " .. cmd .. " < <(exec 2>/dev/null; sleep 8) > " .. outf .. " 2>&1\n")
    local env_t = held and { TILLANDSIAS_HOST_HOLDS_WINDOW = "1" } or {}
    local r = proc.run({ argv = { "bash", ROOT .. "/" .. runner }, env = env_t, timeout_ms = deadline_ms })
    local okf, o = pcall(fs.read, REL .. "/" .. name .. (held and ".held" or ".unheld"))
    return r.status == "timed_out", (okf and o or ""), r
end

-- held then unheld for one exit_pause body; returns ok-or-reason for each.
local function judge(name, fn)
    -- HOLD= is diagnostic only (not judged): it shows whether the variable
    -- reached the shell inside the pty, which util-linux script(1) starts via
    -- $SHELL -c and BSD script execs directly.
    fs.write(REL .. "/" .. name .. ".sh", fn .. "\necho \"HOLD=${TILLANDSIAS_HOST_HOLDS_WINDOW:-unset}\"\ntrap exit_pause EXIT\nfalse\nexit 1\n")
    local h_to, h_out, h_r = on_pty(name, true, 5000)
    local held
    if not h_to and h_out:find("ERROR", 1, true) and not h_out:find("Press any key", 1, true) then held = "ok"
    else
        held = "status=" .. tostring(h_r.status) .. " code=" .. tostring(h_r.code) ..
            " out=[" .. clean(h_out):sub(-160) .. "] runner-stderr=[" .. clean(h_r.stderr):sub(-160) .. "]"
    end
    local u_to, u_out, u_r = on_pty(name, false, 3000)
    local unheld = (u_to and u_out:find("Press any key", 1, true)) and "ok"
        or ("status=" .. tostring(u_r.status) .. " code=" .. tostring(u_r.code) .. " out=[" .. clean(u_out):sub(-160) ..
            "] runner-stderr=[" .. clean(u_r.stderr):sub(-160) .. "]")
    return held, unheld
end

for _, ep in ipairs(ENTRYPOINTS) do
    local fn = extract(ROOT .. "/images/default/" .. ep .. ".sh")
    if not fn then bad(ep .. ": premise: no exit_pause function found")
    else
        local held, unheld = judge(ep, fn)
        if held == "ok" and unheld == "ok" then ok(ep .. ": held -> banner, no second pause; unheld -> still pauses")
        else bad(ep .. ": held=[" .. held .. "] unheld=[" .. unheld .. "]") end
    end
end

-- ── planted failures: the arms must see what they claim ────────────────────
local IGNORES_HOLD = table.concat({
    "exit_pause() {",
    "    local exit_code=$?",
    "    if [ $exit_code -ne 0 ] && [ -t 0 ]; then",
    "        echo \"ERROR: planted (exit code: $exit_code)\"",
    "        echo \"Press any key to exit...\"",
    "        read -r -n 1 -s 2>/dev/null || true",
    "    fi",
    "}",
}, "\n")
local NEVER_PAUSES = table.concat({
    "exit_pause() {",
    "    local exit_code=$?",
    "    if [ $exit_code -ne 0 ] && [ -t 0 ]; then",
    "        echo \"ERROR: planted (exit code: $exit_code)\"",
    "    fi",
    "}",
}, "\n")
local p_held = judge("planted-ignores-hold", IGNORES_HOLD)
if p_held ~= "ok" then ok("planted: an exit_pause that ignores the hold reds the held arm")
else bad("planted: an exit_pause that ignores the hold PASSED the held arm (the arm is blind)") end
local _, p_unheld = judge("planted-never-pauses", NEVER_PAUSES)
if p_unheld ~= "ok" then ok("planted: an exit_pause that never pauses reds the unheld control")
else bad("planted: an exit_pause that never pauses PASSED the unheld control (the control is blind)") end

local total = pass + fail
if fail == 0 then
    -- The verdict counts the six real entrypoints, as the .sh did; the two
    -- planted arms are printed above and fail the run if blind.
    verdict.emit("ok:exit-pause-host-hold:" .. (pass - 2) .. "/" .. (total - 2), 0)
end
verdict.emit("violation:exit-pause-host-hold:" .. pass .. "/" .. total, 1)
