-- @trace order:1561-47a8, order:1561-9f4x, order:1560-uam3, order:1639-8gfw, spec:host-state-lifecycle
-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-check-installer-end-user-output.lua — the end-user installers print
-- only end-user lines (operator ruling 2026-10-08: "we do not need to print any
-- power user messages during install, at all ... a pretty installer, rather
-- than an informational/debugging installer").
--
-- A Lua fixture on `script run`, not a .sh: a new shell fixture would add an
-- item to the shell-to-Lua backlog. Runs the REAL
-- scripts/lua/check-installer-end-user-output.lua over the real tree (so the
-- floors are enforced here) and over scratch copies of the installers
-- (TILLANDSIAS_INSTALLER_OUTPUT_ROOT seam):
--   1 the real tree, at the floors                          -> ok
--   2 install-windows.ps1 gains `Say "... --some-flag ..."` -> refused by file:line
--   3 the same line marked `# power-user-only`              -> ok
--   4 the same line inside a retired PENDING-1560-UAM3 region -> refused (1560-uam3)
--   5 install.sh gains a `say "... TILLANDSIAS_X ..."`       -> refused (above its floor)
--   6 the text only in a comment                            -> ok
--   7-15 power-user detail in install-windows.ps1 (paths, probe binary,
--        shortcut, version line, registration, empty PENDING box, uninstall
--        removal, -Param hint, order id)               -> refused (1639-8gfw)
--   16 a failure line naming $InstallLog                     -> ok
--   17 the detail vocabulary on install.sh                   -> ok (PowerShell-only)
-- Each mutant asserts its own edit landed exactly once.
-- Pre-fix (trunk 2026-10-08): arm 1 FAILS — install-windows.ps1 printed 21
-- diagnostic lines (resolved-channel, --version/--diagnose verification,
-- --init launch).
--
-- Usage: tillandsias-plan script run scripts/lua/test-check-installer-end-user-output.lua [-- --plan <bin>]

local GUARD_REL = "scripts/lua/check-installer-end-user-output.lua"
if not fs.exists(GUARD_REL) then
    verdict.emit("refused:installer-end-user-output-fixture:guard-missing", 1)
end
local PLAN
for i = 1, #arg do if arg[i] == "--plan" then PLAN = arg[i + 1] end end
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_PLAN_BIN") end
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") end
if not PLAN or PLAN == "" then
    verdict.could_not_run("installer-end-user-output-fixture", "no plan binary named (--plan, TILLANDSIAS_PLAN_BIN or TILLANDSIAS_SCRIPT_RUNNER_BIN)")
end

local function run(argv, opts)
    local spec = { argv = argv, timeout_ms = 120000 }
    for k, v in pairs(opts or {}) do spec[k] = v end
    return proc.run(spec)
end
local ROOT = text.trim(run({ "git", "rev-parse", "--show-toplevel" }).stdout or "")
local REL = "target/plan-scratch/installer-output-" .. time.iso_utc():gsub("[^%w]", "") .. "-" .. tostring(math.random(100000, 999999))
fs.mkdir(REL)

local POP = { "scripts/install-windows.ps1", "scripts/install.sh", "scripts/install-macos.sh" }
local FLOORS = "scripts/portability/installer-end-user-output-floor.txt"

local function scratch(name)
    local rel = REL .. "/" .. name
    fs.mkdir(rel .. "/scripts/portability")
    for _, f in ipairs(POP) do fs.write(rel .. "/" .. f, fs.read(f)) end
    fs.write(rel .. "/" .. FLOORS, fs.read(FLOORS))
    return rel
end
-- Append the lines; true when the first one now occurs exactly once.
local function append_once(rel_file, lines)
    local body = fs.read(rel_file)
    if string.sub(body, -1) ~= "\n" then body = body .. "\n" end
    fs.write(rel_file, body .. table.concat(lines, "\n") .. "\n")
    local n = 0
    for _, l in ipairs(text.lines(fs.read(rel_file))) do if l == lines[1] then n = n + 1 end end
    return n == 1
end
local function guard(seam) -- -> rc, combined output
    local opts = {}
    if seam then opts.env = { TILLANDSIAS_INSTALLER_OUTPUT_ROOT = ROOT .. "/" .. seam } end
    local r = run({ PLAN, "script", "run", ROOT .. "/" .. GUARD_REL }, opts)
    return (r.status == "exited" and r.code or -1), (r.stdout or "") .. (r.stderr or "")
end

local passed, failed = 0, 0
local function check(name, cond, why)
    if cond then passed = passed + 1; out.line("ok:   " .. name)
    else failed = failed + 1; out.line("FAIL: " .. name .. " — " .. why) end
end
local FLAG = 'Say "  run with --some-flag to see more"'

-- 1 the real tree.
local rc, o = guard(nil)
check("1 the real tree is at its floors", rc == 0, "rc=" .. rc .. " out=[" .. o .. "]")

-- 2 a diagnostic line added to the Windows installer.
local d = scratch("a")
if append_once(d .. "/scripts/install-windows.ps1", { FLAG }) then
    rc, o = guard(d)
    check("2 a flag-naming line is refused by file:line",
        rc == 1 and text.contains(o, "scripts/install-windows.ps1:"), "rc=" .. rc .. " out=[" .. o .. "]")
else check("2 mutant landed once", false, "it did not") end

-- 3 the same line marked power-user-only.
d = scratch("b")
if append_once(d .. "/scripts/install-windows.ps1", { FLAG .. "  # power-user-only" }) then
    rc, o = guard(d)
    check("3 a power-user-only line is exempt", rc == 0, "rc=" .. rc .. " out=[" .. o .. "]")
else check("3 mutant landed once", false, "it did not") end

-- 4 the same line inside a retired PENDING-1560-UAM3 region (1560-uam3 removed
--   the exemption with the regions): refused like any other.
d = scratch("c")
if append_once(d .. "/scripts/install-windows.ps1", { "# BEGIN-PENDING-1560-UAM3", FLAG, "# END-PENDING-1560-UAM3" }) then
    rc, o = guard(d)
    check("4 a retired pending-prompt marker exempts nothing",
        rc == 1 and text.contains(o, "scripts/install-windows.ps1:"), "rc=" .. rc .. " out=[" .. o .. "]")
else check("4 mutant landed once", false, "it did not") end

-- 5 install.sh above its floor.
d = scratch("d")
if append_once(d .. "/scripts/install.sh", { 'say "  set TILLANDSIAS_X=1 for more"' }) then
    rc, o = guard(d)
    check("5 install.sh above its floor is refused",
        rc == 1 and text.contains(o, "scripts/install.sh:"), "rc=" .. rc .. " out=[" .. o .. "]")
else check("5 mutant landed once", false, "it did not") end

-- 6 the text only in a comment.
d = scratch("e")
if append_once(d .. "/scripts/install-windows.ps1", { "# " .. FLAG }) then
    rc, o = guard(d)
    check("6 a commented line does not count", rc == 0, "rc=" .. rc .. " out=[" .. o .. "]")
else check("6 mutant landed once", false, "it did not") end

-- 7-15 power-user DETAIL in the Windows installer (order 1639-8gfw): each line
--   the v56.10.12.1 end-user install printed, plus its siblings, is refused by
--   file:line. The pre-fix guard passed every one of them (its vocabulary was
--   flags, TILLANDSIAS_, URLs, channel and base).
local DETAIL = {
    { "7 an install path",               'Say "Install path: $InstalledExe"' },
    { "8 the capability probe binary",   'Say "  capability probe binary: $InstalledHeadless"' },
    { "9 a Start Menu shortcut path",    'SayOk "Start Menu shortcut: $ShortcutPath"' },
    { "10 the tray version line",        'SayOk $VerLine' },
    { "11 Installed-Software registration", 'SayOk "Registered in Installed Software (v$InstalledVersion)."' },
    { "12 an empty PENDING box",         "        $out += '  PENDING: none'" },
    { "13 an uninstall removal detail",  'Say "  removed tray-icon settings entry: $p"' },
    { "14 a -Param hint",                'SayOk "Uninstalled. (Use -Purge for full cleanup.)"' },
    { "15 an order id",                  'Say "  note: no probe binary at this locus (1171-ccf2)"' },
}
for i, c in ipairs(DETAIL) do
    d = scratch("detail" .. i)
    if append_once(d .. "/scripts/install-windows.ps1", { c[2] }) then
        rc, o = guard(d)
        check(c[1] .. " is refused by file:line",
            rc == 1 and text.contains(o, "scripts/install-windows.ps1:"), "rc=" .. rc .. " out=[" .. o .. "]")
    else check(c[1] .. " mutant landed once", false, "it did not") end
end

-- 16 the log path on a failure line is allowed (the ruling: show the log by path).
d = scratch("f")
if append_once(d .. "/scripts/install-windows.ps1", { 'SayWn "Something went wrong. Details: $InstallLog"' }) then
    rc, o = guard(d)
    check("16 a failure line naming $InstallLog is allowed", rc == 0, "rc=" .. rc .. " out=[" .. o .. "]")
else check("16 mutant landed once", false, "it did not") end

-- 17 the detail vocabulary is PowerShell-only: the same path line in install.sh
--    stays under its floor (its 1561 slice measures it).
d = scratch("g")
if append_once(d .. "/scripts/install.sh", { 'say "Install path: $InstalledExe"' }) then
    rc, o = guard(d)
    check("17 the detail vocabulary does not apply to the shell installers", rc == 0, "rc=" .. rc .. " out=[" .. o .. "]")
else check("17 mutant landed once", false, "it did not") end

run({ "rm", "-rf", ROOT .. "/" .. REL })
if failed > 0 then
    verdict.emit("refused:installer-end-user-output-fixture:" .. failed .. "-of-" .. (passed + failed), 1)
end
verdict.emit("ok:installer-end-user-output-fixture:" .. passed .. " arms", 0)
