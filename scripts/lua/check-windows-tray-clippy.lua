-- @trace order:1434-vm7g, order:2203-wclp, spec:windows-native-tray
-- @env PATH HOME USERPROFILE CARGO_HOME RUSTUP_HOME RUSTUP_TOOLCHAIN CARGO_TARGET_DIR TMPDIR TEMP TMP TILLANDSIAS_WINDOWS_CLIPPY_UNAME TILLANDSIAS_WINDOWS_CLIPPY_CRATES_DIR TILLANDSIAS_WINDOWS_CLIPPY_MANIFEST TILLANDSIAS_WINDOWS_CLIPPY_BASE TILLANDSIAS_GATE_DIFF_BASE
--
-- check-windows-tray-clippy.lua: native clippy -D warnings on the Windows
-- tray, run where a Windows host actually runs it. Port of
-- check-windows-tray-clippy.sh (order 2203-wclp); verdict lines and exit codes
-- are byte-identical.
--
-- THE GAP. tillandsias-windows-tray is cfg(windows). On a Linux host its
-- Windows-only modules compile as src/stubs/ substitutes (716-f5kc), and on a
-- Windows host ./build.sh re-execs inside the WSL2 builder, which is Linux too.
-- So no gate linted the real sources: on 2026-09-27 native clippy -D warnings
-- found three errors plus a fourth behind them (1434-vm7g).
--
-- WHY THE PRE-PUSH HOOK AND NOT A build.sh STEP. A build.sh step would run in
-- the WSL builder and skip forever. git runs the pre-push hook natively in Git
-- Bash, so a check called from there reaches the real toolchain.
--
-- SCOPE. Only when the change touches a crate with cfg(windows) code (against
-- the base, plus untracked files there); a clippy build costs minutes. --all
-- forces a run.
--
-- Seams (fixture use): TILLANDSIAS_WINDOWS_CLIPPY_UNAME (stands in for
-- `uname -s`), TILLANDSIAS_WINDOWS_CLIPPY_MANIFEST (a Cargo.toml to lint; its
-- directory is the scope prefix), TILLANDSIAS_WINDOWS_CLIPPY_CRATES_DIR
-- (default crates), TILLANDSIAS_WINDOWS_CLIPPY_BASE (default
-- TILLANDSIAS_GATE_DIFF_BASE, then origin/linux-next).
--
-- Verdicts (last stdout line):
--   ok:windows-tray-clippy:clean
--   skip:windows-tray-clippy:not-windows:<uname>
--   skip:windows-tray-clippy:crate-untouched
--   skip:windows-tray-clippy:base-ref-unavailable:<ref>
--   could-not-run:windows-tray-clippy:no-cargo            (exit 3)
--   refused:windows-tray-clippy:<n>-errors                (exit 1)

local function nonempty(s) return s ~= nil and s ~= "" end
local function run(argv, ms) return proc.run({ argv = argv, timeout_ms = ms or 120000 }) end

local uname_s = env.get("TILLANDSIAS_WINDOWS_CLIPPY_UNAME")
if not nonempty(uname_s) then
    local u = run({ "uname", "-s" }, 10000)
    uname_s = text.trim(u.stdout or "")
end
if not (uname_s:match("^MINGW") or uname_s:match("^MSYS") or uname_s:match("^CYGWIN")) then
    verdict.emit("skip:windows-tray-clippy:not-windows:" .. (nonempty(uname_s) and uname_s or "unknown"), 0)
end

local crates_root = env.get("TILLANDSIAS_WINDOWS_CLIPPY_CRATES_DIR")
if not nonempty(crates_root) then crates_root = "crates" end

-- a crate has Windows code when a non-comment part of a src/*.rs line says
-- cfg(target_os = "windows") or cfg(windows)
local function has_windows_cfg(d)
    if not fs.exists(d .. "/src") then return false end
    local listed = fs.walk(d .. "/src", { suffix = ".rs" }) or {}
    local SRC = require("common.listed_read").read_all("windows-tray-clippy", listed)
    for _, f in ipairs(listed) do
        local body = SRC[f]
        if body then
            for line in (body .. "\n"):gmatch("([^\n]*)\n") do
                local code = line:gsub("//.*$", "")
                if code:find('cfg%(target_os *= *"windows"') or code:find("cfg%(windows") then return true end
            end
        end
    end
    return false
end

local candidates = {}
local manifest = env.get("TILLANDSIAS_WINDOWS_CLIPPY_MANIFEST")
if nonempty(manifest) then
    candidates[1] = manifest:match("^(.*)/[^/]*$") or "."
else
    -- the .sh globbed "$crates_root"/*/ and kept each dir with a Cargo.toml.
    -- fs.list lists files only, so walk for <root>/<name>/Cargo.toml exactly.
    local prefix = crates_root:gsub("/+$", "")
    local pat = "^" .. prefix:gsub("%p", "%%%0") .. "/([^/]+)/Cargo%.toml$"
    local names = {}
    for _, f in ipairs(fs.walk(prefix, { suffix = "Cargo.toml" }) or {}) do
        local n = f:match(pat)
        if n then names[#names + 1] = n end
    end
    table.sort(names)
    for _, n in ipairs(names) do
        local d = prefix .. "/" .. n
        if has_windows_cfg(d) then candidates[#candidates + 1] = d end
    end
end

local targets = {}
if arg[1] == "--all" then
    targets = candidates
else
    local base = env.get("TILLANDSIAS_WINDOWS_CLIPPY_BASE")
    if not nonempty(base) then base = env.get("TILLANDSIAS_GATE_DIFF_BASE") end
    if not nonempty(base) then base = "origin/linux-next" end
    local v = run({ "git", "rev-parse", "--verify", "--quiet", base .. "^{commit}" }, 30000)
    if v.status ~= "exited" or v.code ~= 0 then
        verdict.emit("skip:windows-tray-clippy:base-ref-unavailable:" .. base, 0)
    end
    for _, d in ipairs(candidates) do
        local a = run({ "git", "diff", "--name-only", base, "--", d .. "/" }, 60000)
        local b = run({ "git", "ls-files", "--others", "--exclude-standard", "--", d .. "/" }, 60000)
        if nonempty(text.trim((a.stdout or "") .. (b.stdout or ""))) then targets[#targets + 1] = d end
    end
end

if #targets == 0 then
    verdict.emit("skip:windows-tray-clippy:crate-untouched", 0)
end

local cv = run({ "cargo", "--version" }, 60000)
if cv.status ~= "exited" or cv.code ~= 0 then
    verdict.emit("could-not-run:windows-tray-clippy:no-cargo", 3)
end

local logbuf, failed, linted = {}, {}, 0
for _, d in ipairs(targets) do
    linted = linted + 1
    local r = run({ "cargo", "clippy", "--manifest-path", d .. "/Cargo.toml", "--all-targets", "--", "-D", "warnings" },
        3600000)
    logbuf[#logbuf + 1] = (r.stdout or "") .. (r.stderr or "")
    if r.status ~= "exited" or r.code ~= 0 then failed[#failed + 1] = d:match("([^/]*)$") end
end
log.raw("  linted " .. linted .. " crate(s) with cfg(windows) code natively")
if #failed == 0 then
    verdict.emit("ok:windows-tray-clippy:clean", 0)
end

-- each `error: <msg>` paired with the `--> <site>` that follows it, sorted and
-- de-duplicated; `error: could not compile` is clippy's summary, not a finding
local seen, findings, msg = {}, {}, nil
for line in (table.concat(logbuf, "") .. "\n"):gmatch("([^\n]*)\n") do
    if line:match("^error: could not compile") then
        -- skip
    elseif line:match("^error: ") then
        msg = line
    elseif msg and line:match("^ *%-%-> ") then
        local f = msg .. " @ " .. line:gsub("^ *%-%-> ", "")
        if not seen[f] then seen[f] = true; findings[#findings + 1] = f end
        msg = nil
    end
end
table.sort(findings)
for i = 1, math.min(20, #findings) do log.raw("  " .. findings[i]) end
log.raw("  refused in: " .. table.concat(failed, " "))
log.raw("  remedy: fix each site above; 'cargo clippy -p <crate> --all-targets -- -D warnings' reproduces it natively")
verdict.emit("refused:windows-tray-clippy:" .. #findings .. "-errors", 1)
