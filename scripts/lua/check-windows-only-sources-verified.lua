-- @trace order:2243-wosv, order:738-3pft, order:801-ajcd, order:739-6r6n
-- @env WINDOWS_ONLY_ROOT
-- @env WINDOWS_ONLY_STAMP
-- @env WINDOWS_ONLY_ATTEST_DIR
-- @env WINDOWS_ONLY_ATTEST_COMMAND
-- @env ONLY_PLATFORM
-- @env ONLY_CRATE
-- @stdin 16777216
--
-- check-windows-only-sources-verified.lua — the Lua port of
-- check-windows-only-sources-verified.sh and its macOS wrapper (2243-wosv s2).
--
-- Are the platform-only sources of a tray crate (the `mod x;` lines under a
-- `#[cfg(target_os = "<platform>")]` in its main.rs) verified as they stand?
-- A linux host cannot compile them, so a host that can records the claim:
--
--   check   (default) prefer a TRACKED attestation under plan/attestations/
--           (`<scope>-sources.<host>.json`, per-file git blob hashes); else the
--           HOST-LOCAL stamp under $GIT_DIR (a digest, plus per-file digests in
--           <stamp>.d/ so drift names the file).
--   stamp   [--from <transcript>|-] record the current contents in the local stamp
--   attest  [--host <label>] --from <transcript>|-  the same checked claim, as a
--           tracked file the whole fleet reads
--
-- Both writers demand evidence: a cargo-test transcript with `test ... ok|FAILED`
-- lines and no FAILED test outside scripts/<platform>-only-known-red.txt.
-- The legacy `stamp pass --from <file>` shape is still accepted (801-ajcd).
--
-- Platform: `--platform macos` (first argument), or ONLY_PLATFORM/ONLY_CRATE;
-- default windows / tillandsias-windows-tray.
-- Seams (the fixture's): WINDOWS_ONLY_ROOT, WINDOWS_ONLY_STAMP,
-- WINDOWS_ONLY_ATTEST_DIR, WINDOWS_ONLY_ATTEST_COMMAND.
--
-- Verdicts (exit 0 unless noted), byte-identical to the .sh:
--   ok:sources-verified:<scope>:<n>        skip:no-sources:<scope>
--   stale:sources-drifted:<scope>:<n>:<first>
--   missing:sources-no-attestation:<scope>
--   ok:sources-attested:<scope>:<n>
--   refused:stamp-needs-evidence:<why>     exit 1
--   refused:undeclared-failure:<test>      exit 1
--
-- I/O: the stamp sits under $GIT_DIR (outside the tree in a worktree) and the
-- seams point anywhere, so paths are read and written through cat/tee/mkdir/rm
-- (proc.run with stdin=), not fs, which is confined to the repository.

local SELF = "check-windows-only-sources-verified.lua"

-- Tools: plain names on unix; Git for Windows' own usr/bin on a native host.
local GIT_USR = nil
do
    local ep = text.trim(proc.run({ argv = { "git", "--exec-path" }, timeout_ms = 10000 }).stdout or "")
    if ep:find("^%a:/.*/libexec/git%-core$") then
        GIT_USR = (ep:gsub("/[^/]+/libexec/git%-core$", "/usr/bin/"))
    end
end
local function tool(n) return GIT_USR and (GIT_USR .. n .. ".exe") or n end

local function run(argv, stdin_s)
    local spec = { argv = argv, timeout_ms = 60000 }
    if stdin_s then spec.stdin = stdin_s end
    return proc.run(spec)
end
local function read(p)
    local r = run({ tool("cat"), "--", p })
    if r.code ~= 0 then return nil end
    return r.stdout or ""
end
local function exists(p) return run({ tool("test"), "-f", p }).code == 0 end
local function write(p, s) return run({ tool("tee"), "--", p }, s).code == 0 end
local function mkdirp(p) run({ tool("mkdir"), "-p", "--", p }) end
local function rmrf(p) run({ tool("rm"), "-rf", "--", p }) end

-- Arguments; `--platform <p>` first selects the macOS (or any) scope.
local A = {}
for i = 1, #arg do A[#A + 1] = arg[i] end
local platform_arg = nil
if A[1] == "--platform" then platform_arg = A[2]; table.remove(A, 1); table.remove(A, 1) end

local PLATFORM = platform_arg or env.get("ONLY_PLATFORM") or "windows"
local CRATE = env.get("ONLY_CRATE")
if not CRATE or CRATE == "" or platform_arg then CRATE = "tillandsias-" .. PLATFORM .. "-tray" end
if PLATFORM == "" then PLATFORM = "windows" end

local ROOT = env.get("WINDOWS_ONLY_ROOT")
if not ROOT or ROOT == "" then
    ROOT = text.trim(run({ "git", "rev-parse", "--show-toplevel" }).stdout or "")
end
local GIT_DIR = text.trim(run({ "git", "-C", ROOT, "rev-parse", "--absolute-git-dir" }).stdout or "")
if GIT_DIR == "" then GIT_DIR = ROOT .. "/.git" end
local STAMP = env.get("WINDOWS_ONLY_STAMP")
if not STAMP or STAMP == "" then STAMP = GIT_DIR .. "/tillandsias-" .. PLATFORM .. "-only-verified" end
local TRAY_SRC = ROOT .. "/crates/" .. CRATE .. "/src"
local SCOPE = PLATFORM .. "-only"
local ATTEST_DIR = env.get("WINDOWS_ONLY_ATTEST_DIR")
if not ATTEST_DIR or ATTEST_DIR == "" then ATTEST_DIR = ROOT .. "/plan/attestations" end

local function lines(s)
    local t = {}
    for l in ((s or "") .. "\n"):gmatch("([^\n]*)\n") do t[#t + 1] = l end
    if t[#t] == "" then t[#t] = nil end
    return t
end

-- Platform-only sources: `mod x;` on a cfg line or the line after it.
local SOURCES = {}
do
    local main = read(TRAY_SRC .. "/main.rs")
    if main then
        local L, seen, mods = lines(main), {}, {}
        local cfg = '#[cfg(target_os = "' .. PLATFORM .. '")]'
        for i, l in ipairs(L) do
            if l:find(cfg, 1, true) then
                for _, c in ipairs({ l, L[i + 1] or "" }) do
                    local m = c:match("^mod ([a-z_]+);")
                    if m and not seen[m] then seen[m] = true; mods[#mods + 1] = m end
                end
            end
        end
        table.sort(mods) -- `sort -u` in the C locale over [a-z_]
        for _, m in ipairs(mods) do
            local f = TRAY_SRC .. "/" .. m .. ".rs"
            if exists(f) then SOURCES[#SOURCES + 1] = f end
        end
    end
end
if #SOURCES == 0 then verdict.emit("skip:no-sources:" .. SCOPE, 0) end

local function rel_of(f) return f:sub(#ROOT + 2) end
-- The .sh digest: sha256 over, per file, `<rel>\0<sha256 hex>\n`.
local function digest_of(files)
    local acc = {}
    for _, f in ipairs(files) do
        acc[#acc + 1] = rel_of(f) .. "\0" .. hash.sha256(read(f) or "") .. "\n"
    end
    return hash.sha256(table.concat(acc))
end
local function blob_hash(f)
    return text.trim(run({ "git", "-C", ROOT, "hash-object", "--", f }).stdout or "")
end
local current = digest_of(SOURCES)

local TRANSCRIPT_FROM = ""
local function parse_from(a1, a2, a3)
    TRANSCRIPT_FROM = ""
    if a1 == "--from" then TRANSCRIPT_FROM = a2 or ""
    elseif a1 == "pass" and a2 == "--from" then TRANSCRIPT_FROM = a3 or "" end
end

local RESULT_LINE = ""
local function require_evidence(sub)
    if TRANSCRIPT_FROM == "" then
        verdict.emit("refused:stamp-needs-evidence:usage: " .. SELF .. " " .. sub
            .. " --from <cargo-test-output>; a stamp with no transcript is an assertion, not a verification", 1)
    end
    local T
    if TRANSCRIPT_FROM == "-" then T = stdin.read() else T = read(TRANSCRIPT_FROM) or "" end
    local tl = lines(T)
    local has = false
    for _, l in ipairs(tl) do
        if text.is_match(l, [[^test .* \.\.\. (ok|FAILED|ignored)]]) then has = true; break end
    end
    if not has then verdict.emit("refused:stamp-needs-evidence:the transcript contains no test results", 1) end
    local kr = {}
    for _, k in ipairs(lines(read(ROOT .. "/scripts/" .. PLATFORM .. "-only-known-red.txt") or "")) do kr[k] = true end
    for _, l in ipairs(tl) do
        if text.is_match(l, [[^test .* \.\.\. FAILED]]) then
            local name = (l:match("^test%s+(%S+)") or ""):gsub(".*::", "")
            if name ~= "" and not kr[name] then verdict.emit("refused:undeclared-failure:" .. name, 1) end
        end
    end
    local rs = {}
    for _, l in ipairs(tl) do
        if l:find("^test result:") then rs[#rs + 1] = (l:gsub('"', "'")) end
    end
    RESULT_LINE = table.concat(rs, ";")
    if RESULT_LINE == "" then RESULT_LINE = "test results present; no summary line" end
end

local function flat(rel) return (rel:gsub("/", "_")) end
local function json_escape(s) return (s:gsub("\\", "\\\\"):gsub('"', '\\"')) end

-- UTC ISO-8601 from epoch ms (civil-from-days, H. Hinnant).
local function utc_now()
    local s = time.now_ms() // 1000
    local days, rem = s // 86400, s % 86400
    local z = days + 719468
    local era = z // 146097
    local doe = z - era * 146097
    local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    local mp = (5 * doy + 2) // 153
    local d = doy - (153 * mp + 2) // 5 + 1
    local m = mp < 10 and mp + 3 or mp - 9
    local y = yoe + era * 400 + (m <= 2 and 1 or 0)
    return string.format("%04d-%02d-%02dT%02d:%02d:%02dZ", y, m, d, rem // 3600, rem % 3600 // 60, rem % 60)
end

local function host_label()
    local u = text.trim(run({ "uname", "-s" }).stdout or "")
    if u == "Darwin" then return "macos" end
    if u:find("^MINGW") or u:find("^MSYS") or u:find("^CYGWIN") or GIT_USR then return "windows" end
    if u == "Linux" then return "linux" end
    return "unknown"
end

local sub = A[1] or "check"

if sub == "stamp" then
    parse_from(A[2], A[3], A[4])
    require_evidence("stamp")
    write(STAMP, current .. "\n")
    rmrf(STAMP .. ".d"); mkdirp(STAMP .. ".d")
    for _, f in ipairs(SOURCES) do
        write(STAMP .. ".d/" .. flat(rel_of(f)), digest_of({ f }) .. "\n")
    end
    verdict.emit("ok:sources-verified:" .. SCOPE .. ":" .. #SOURCES, 0)
elseif sub == "attest" then
    local label, i = "", 2
    if A[2] == "--host" then label = A[3] or ""; i = 4 end
    if label == "" then label = host_label() end
    parse_from(A[i], A[i + 1], A[i + 2])
    require_evidence("attest")
    local commit = text.trim(run({ "git", "-C", ROOT, "rev-parse", "HEAD" }).stdout or "")
    if commit == "" then commit = "unknown" end
    local krl = {}
    for _, k in ipairs(lines(read(ROOT .. "/scripts/" .. PLATFORM .. "-only-known-red.txt") or "")) do
        if k ~= "" then krl[#krl + 1] = '"' .. json_escape(k) .. '"' end
    end
    local cmd = env.get("WINDOWS_ONLY_ATTEST_COMMAND")
    if not cmd or cmd == "" then cmd = "cargo test -p " .. CRATE .. " --bins" end
    local o = { "{",
        '  "scope": "' .. SCOPE .. '",',
        '  "host": "' .. label .. '",',
        '  "attested_at": "' .. utc_now() .. '",',
        '  "commit": "' .. commit .. '",',
        '  "command": "' .. cmd .. '",',
        '  "result": "' .. json_escape(RESULT_LINE) .. '",',
        '  "sources": {' }
    for n, f in ipairs(SOURCES) do
        o[#o + 1] = '    "' .. rel_of(f) .. '": "' .. blob_hash(f) .. '"' .. (n < #SOURCES and "," or "")
    end
    o[#o + 1] = "  },"
    o[#o + 1] = '  "known_red": [' .. table.concat(krl, ", ") .. "]"
    o[#o + 1] = "}"
    mkdirp(ATTEST_DIR)
    local out_p = ATTEST_DIR .. "/" .. SCOPE .. "-sources." .. label .. ".json"
    write(out_p, table.concat(o, "\n") .. "\n")
    log.raw("wrote " .. out_p)
    verdict.emit("ok:sources-attested:" .. SCOPE .. ":" .. #SOURCES, 0)
elseif sub == "check" then
    -- The first attestation in glob order (any host's word is the fleet's).
    local ls = run({ tool("ls"), "-1", "--", ATTEST_DIR })
    local cands = {}
    local pre = SCOPE .. "-sources."
    for _, n in ipairs(lines(ls.code == 0 and ls.stdout or "")) do
        if n:sub(1, #pre) == pre and n:sub(-5) == ".json" then cands[#cands + 1] = n end
    end
    table.sort(cands)
    local att = nil
    for _, n in ipairs(cands) do
        if exists(ATTEST_DIR .. "/" .. n) then att = read(ATTEST_DIR .. "/" .. n); break end
    end
    if att then
        local drifted, first = 0, ""
        for _, f in ipairs(SOURCES) do
            local rel = rel_of(f)
            local want = nil
            for _, l in ipairs(lines(att)) do
                if l:find('"' .. rel .. '":', 1, true) then want = l:match(':%s*"([^"]*)"') ; break end
            end
            if not (want and want ~= "" and want == blob_hash(f)) then
                drifted = drifted + 1
                if first == "" then first = rel end
            end
        end
        if drifted == 0 then verdict.emit("ok:sources-verified:" .. SCOPE .. ":" .. #SOURCES, 0) end
        verdict.emit("stale:sources-drifted:" .. SCOPE .. ":" .. drifted .. ":" .. first, 0)
    end
    if not exists(STAMP) then verdict.emit("missing:sources-no-attestation:" .. SCOPE, 0) end
    if text.trim(read(STAMP) or "") == current then
        verdict.emit("ok:sources-verified:" .. SCOPE .. ":" .. #SOURCES, 0)
    end
    local changed, first = 0, ""
    for _, f in ipairs(SOURCES) do
        local rel = rel_of(f)
        local prev = read(STAMP .. ".d/" .. flat(rel))
        if not (prev and text.trim(prev) == digest_of({ f })) then
            changed = changed + 1
            if first == "" then first = rel end
        end
    end
    if changed == 0 then changed = #SOURCES; first = "all(no-per-file-records)" end
    verdict.emit("stale:sources-drifted:" .. SCOPE .. ":" .. changed .. ":" .. first, 0)
else
    log.raw("usage: " .. SELF .. " [--platform <p>] [check|stamp|attest]")
    verdict.emit("refused:usage:" .. SCOPE .. ":unknown-subcommand:" .. sub, 1)
end
