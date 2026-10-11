-- @trace order:1597-rrku, order:770-ifeg
-- @env PATH
--
-- test-ruby-probe-runs.lua — the mirror pre-receive hook's discipline parser,
-- and test-mirror-discipline's skip guard, probe ruby by RUNNING it.
--
-- MEASURED on yoga's forge 2026-10-11: `ruby` on PATH is the Homebrew
-- lazy-install shim, which exits 127. `command -v ruby` accepted it, so the
-- hook parsed branch-discipline.yaml with a ruby that could not run, discarded
-- its stderr, and logged "present but unreadable ()". The fixture ran instead
-- of skipping, went red, and refused --preflight whenever it beat the 5 s
-- deadline. Run-don't-stat (770-ifeg).
--
-- A scratch bin holds a `ruby` that behaves like the shim: it exits 127, and it
-- records an install attempt unless TILLANDSIAS_BREW_AUTOINSTALL=0. It is put
-- first on PATH, and the hook's own discipline_parse runs on a valid seed:
--   1 PRE-FIX  the parser with its probe turned back into `command -v ruby`
--              reports no reason (the "()" of the measured warning)
--   2 FIXED    the parser as it stands reports reason=no-ruby
--   3 NO INSTALL  the fixed probe never lets the shim attempt an install
--   4 GUARD    test-mirror-discipline.sh's skip guard runs ruby, with
--              AUTOINSTALL=0, rather than `command -v ruby`
--
-- Terminal line: ok:ruby-probe-runs-fixture:<n> or
-- refused:ruby-probe-runs-fixture:<failed>.
--
-- Usage: tillandsias-plan script run scripts/lua/test-ruby-probe-runs.lua

local ROOT = text.trim(proc.run({ argv = { "git", "rev-parse", "--show-toplevel" } }).stdout or "")
local REL = "target/plan-scratch/ruby-probe-" .. tostring(math.random(100000, 999999)) .. tostring(math.random(100000, 999999))
local S = ROOT .. "/" .. REL
fs.mkdir(REL .. "/bin")
local passed, failed = 0, 0
local function ok(m) out.line("ok: " .. m); passed = passed + 1 end
local function bad(m) out.line("FAIL: " .. m); failed = failed + 1 end
local function has(s, sub) return s:find(sub, 1, true) ~= nil end

local hook = fs.read("images/git/pre-receive-hook.sh") or ""
local fn = hook:match("\n(discipline_parse%(%) {.-\n})\n")
local PROBE = "TILLANDSIAS_BREW_AUTOINSTALL=0 ruby -e 'exit 0' >/dev/null 2>&1 || { echo \"reason=no-ruby\"; return 1; }"
if not fn or not has(fn, PROBE) then
    bad("premise: discipline_parse, or its execution probe, was not found in images/git/pre-receive-hook.sh")
    proc.run({ argv = { "rm", "-rf", S } })
    verdict.emit("refused:ruby-probe-runs-fixture:" .. failed, 1)
end
local i, j = fn:find(PROBE, 1, true)
local pre = fn:sub(1, i - 1) .. 'command -v ruby >/dev/null 2>&1 || { echo "reason=no-ruby"; return 1; }' .. fn:sub(j + 1)

-- The shim stand-in: exits 127; records an install attempt unless AUTOINSTALL=0.
fs.write(REL .. "/bin/ruby", "#!/usr/bin/env bash\n[ \"${TILLANDSIAS_BREW_AUTOINSTALL:-1}\" = 0 ] || echo attempted >> \"" .. S .. "/install-attempts\"\necho \"tillandsias: 'ruby' is not installed.\" >&2\nexit 127\n")
proc.run({ argv = { "chmod", "+x", S .. "/bin/ruby" } })
fs.write(REL .. "/seed.yaml", "level: 1\nenforcement:\n  default_branch: enforced\n")

local function parse(name, body)
    fs.write(REL .. "/" .. name, body .. "\nout=\"$(discipline_parse \"$1\" 2>/dev/null)\"; rc=$?\nprintf 'rc=%s out=[%s]\\n' \"$rc\" \"$out\"\n")
    local r = proc.run({ argv = { "bash", S .. "/" .. name, S .. "/seed.yaml" },
        env = { PATH = S .. "/bin:" .. (env.get("PATH") or "/usr/bin:/bin") }, timeout_ms = 30000 })
    return r.stdout or ""
end

local function attempts()
    local okr, body = pcall(fs.read, REL .. "/install-attempts")
    local n = 0
    if okr and body then for _ in body:gmatch("attempted") do n = n + 1 end end
    return n
end

local o_pre = parse("pre-fix.sh", pre)
local after_pre = attempts()
if has(o_pre, "out=[]") and not has(o_pre, "rc=0") then
    ok("pre-fix: `command -v ruby` accepts the shim, the parse fails and no reason is given (" .. text.trim(o_pre) .. ")")
else bad("pre-fix did not reproduce the empty reason: " .. o_pre) end

local o_fix = parse("fixed.sh", fn)
local added = attempts() - after_pre
if has(o_fix, "rc=1 out=[reason=no-ruby]") then ok("fixed: the shim reads as no ruby, reason=no-ruby")
else bad("fixed parser did not report reason=no-ruby: " .. o_fix) end

-- The pre-fix parse ran the shim with installs allowed (after_pre counts
-- them: the bug's network-install risk); the fixed parse must add none.
if added == 0 and after_pre >= 1 then
    ok("the fixed probe let the shim attempt no install (pre-fix: " .. after_pre .. ", fixed: 0)")
else bad("install attempts — pre-fix: " .. after_pre .. ", added by the fixed parse: " .. added) end

local fx = fs.read("scripts/test-mirror-discipline.sh") or ""
if has(fx, "TILLANDSIAS_BREW_AUTOINSTALL=0 ruby -e 'exit 0' >/dev/null 2>&1 || { echo \"skip:mirror-discipline:no-ruby")
    and not fx:find("\ncommand %-v ruby >/dev/null 2>&1 || { echo \"skip:mirror%-discipline") then
    ok("test-mirror-discipline.sh's skip guard runs ruby rather than `command -v ruby`")
else bad("test-mirror-discipline.sh's skip guard still stats ruby") end

proc.run({ argv = { "rm", "-rf", S } })
if failed == 0 then verdict.emit("ok:ruby-probe-runs-fixture:" .. passed, 0) end
verdict.emit("refused:ruby-probe-runs-fixture:" .. failed, 1)
