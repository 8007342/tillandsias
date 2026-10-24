-- @trace spec:host-state-lifecycle, order:1738-wqmt
--
-- test-install-linux-setup-is-quiet.lua — install.sh runs the SOFT reset and
-- only the SOFT reset, keeps the binary's reset output in the setup log, and
-- prints no power-user text. The Linux twin of
-- scripts/test-install-macos-setup-is-quiet.sh (1437-8c6p).
--
-- Operator ruling 2026-10-08, verbatim: "SOFT reset is the default only and
-- forever. ... we do not need to print any power user messages during install,
-- at all. Install should be for END USER (NOT POWER USER) and be a pretty
-- installer, rather than an informational/debugging installer." MEASURED by
-- yoga installing v56.10.14.1 (2026-10-15): install.sh ran
-- `--reset-state --debug` on the terminal and printed the flag name.
--
-- HOW IT TESTS. The real installer writes ~/.local/bin and resets podman, so it
-- never runs here. This RUNS the installer's own reset block (between
-- `# BEGIN-SETUP-RESET` and `# END-SETUP-RESET`, cut from the file, not copied)
-- in bash against a scratch HOME and a stub binary that prints the real
-- banner's shape and records its argv and stdin. Arms:
--   1 the reset block is marked exactly once
--   2 against a passing stub it exits 0 and its terminal names no flag and no
--     TILLANDSIAS_ variable
--   3 the setup log, under $HOME/.local/state/tillandsias, holds the banner
--   4 the stub was called with exactly `--reset-state` (no --debug, no HARD)
--     and stdin from /dev/null
--   5 a failing stub: the block exits non-zero, names the log, stays quiet
--   6 the installer's code has exactly one reset call and no HARD path
--   7 NEGATIVE CONTROL: the detector flags the line yoga measured
-- Pre-fix (linux-next 019f2b2c6): FAILS arms 1-6 — no markers; the legacy
-- range prints "Running tillandsias --reset-state" and calls --debug.
--
-- Usage: tillandsias-plan script run scripts/lua/test-install-linux-setup-is-quiet.lua

local SRC = "scripts/install.sh"
if not fs.exists(SRC) then
    verdict.could_not_run("install-linux-setup-is-quiet", "no " .. SRC)
end

local function run(argv, opts)
    local spec = { argv = argv, timeout_ms = 60000 }
    for k, v in pairs(opts or {}) do spec[k] = v end
    return proc.run(spec)
end
local ROOT = text.trim(run({ "git", "rev-parse", "--show-toplevel" }).stdout or "")
local REL = "target/plan-scratch/install-linux-quiet-" .. time.iso_utc():gsub("[^%w]", "") .. "-" .. tostring(math.random(100000, 999999))
local WORK = ROOT .. "/" .. REL
fs.mkdir(REL)

local passed, failed = 0, 0
local function check(name, cond, why)
    if cond then passed = passed + 1; out.line("ok:   " .. name)
    else failed = failed + 1; out.line("FAIL: " .. name .. " — " .. why) end
end

-- Power-user text: a TILLANDSIAS_ variable, or a flag (`--` then a letter, not
-- inside a word).
local function noisy(s)
    for _, l in ipairs(text.lines(s)) do
        if string.find(l, "TILLANDSIAS_", 1, true) or string.find(" " .. l, "[^%w%-]%-%-%a") then
            return l
        end
    end
    return nil
end
local function flat(s) return (string.gsub(string.sub(s or "", 1, 300), "\n", "|")) end

local src = fs.read(SRC)
local lines = text.lines(src)
local begins, block, inside = 0, {}, false
for _, l in ipairs(lines) do
    if string.find(l, "^# BEGIN%-SETUP%-RESET") then begins = begins + 1; inside = true
    elseif string.find(l, "^# END%-SETUP%-RESET") then inside = false
    elseif inside then block[#block + 1] = l end
end
check("1 the reset block is marked exactly once", begins == 1 and #block > 0,
    "BEGIN markers=" .. begins .. " block lines=" .. #block)
if #block == 0 then
    -- Measure what the installer has instead, so arms 2-5 judge the real text.
    local f = false
    for _, l in ipairs(lines) do
        if string.find(l, '^if %[ ! %-x "%$INSTALL_PATH" %]; then$') then f = true
        elseif f and string.find(l, "^echo \"\"$") then break
        elseif f and not string.find(l, "^%s") and not string.find(l, "^fi$") then block[#block + 1] = l end
    end
end

-- The stub: the shape of the real banner (core announce_reset_plan plus the
-- Linux SOFT body), its argv and stdin recorded, exiting with $STUB_EXIT.
fs.write(REL .. "/tillandsias", table.concat({
    "#!/usr/bin/env bash",
    'printf "%s\\n" "$*" > "$STUB_ARGV"',
    -- `-ef` compares device and inode, so it works where /proc does not (darwin).
    'if [ /dev/stdin -ef /dev/null ]; then echo /dev/null; else readlink /proc/self/fd/0 2>/dev/null || echo not-dev-null; fi > "$STUB_STDIN"',
    'echo "[tillandsias] reset: SOFT" >&2',
    'echo "[tillandsias]   WILL BE PRESERVED:" >&2',
    'echo "[tillandsias]   Skip the reset with TILLANDSIAS_DESTRUCTIVE_RESET_OK=0." >&2',
    'echo "[tillandsias] --reset-state: local state reset — reprovisioning ..." >&2',
    'exit "${STUB_EXIT:-0}"',
}, "\n") .. "\n")
run({ "chmod", "+x", WORK .. "/tillandsias" })

local BLOCK = table.concat(block, "\n")
local HARNESS = 'set -euo pipefail\n'
    .. 'say() { printf "  %s\\n" "$*"; }\n'
    .. 'die() { printf "  ERROR: %s\\n" "$*" >&2; exit 1; }\n'
    .. BLOCK .. "\n"
fs.write(REL .. "/harness.sh", HARNESS)
local function run_block(code) -- -> rc, terminal, home
    local home = WORK .. "/home." .. code
    fs.mkdir(REL .. "/home." .. code)
    local r = run({ "bash", WORK .. "/harness.sh" }, { env = {
        PATH = "/usr/bin:/bin",
        HOME = home,
        INSTALL_PATH = WORK .. "/tillandsias",
        STUB_EXIT = tostring(code),
        STUB_ARGV = WORK .. "/argv." .. code,
        STUB_STDIN = WORK .. "/stdin." .. code,
    } })
    local rc = (r.status == "exited") and r.code or -1
    return rc, (r.stdout or "") .. (r.stderr or ""), home
end

local rc, term, home = run_block(0)
local hit = noisy(term)
check("2 a passing reset exits 0 and the terminal names no flag or variable",
    rc == 0 and hit == nil, "rc=" .. rc .. " noisy=[" .. tostring(hit) .. "] terminal=[" .. flat(term) .. "]")

local log = home .. "/.local/state/tillandsias/setup.log"
local log_rel = REL .. "/home.0/.local/state/tillandsias/setup.log"
local log_body = fs.exists(log_rel) and fs.read(log_rel) or ""
check("3 the setup log holds the binary's banner",
    text.contains(log_body, "reset: SOFT") and text.contains(log_body, "WILL BE PRESERVED"),
    "log " .. log .. " = [" .. flat(log_body) .. "]")

local argv = fs.exists(REL .. "/argv.0") and text.trim(fs.read(REL .. "/argv.0")) or "<not called>"
local stdin = fs.exists(REL .. "/stdin.0") and text.trim(fs.read(REL .. "/stdin.0")) or "<not called>"
check("4 the binary ran with exactly --reset-state, stdin from /dev/null",
    argv == "--reset-state" and stdin == "/dev/null", "argv=[" .. argv .. "] stdin=[" .. stdin .. "]")

rc, term = run_block(7)
hit = noisy(term)
check("5 a failing reset exits non-zero, names the log, and stays quiet",
    rc ~= 0 and text.contains(term, "/.local/state/tillandsias/setup.log") and hit == nil,
    "rc=" .. rc .. " noisy=[" .. tostring(hit) .. "] terminal=[" .. flat(term) .. "]")

-- 6 — the installer's CODE (comments stripped): one SOFT call, no HARD path.
local calls, hard = 0, {}
for _, l in ipairs(lines) do
    local code = string.gsub(l, "^%s*#.*", "")
    code = string.gsub(code, "%s#.*", "")
    if string.find(code, "--reset-state", 1, true) and string.find(code, "INSTALL_PATH", 1, true) then
        calls = calls + 1
        if string.find(code, "--debug", 1, true) then hard[#hard + 1] = "--debug" end
    end
    for _, tok in ipairs({ "--reset-guest", "--approve-hard-reset", "TILLANDSIAS_HARD_RESET_APPROVED", "TILLANDSIAS_INSTALL_RESET" }) do
        if string.find(code, tok, 1, true) then hard[#hard + 1] = tok end
    end
end
check("6 exactly one reset call, without --debug, and no HARD path",
    calls == 1 and #hard == 0, "calls=" .. calls .. " hard=[" .. table.concat(hard, " ") .. "]")

-- 7 — NEGATIVE CONTROL: the line yoga's v56.10.14.1 install printed.
check("7 NEGATIVE CONTROL: the measured line is flagged",
    noisy("  Running tillandsias --reset-state (resets local state, then reprovisions — may take a minute)...") ~= nil,
    "the detector cannot see a flag name")

run({ "rm", "-rf", WORK })
if failed > 0 then
    verdict.emit("refused:install-linux-setup-is-quiet:" .. failed .. "-of-" .. (passed + failed), 1)
end
verdict.emit("ok:install-linux-setup-is-quiet:" .. passed .. " arms", 0)
