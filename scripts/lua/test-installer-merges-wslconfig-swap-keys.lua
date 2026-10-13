-- @trace order:1339-r9xv, order:1560-uam3, spec:wsl-runtime
-- @env PATH SystemRoot TEMP TMP USERPROFILE LOCALAPPDATA TILLANDSIAS_INSTALLER_SRC
--
-- test-installer-merges-wslconfig-swap-keys.lua — the Windows installer ENSURES
-- the WSL swap and memory-reclaim keys and the Hyper-V access, without asking.
-- Operator, 2026-10-12 (1560-uam3): "HyperV and SWAP should not be prompts, our
-- install should add them forcibly as they're hard requirements."
--
-- Ported from scripts/test-installer-merges-wslconfig-swap-keys.sh (1339-r9xv)
-- as 1560-uam3's carried shell-to-lua item. Like the .sh, it RUNS the
-- installer's own functions through PowerShell against concrete files; it does
-- not read the functions' source for idioms. The functions are cut out of
-- scripts/install-windows.ps1 between # BEGIN-WSLCONFIG-MERGE and
-- # END-WSLCONFIG-MERGE.
--
--   0  the cut: each marker exactly once, and the cut defines Get-WslConfigMerge
--      (could-not-run otherwise, never a verdict)
--   1  empty file: adds exactly the four keys, in their sections, each under a
--      "# tillandsias:" comment
--   2  a tuned file: adds swap, swapFile, sparseVhd and leaves every existing
--      line byte-identical and in order
--   3  swap=4GB (below the 8 GB floor) is REPLACED in place, under a
--      "# tillandsias: replaced" comment, and reported (the .sh asserted the
--      opposite; the operator's ruling reversed it)
--   4  swap=0 (swap off) is replaced
--   5  swap=16GB (at or above the floor) is kept and reported as kept
--   6  sparseVhd=false and autoMemoryReclaim=dropcache are replaced; memory and
--      processors are never touched
--   7  idempotent: the function's own output, fed back, changes nothing (for an
--      added file and for a replaced one)
--   8  autoMemoryReclaim under [wsl2] (where WSL ignores it) does not count as
--      present: the [experimental] key is still added
--   9  swapFile is written with doubled backslashes (.wslconfig expands nothing)
--  10  swap size scales with free disk, with a floor and a reserve
--  11  Invoke-WslConfigEnsure on scratch files: an absent file is created with
--      no backup; a conflicting file gets a byte-identical backup FIRST and a
--      BOM-less rewrite; a file that already complies is not touched
--  12  Get-WslRestartDecision: restart only when ours is the only running distro
--  13  Invoke-HyperVAccessEnsure: the add runs whenever access is missing, and
--      sign-out is reported only when IsInRole is still false after the add
--  14  installer source (comments stripped): no Read-Host, [y/N] or [Y/n], no
--      consent or opt-out variable; the ensure functions are CALLED (a function
--      nobody calls would pass 1-13); the sign-out note sits only in the
--      sign-out arm
--
-- TILLANDSIAS_INSTALLER_SRC is the seam (default scripts/install-windows.ps1).
-- Where no PowerShell exists (a Linux gate host) arms 1-13 are one named skip;
-- arms 0 and 14 read source and always run.
--
-- Usage: tillandsias-plan script run scripts/lua/test-installer-merges-wslconfig-swap-keys.lua

local function run(argv, opts)
    local spec = { argv = argv, timeout_ms = 120000 }
    for k, v in pairs(opts or {}) do spec[k] = v end
    return proc.run(spec)
end
local ROOT = text.trim(run({ "git", "rev-parse", "--show-toplevel" }).stdout or "")
local SRC = env.get("TILLANDSIAS_INSTALLER_SRC")
if SRC == nil or SRC == "" then SRC = "scripts/install-windows.ps1" end
if not fs.exists(SRC) then
    verdict.could_not_run("wslconfig-merge-fixture", "no installer at " .. SRC .. " (a measurement failure, not a verdict)")
end
local src = fs.read(SRC)

local passed, failed, skipped = 0, 0, 0
local function check(name, cond, why)
    if cond then passed = passed + 1; out.line("ok:   " .. name)
    else failed = failed + 1; out.line("FAIL: " .. name .. " — " .. (why or "")) end
end
local function count(lines, pred)
    local n = 0
    for _, l in ipairs(lines) do if pred(l) then n = n + 1 end end
    return n
end
local function has(lines, s) return count(lines, function(l) return l == s end) end

-- ARM 0: the cut.
local lines = text.lines(src)
local nb = has(lines, "# BEGIN-WSLCONFIG-MERGE")
local ne = has(lines, "# END-WSLCONFIG-MERGE")
if nb ~= 1 or ne ~= 1 then
    log.raw("  why: the fixture cuts the functions out between two marker lines, and each must occur exactly once")
    verdict.could_not_run("wslconfig-merge-fixture", "markers:begin=" .. nb .. ":end=" .. ne)
end
local cut, on = {}, false
for _, l in ipairs(lines) do
    if l == "# BEGIN-WSLCONFIG-MERGE" then on = true end
    if on then cut[#cut + 1] = l end
    if l == "# END-WSLCONFIG-MERGE" then on = false end
end
local cut_text = table.concat(cut, "\n") .. "\n"
if not text.is_match(cut_text, [[(?m)^function Get-WslConfigMerge]]) then
    verdict.could_not_run("wslconfig-merge-fixture", "cut-has-no-function")
end
check("0 the cut defines Get-WslConfigMerge", true)

-- ARM 14 (source; runs everywhere). Comments stripped: a `#` at line start or
-- after whitespace, and <# ... #> blocks.
local code, blk = {}, false
for _, l in ipairs(lines) do
    if text.is_match(l, [[^\s*<#]]) then blk = true end
    if blk then
        if string.find(l, "#>", 1, true) then blk = false end
        code[#code + 1] = ""
    else
        local c, i = l, 1
        while true do
            local j = string.find(c, "#", i, true)
            if j == nil then break end
            if j == 1 or string.find(string.sub(c, j - 1, j - 1), "%s") then c = string.sub(c, 1, j - 1); break end
            i = j + 1
        end
        code[#code + 1] = c
    end
end
local prompts = {}
for n, c in ipairs(code) do
    if text.is_match(c, [=[Read-Host|\[y/N\]|\[Y/n\]]=]) then prompts[#prompts + 1] = SRC .. ":" .. n end
end
check("14a no Read-Host, [y/N] or [Y/n] remains in the installer", #prompts == 0, table.concat(prompts, " "))
local optouts = {}
for n, c in ipairs(code) do
    if text.is_match(c, [[TILLANDSIAS_NO_GROUP_ADD|TILLANDSIAS_WSLCONFIG\b]]) then optouts[#optouts + 1] = SRC .. ":" .. n end
end
check("14b no consent or opt-out variable gates the Hyper-V or .wslconfig step", #optouts == 0, table.concat(optouts, " "))
local calls_wsl = count(code, function(c) return text.is_match(c, [[=\s*Invoke-WslConfigEnsure\s+-Path\s+\$WslCfgPath]]) end)
local calls_hv = count(code, function(c) return text.is_match(c, [[=\s*Invoke-HyperVAccessEnsure\s+-Test]]) end)
check("14c the installer calls Invoke-WslConfigEnsure and Invoke-HyperVAccessEnsure once each",
    calls_wsl == 1 and calls_hv == 1, "Invoke-WslConfigEnsure calls=" .. calls_wsl .. " Invoke-HyperVAccessEnsure calls=" .. calls_hv)
-- The sign-out note: every code line naming it lies inside the 'sign-out'
-- switch arm, which opens at `'sign-out' {` and ends where `'failed'` opens.
local arm_open, arm_close = nil, nil
for n, c in ipairs(code) do
    if arm_open == nil and text.is_match(c, [['sign-out'\s*\{]]) then arm_open = n
    elseif arm_open ~= nil and arm_close == nil and text.is_match(c, [['failed'\s*\{]]) then arm_close = n end
end
local notes, outside = 0, {}
for n, c in ipairs(code) do
    if string.find(c, "SIGN OUT", 1, true) then
        notes = notes + 1
        if arm_open == nil or arm_close == nil or n < arm_open or n > arm_close then outside[#outside + 1] = SRC .. ":" .. n end
    end
end
check("14d the sign-out note appears only in the sign-out arm",
    arm_open ~= nil and arm_close ~= nil and notes > 0 and #outside == 0,
    "arm=" .. tostring(arm_open) .. ".." .. tostring(arm_close) .. " notes=" .. notes .. " outside=" .. table.concat(outside, " "))

-- PowerShell: the installer's runtime is Windows PowerShell where present.
local ENV = {}
for _, k in ipairs({ "PATH", "SystemRoot", "TEMP", "TMP", "USERPROFILE", "LOCALAPPDATA" }) do
    local v = env.get(k); if v and v ~= "" then ENV[k] = v end
end
local PS = nil
local REL = "target/plan-scratch/wslconfig-merge-" .. time.iso_utc():gsub("[^%w]", "") .. "-" .. tostring(math.random(100000, 999999))
fs.mkdir(REL)
local DIR = ROOT .. "/" .. REL
fs.write(REL .. "/merge.ps1", cut_text)
fs.write(REL .. "/probe.ps1", "exit 0\n")
if PS == nil then
    for _, exe in ipairs({ "powershell.exe", "pwsh" }) do
        local r = run({ exe, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", DIR .. "/probe.ps1" }, { env = ENV, timeout_ms = 60000 })
        if r.status == "exited" and r.code == 0 then PS = exe; break end
    end
end

local function finish()
    run({ "rm", "-rf", DIR })
    if failed > 0 then
        verdict.emit("refused:wslconfig-merge-fixture:failed=" .. failed .. " ran=" .. (passed + failed) .. " skipped=" .. skipped, 1)
    end
    verdict.emit("ok:wslconfig-merge-fixture:ran=" .. passed .. " skipped=" .. skipped, 0)
end
if PS == nil then
    log.raw("skip:wslconfig-merge-fixture:run:no-powershell-on-this-host")
    skipped = skipped + 1
    finish()
end

-- The harness: dot-source the cut and run one mode. Lists come back one item
-- per line, prefixed, and file lines between ---begin--- and ---end---.
fs.write(REL .. "/run.ps1", [[
param([string]$Merge, [string]$Mode, [string]$In = '', [int]$SwapGB = 8, [string]$Names = '', [string]$Scenario = '')
$ErrorActionPreference = 'Stop'
. $Merge
$sf = 'C:\Users\u\AppData\Local\tillandsias\wsl-swap.vhdx'
function Emit($r) {
    foreach ($a in $r.Added) { "added:$a" }
    foreach ($a in $r.Replaced) { "replaced:$a" }
    foreach ($a in $r.Kept) { "kept:$a" }
    "---begin---"
    foreach ($l in $r.Lines) { $l }
    "---end---"
}
switch ($Mode) {
    'merge' {
        $lines = @()
        if ((Test-Path $In) -and (Get-Item $In).Length -gt 0) { $lines = @(Get-Content $In) }
        Emit (Get-WslConfigMerge -Lines $lines -SwapFile $sf -SwapSizeGB $SwapGB)
    }
    'size' {
        foreach ($f in @(10, 27, 30, 99.9, 100, 110, 199, 200, 230, 500)) {
            $r = Get-WslSwapSizeGB -FreeGB $f
            "size:${f}:$($r.SizeGB):$($r.Warn)"
        }
        $m = Get-WslConfigMerge -Lines @() -SwapFile 'C:\x\s.vhdx' -SwapSizeGB 24
        "line:" + (($m.Lines | Where-Object { $_ -like 'swap=*' }) -join ',')
    }
    'ensure' {
        $r = Invoke-WslConfigEnsure -Path $In -SwapFile $sf -SwapSizeGB 8
        "changed:$($r.Changed)"
        "backup:$($r.Backup)"
    }
    'restart' {
        $n = @()
        if ($Names -ne '') { $n = $Names -split ',' }
        "decision:" + (Get-WslRestartDecision -Running $n)
    }
    'hyperv' {
        $script:adds = 0
        $script:tests = 0
        $add = { $script:adds++ }
        switch ($Scenario) {
            'already' { $test = { $script:tests++; $true } }
            'active'  { $test = { $script:tests++; $script:adds -gt 0 } }
            'signout' { $test = { $script:tests++; $false } }
            'failed'  { $test = { $script:tests++; $false }; $add = { $script:adds++; throw 'The operation was canceled by the user.' } }
        }
        $r = Invoke-HyperVAccessEnsure -Test $test -Add $add
        "outcome:$($r.Outcome)"
        "signout:$($r.SignOut)"
        "adds:$script:adds"
    }
}
]])

local function ps(args) -- -> output lines (CR stripped), raw
    local argv = { PS, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", DIR .. "/run.ps1", "-Merge", DIR .. "/merge.ps1" }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local r = run(argv, { env = ENV })
    local o = ((r.stdout or "") .. (r.stderr or "")):gsub("\r", "")
    return text.lines(o), o
end
local function merge_case(name, body, swapgb)
    fs.write(REL .. "/" .. name .. ".ini", body)
    local o, raw = ps({ "-Mode", "merge", "-In", DIR .. "/" .. name .. ".ini", "-SwapGB", tostring(swapgb or 8) })
    local res = { added = {}, replaced = {}, kept = {}, lines = {}, raw = raw }
    local inb = false
    for _, l in ipairs(o) do
        if l == "---begin---" then inb = true
        elseif l == "---end---" then inb = false
        elseif inb then res.lines[#res.lines + 1] = l
        elseif string.sub(l, 1, 6) == "added:" then res.added[#res.added + 1] = string.sub(l, 7)
        elseif string.sub(l, 1, 9) == "replaced:" then res.replaced[#res.replaced + 1] = string.sub(l, 10)
        elseif string.sub(l, 1, 5) == "kept:" then res.kept[#res.kept + 1] = string.sub(l, 6) end
    end
    return res
end
local function body(t) return table.concat(t, "\n") .. "\n" end
local function starts(prefix) return function(l) return string.sub(l, 1, #prefix) == prefix end end

-- ARM 1: empty file.
local e = merge_case("empty", "")
check("1 empty file adds exactly four keys", #e.added == 4, "added=" .. #e.added .. " raw=[" .. e.raw .. "]")
check("1 each added key carries its own # tillandsias: comment", count(e.lines, starts("# tillandsias:")) == 4)
local sec, where = "", {}
for _, l in ipairs(e.lines) do
    if l == "[wsl2]" then sec = "w" elseif l == "[experimental]" then sec = "e" end
    if l == "swap=8GB" then where[#where + 1] = "swap:" .. sec end
    if l == "sparseVhd=true" then where[#where + 1] = "sparse:" .. sec end
    if l == "autoMemoryReclaim=gradual" then where[#where + 1] = "reclaim:" .. sec end
end
check("1 keys land in their sections", table.concat(where, " ") == "swap:w sparse:e reclaim:e", table.concat(where, " "))

-- ARM 2: a tuned file keeps every line, in order.
local tuned = { "[wsl2]", "memory=8GB", "processors=16", "", "[experimental]", "autoMemoryReclaim=gradual" }
local t = merge_case("tuned", body(tuned))
local names = {}
for _, a in ipairs(t.added) do names[#names + 1] = (a:gsub("=.*", "")) end
check("2 a tuned file gains swap, swapFile, sparseVhd only",
    table.concat(names, ",") == "[wsl2] swap,[wsl2] swapFile,[experimental] sparseVhd", table.concat(t.added, " | "))
local kept_lines = {}
for _, l in ipairs(t.lines) do
    if not text.is_match(l, [[^# tillandsias:|^(swap|swapFile|sparseVhd)=]]) then kept_lines[#kept_lines + 1] = l end
end
check("2 no existing line was changed, dropped or reordered", body(kept_lines) == body(tuned), body(kept_lines))

-- ARM 3: swap below the floor is replaced in place.
local s4 = merge_case("swap4", body({ "[wsl2]", "memory=8GB", "swap=4GB" }))
check("3 swap=4GB is replaced by swap=8GB, once, in place",
    has(s4.lines, "swap=8GB") == 1 and has(s4.lines, "swap=4GB") == 0 and s4.lines[3] ~= nil
        and text.is_match(s4.lines[3], [[^# tillandsias: replaced swap=4GB]]) and s4.lines[4] == "swap=8GB",
    body(s4.lines))
check("3 the replacement is reported, not counted as added",
    #s4.replaced == 1 and text.contains(s4.replaced[1], "swap=4GB -> 8GB") and count(s4.added, starts("[wsl2] swap=")) == 0,
    "replaced=" .. table.concat(s4.replaced, " | ") .. " added=" .. table.concat(s4.added, " | "))

-- ARM 4: swap=0 turns swap off and is replaced.
local s0 = merge_case("swap0", body({ "[wsl2]", "swap=0" }))
check("4 swap=0 is replaced", has(s0.lines, "swap=0") == 0 and has(s0.lines, "swap=8GB") == 1, body(s0.lines))

-- ARM 5: swap at or above the floor is kept.
local s16 = merge_case("swap16", body({ "[wsl2]", "swap=16GB" }))
check("5 swap=16GB is kept and reported as kept",
    has(s16.lines, "swap=16GB") == 1 and has(s16.lines, "swap=8GB") == 0 and #s16.replaced == 0
        and count(s16.kept, starts("[wsl2] swap=16GB")) == 1,
    body(s16.lines) .. " kept=" .. table.concat(s16.kept, " | "))

-- ARM 6: the reclaim and sparse keys must be exactly ours; memory/processors never.
local ex = merge_case("exp", body({ "[wsl2]", "memory=4GB", "processors=2", "", "[experimental]", "sparseVhd=false", "autoMemoryReclaim=dropcache" }))
check("6 sparseVhd=false and autoMemoryReclaim=dropcache are replaced",
    has(ex.lines, "sparseVhd=true") == 1 and has(ex.lines, "autoMemoryReclaim=gradual") == 1
        and has(ex.lines, "sparseVhd=false") == 0 and has(ex.lines, "autoMemoryReclaim=dropcache") == 0 and #ex.replaced == 2,
    body(ex.lines))
check("6 memory and processors are never touched",
    has(ex.lines, "memory=4GB") == 1 and has(ex.lines, "processors=2") == 1, body(ex.lines))

-- ARM 7: idempotent.
local again = merge_case("again", body(e.lines))
check("7 a second run over an added file changes nothing",
    #again.added == 0 and #again.replaced == 0 and body(again.lines) == body(e.lines), again.raw)
local again2 = merge_case("again2", body(ex.lines))
check("7 a second run over a replaced file changes nothing",
    #again2.added == 0 and #again2.replaced == 0 and body(again2.lines) == body(ex.lines), again2.raw)

-- ARM 8: autoMemoryReclaim in [wsl2] is inert.
local mis = merge_case("misplaced", body({ "[wsl2]", "autoMemoryReclaim=gradual" }))
check("8 autoMemoryReclaim under [wsl2] is not treated as present",
    count(mis.added, starts("[experimental] autoMemoryReclaim=gradual")) == 1, table.concat(mis.added, " | "))

-- ARM 9: the swap file path is escaped for .wslconfig.
check("9 swapFile is written with doubled backslashes",
    has(e.lines, [[swapFile=C:\\Users\\u\\AppData\\Local\\tillandsias\\wsl-swap.vhdx]]) == 1, body(e.lines))

-- ARM 10: swap size scales with free disk.
local so = ps({ "-Mode", "size" })
local sizes = {}
for _, l in ipairs(so) do if starts("size:")(l) then sizes[#sizes + 1] = l end end
local want = "size:10:8:True size:27:8:True size:30:8:False size:99.9:8:False size:100:16:False size:110:16:False size:199:16:False size:200:24:False size:230:24:False size:500:24:False"
check("10 swap sizing tiers, floor and reserve", table.concat(sizes, " ") == want, table.concat(sizes, " "))
check("10 the chosen size reaches the swap= line", has(so, "line:swap=24GB") == 1, table.concat(so, " | "))

-- ARM 11: the one write, on scratch files.
local function ensure(name)
    local o = ps({ "-Mode", "ensure", "-In", DIR .. "/" .. name })
    local r = { changed = "", backup = "" }
    for _, l in ipairs(o) do
        if starts("changed:")(l) then r.changed = string.sub(l, 9) end
        if starts("backup:")(l) then r.backup = string.sub(l, 8) end
    end
    r.out = table.concat(o, " | ")
    return r
end
local r1 = ensure("absent.wslconfig")
check("11 an absent file is created, with no backup",
    r1.changed == "True" and r1.backup == "" and fs.exists(REL .. "/absent.wslconfig")
        and not fs.exists(REL .. "/absent.wslconfig.tillandsias-bak")
        and text.contains(fs.read(REL .. "/absent.wslconfig"), "autoMemoryReclaim=gradual"), r1.out)
local orig = body({ "[wsl2]", "memory=8GB", "swap=0", "", "[experimental]", "autoMemoryReclaim=disabled" })
fs.write(REL .. "/conflict.wslconfig", orig)
local r2 = ensure("conflict.wslconfig")
local after = fs.read(REL .. "/conflict.wslconfig")
check("11 a conflicting file is backed up byte-identical first",
    r2.changed == "True" and fs.exists(REL .. "/conflict.wslconfig.tillandsias-bak")
        and fs.read(REL .. "/conflict.wslconfig.tillandsias-bak"):gsub("\r", "") == orig, r2.out)
check("11 the rewrite replaces the conflicts and carries no BOM",
    string.byte(after, 1) ~= 0xEF and text.contains(after, "swap=8GB") and text.contains(after, "autoMemoryReclaim=gradual")
        and not text.is_match(after, [[(?m)^swap=0\r?$]]), after)
local good = after
fs.write(REL .. "/good.wslconfig", good)
local r3 = ensure("good.wslconfig")
check("11 a file that already complies is not touched",
    r3.changed == "False" and r3.backup == "" and not fs.exists(REL .. "/good.wslconfig.tillandsias-bak")
        and fs.read(REL .. "/good.wslconfig") == good, r3.out)

-- ARM 12: the shared VM is restarted only when that stops nothing of the user's.
local function decision(names_csv)
    local o = ps({ "-Mode", "restart", "-Names", names_csv })
    for _, l in ipairs(o) do if starts("decision:")(l) then return string.sub(l, 10) end end
    return table.concat(o, " | ")
end
local d = { decision(""), decision("tillandsias"), decision("tillandsias,Ubuntu"), decision("Ubuntu") }
check("12 restart decisions: none-running, restart, deferred, deferred",
    table.concat(d, ",") == "none-running,restart,deferred,deferred", table.concat(d, ","))

-- ARM 13: Hyper-V access decided for the user.
local function hv(s)
    local o = ps({ "-Mode", "hyperv", "-Scenario", s })
    local r = {}
    for _, l in ipairs(o) do
        local k, v = string.match(l, "^(%a+):(.*)$")
        if k then r[k] = v end
    end
    r.out = table.concat(o, " | ")
    return r
end
local h1, h2, h3, h4 = hv("already"), hv("active"), hv("signout"), hv("failed")
check("13 access already held: no add, no sign-out note",
    h1.outcome == "already" and h1.signout == "False" and h1.adds == "0", h1.out)
check("13 access missing: the add always runs; effective at once means no sign-out note",
    h2.outcome == "active" and h2.signout == "False" and h2.adds == "1", h2.out)
check("13 IsInRole still false after the add: the sign-out note",
    h3.outcome == "sign-out" and h3.signout == "True" and h3.adds == "1", h3.out)
check("13 the add declined or failed: no sign-out note",
    h4.outcome == "failed" and h4.signout == "False" and h4.adds == "1", h4.out)

finish()
