-- @env TILLANDSIAS_MACOS_STOCK_ROOT
-- @read-env TILLANDSIAS_MACOS_STOCK_ROOT
-- @trace spec:macos-native-tray, order:1420-umka, order:980-xcaf
-- @trace order:1247-hun3
--
-- check-macos-stock-binaries.lua — PORTED from check-macos-stock-binaries.sh
-- (the shell-to-lua carried obligation, paid by 1247-hun3). The macOS install
-- and provision path runs only STOCK macOS binaries, named so a user's PATH
-- cannot change which one.
--
--   tillandsias-plan script run scripts/lua/check-macos-stock-binaries.lua
--   TILLANDSIAS_MACOS_STOCK_ROOT=<dir> ... (a scratch copy; the .sh's --root)
--
-- WHY: QEMU left the provision path in cadbd0e57 and the promise since is "a
-- clean Mac needs nothing installed". Nothing guarded it outside vz.rs, and a
-- regression is invisible where it is written: a developer Mac has Homebrew on
-- its shell PATH, so a bare `Command::new("qemu-img")` or a bare stock name
-- shadowed by a Homebrew build works there and fails on the user's clean Mac
-- (whose GUI launch gets PATH=/usr/bin:/bin:/usr/sbin:/sbin, 980-xcaf). The
-- 2026-09-27 clean-MacBook first-provision failure is why this exists.
--
-- WHAT IT CHECKS
--   Rust, over the macOS tray crate and the vm-layer's macOS provisioning
--   sources: every string-literal program given to Command::new(...) or to the
--   tray's spawn_bounded(...) helper must be an absolute path under a stock
--   root (/usr/bin/, /bin/, /usr/sbin/, /sbin/, /System/). A program held in a
--   variable is not a literal and is not judged here.
--   Shell, scripts/install-macos.sh: `export PATH=` naming only stock roots
--   must be the first statement after `set -euo pipefail`, so every later
--   command resolves from stock macOS whatever PATH `curl | bash` inherited.
--
-- Verdict grammar, unchanged from the .sh (offenders listed above it, now on
-- stderr):
--   ok:macos-stock-binaries:<n> spawn literal(s) checked, installer PATH pinned
--   violation:macos-stock-binaries:<k>
-- The root comes from TILLANDSIAS_MACOS_STOCK_ROOT rather than --root, because
-- @read-env widens fs.read only through a declared variable.

local R = env.get("TILLANDSIAS_MACOS_STOCK_ROOT")
local function at(p)
    if R == nil or R == "" then return p end
    return R .. "/" .. p
end
if R ~= nil and R ~= "" and not pcall(fs.walk, R) then
    verdict.emit("violation:macos-stock-binaries:no-root", 2)
end

local function readable(p)
    local ok, body = pcall(fs.read, p)
    if ok and type(body) == "string" then return body end
    return nil
end

local files = {}
local ok_w, walked = pcall(fs.walk, at("crates/tillandsias-macos-tray/src"), { suffix = ".rs" })
if ok_w and type(walked) == "table" then
    for _, f in ipairs(walked) do
        -- fs.walk answers absolute paths under an absolute root and relative
        -- ones otherwise; reduce both to the repo-relative spelling.
        local rel = f
        if R ~= nil and R ~= "" and rel:sub(1, #R + 1) == R .. "/" then rel = rel:sub(#R + 2) end
        if rel:sub(1, #"crates/") ~= "crates/" then rel = "crates/tillandsias-macos-tray/src/" .. rel end
        files[#files + 1] = rel
    end
end
for _, f in ipairs({ "crates/tillandsias-vm-layer/src/vz.rs", "crates/tillandsias-vm-layer/src/materialize/macos.rs" }) do
    if readable(at(f)) then files[#files + 1] = f end
end
table.sort(files)
if #files == 0 then
    verdict.emit("violation:macos-stock-binaries:no-sources-found-under:" .. (R or "."), 1)
end

-- Every `Command::new("...` or `spawn_bounded("...` literal on a line, in
-- order (the .sh's awk match loop; Lua patterns have no alternation, so the
-- two openers are found separately and the earlier one taken each time).
local OPENERS = { 'Command::new%("([^"]*)"', 'spawn_bounded%("([^"]*)"' }
local function spawns_on(line)
    local out, from = {}, 1
    while true do
        local best_s, best_e, best_lit
        for _, pat in ipairs(OPENERS) do
            local s, e, lit = line:find(pat, from)
            if s and (best_s == nil or s < best_s) then best_s, best_e, best_lit = s, e, lit end
        end
        if not best_s then return out end
        out[#out + 1] = best_lit
        from = best_e + 1
    end
end

local STOCK = { "/usr/bin/", "/bin/", "/usr/sbin/", "/sbin/", "/System/" }
local function is_stock(p)
    for _, root in ipairs(STOCK) do
        if p:sub(1, #root) == root and #p > #root then return true end
    end
    return false
end

local bad, checked = 0, 0
for _, f in ipairs(files) do
    local body = readable(at(f)) or ""
    for n, line in ipairs(text.lines(body)) do
        for _, prog in ipairs(spawns_on(line)) do
            checked = checked + 1
            if not is_stock(prog) then
                log.raw(string.format('  %s:%d: spawns "%s" — not an absolute stock-macOS path (/usr/bin, /bin, /usr/sbin, /sbin, /System)', f, n, prog))
                bad = bad + 1
            end
        end
    end
end

local inst = "scripts/install-macos.sh"
local ibody = readable(at(inst))
if ibody == nil then
    log.raw("  " .. inst .. ": missing")
    bad = bad + 1
else
    -- The first non-blank, non-comment line after `set -euo pipefail`.
    local seen, first = false, ""
    for _, line in ipairs(text.lines(ibody)) do
        if seen and not line:match("^%s*#") and not line:match("^%s*$") then first = line; break end
        if line:match("^set %-euo pipefail%s*$") then seen = true end
    end
    if first ~= "export PATH=/usr/bin:/bin:/usr/sbin:/sbin" then
        log.raw("  " .. inst .. ": the first statement after 'set -euo pipefail' must be 'export PATH=/usr/bin:/bin:/usr/sbin:/sbin' (found: '" .. first .. "')")
        bad = bad + 1
    end
end

if bad > 0 then
    verdict.emit("violation:macos-stock-binaries:" .. bad, 1)
end
verdict.emit("ok:macos-stock-binaries:" .. checked .. " spawn literal(s) checked, installer PATH pinned", 0)
