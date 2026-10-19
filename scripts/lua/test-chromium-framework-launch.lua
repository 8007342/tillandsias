-- @trace order:612-nvf3, order:1656-6c97
-- @env PATH
--
-- test-chromium-framework-launch.lua — images/chromium/chromium-framework-launch.sh
-- (the chromium-framework image's entrypoint) adds --no-sandbox exactly when
-- the Chromium wrapper accepts it. Chromium's setuid sandbox cannot start
-- under the window container's --cap-drop=ALL plus no-new-privileges (the
-- container exits 21), and Fedora's wrapper accepts --no-sandbox without
-- advertising it in --help, so the launcher PROBES (612-nvf3). The Lua port of
-- scripts/test-chromium-framework-launch.sh, which nothing ran (1656-6c97).
--
--   1 ACCEPTS   a Fedora-shape wrapper (accepts --no-sandbox, does not
--               advertise it) is exec'd with --no-sandbox and the caller's flag
--   2 REJECTS   a wrapper that rejects --no-sandbox is exec'd without it
--   3 MUTANT A  the launcher with the probe DROPPED (never adds the flag): arm 1
--               must go red, so this fixture sees a launcher that leaves every
--               window to exit 21
--   4 MUTANT B  the launcher with the probe made UNCONDITIONAL: arm 2 must go
--               red, so this fixture sees a launcher that breaks a strict wrapper
--
-- Hermetic: the wrappers and mutants live in a fresh target/plan-scratch dir;
-- the real launcher is only read.
--
-- Usage: tillandsias-plan script run scripts/lua/test-chromium-framework-launch.lua

local LAUNCHER = "images/chromium/chromium-framework-launch.sh"
if not fs.exists(LAUNCHER) then
    verdict.emit("violation:chromium-framework-launch:no-launcher", 1, LAUNCHER .. " does not exist")
end

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
local REL = "target/plan-scratch/chromium-launch-" .. time.iso_utc():gsub("[^%w]", "") .. "-" .. tostring(math.random(100000, 999999))
fs.mkdir(REL)
local DIR = ROOT .. "/" .. REL

-- A fake `chromium` on PATH. Every exec that is not the probe records its argv
-- (one per line) to $TILLANDSIAS_LAUNCH_REC.
local ACCEPTING = [=[#!/usr/bin/env bash
if [[ "$*" == *"--help"* ]]; then echo "Usage: chromium [OPTIONS]"; exit 0; fi
if [[ "$*" == *"--version"* ]]; then echo "Chromium 150.0.0.0 Fedora"; exit 0; fi
printf '%s\n' "$@" > "$TILLANDSIAS_LAUNCH_REC"
]=]
local REJECTING = [=[#!/usr/bin/env bash
if [[ "$*" == *"--no-sandbox"* ]]; then echo "chromium: unknown option --no-sandbox" >&2; exit 1; fi
if [[ "$*" == *"--version"* ]]; then echo "Chromium Strict 150.0.0.0"; exit 0; fi
printf '%s\n' "$@" > "$TILLANDSIAS_LAUNCH_REC"
]=]

local function install(name, body)
    fs.mkdir(REL .. "/" .. name)
    fs.write(REL .. "/" .. name .. "/chromium", body)
    proc.run({ argv = { "chmod", "0755", DIR .. "/" .. name .. "/chromium" }, timeout_ms = 5000 })
    return DIR .. "/" .. name
end
local BIN_ACCEPT = install("accepting", ACCEPTING)
local BIN_REJECT = install("rejecting", REJECTING)
-- 1769-9gna made the launcher source the image's audio-start helper, which
-- does not exist outside the image; the fixture judges argv, not audio.
fs.write(REL .. "/audio-start.sh", "# fixture stub: no audio server\n")

-- Run `launcher --custom-flag` against one wrapper; return the exec'd argv
-- as a set, or nil when the wrapper was never exec'd.
local runs = 0
local function exec_argv(launcher, bin)
    runs = runs + 1
    local rec = DIR .. "/rec-" .. runs
    proc.run({
        argv = { "bash", launcher, "--custom-flag" },
        cwd = ROOT,
        env = { PATH = bin .. ":" .. (env.get("PATH") or "/usr/bin:/bin"), TILLANDSIAS_LAUNCH_REC = rec,
                TILLANDSIAS_BROWSER_AUDIO_START = DIR .. "/audio-start.sh" },
        timeout_ms = 30000,
    })
    local ok, body = pcall(fs.read, REL .. "/rec-" .. runs)
    if not ok then return nil end
    local set, n = {}, 0
    for _, l in ipairs(text.lines(body)) do
        set[l] = (set[l] or 0) + 1
        n = n + 1
    end
    return set, n
end

-- arm results for one launcher: accepts_ok, rejects_ok, detail
local function judge(launcher)
    local a = exec_argv(launcher, BIN_ACCEPT)
    local r = exec_argv(launcher, BIN_REJECT)
    local accepts_ok = a ~= nil and a["--no-sandbox"] == 1 and a["--custom-flag"] == 1
    local rejects_ok = r ~= nil and r["--no-sandbox"] == nil and r["--custom-flag"] == 1
    return accepts_ok, rejects_ok
end

local failed = {}
local function arm(name, cond)
    if cond then out.line("ok:   " .. name) else
        out.line("FAIL: " .. name)
        failed[#failed + 1] = name
    end
end

local acc, rej = judge(ROOT .. "/" .. LAUNCHER)
arm("1 ACCEPTS: a wrapper that accepts --no-sandbox is exec'd with it", acc)
arm("2 REJECTS: a wrapper that rejects --no-sandbox is exec'd without it", rej)

-- The mutants rewrite one anchor each in a COPY. A missing anchor fails that
-- arm (the launcher changed shape; update this fixture with it), after arms
-- 1 and 2 have already said what the real launcher does.
local real = fs.read(LAUNCHER)
local function mutant(name, from, to)
    local body, n = real:gsub(from, to, 1)
    if n ~= 1 then return nil end
    fs.write(REL .. "/" .. name .. ".sh", body)
    return DIR .. "/" .. name .. ".sh"
end
-- A: the probe dropped: the flag is never added.
local DROPPED = mutant("probe-dropped", 'ARGS%+=%("%-%-no%-sandbox"%)', ':')
-- B: the probe made unconditional: the flag is always added.
local ALWAYS = mutant("probe-always", 'if accepts_no_sandbox "%$CHROMIUM_BIN"; then', 'if true; then')
local a_acc, a_rej, b_acc, b_rej = false, false, false, false
if DROPPED then a_acc, a_rej = judge(DROPPED) end
if ALWAYS then b_acc, b_rej = judge(ALWAYS) end
arm("3 MUTANT A: with the probe dropped, arm 1 goes red (and arm 2 stays green)"
    .. (DROPPED and "" or " [anchor ARGS+=(\"--no-sandbox\") not found]"), DROPPED ~= nil and (not a_acc) and a_rej)
arm("4 MUTANT B: with the probe unconditional, arm 2 goes red (and arm 1 stays green)"
    .. (ALWAYS and "" or " [anchor `if accepts_no_sandbox` not found]"), ALWAYS ~= nil and b_acc and not b_rej)

proc.run({ argv = { "find", DIR, "-delete" }, timeout_ms = 30000 })

if #failed > 0 then
    verdict.emit("violation:chromium-framework-launch:" .. #failed .. ":of:4", 1, table.concat(failed, "; "))
end
verdict.emit("ok:chromium-framework-launch:4:of:4", 0)
