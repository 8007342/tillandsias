-- @trace order:1087-h2z9, order:2118-9mk4
--
-- check-no-tracked-binaries.lua — PORTED from check-no-tracked-binaries.sh
-- (2118-9mk4, check-[n-z] batch 2). No tracked file may be a binary unless it
-- sits under an allowlisted asset prefix, and no tracked file may carry an
-- executable-binary extension at all (not even under an allowed prefix).
--
-- Two lanes, as before:
--   numstat lane   `git diff --numstat <empty-tree> HEAD` rows with "-\t-" are
--                  files git itself classifies as binary;
--   extension lane `git ls-files` paths ending .so .dylib .dll .exe .a .o
--                  .rlib .wasm .pdb (case-insensitive), allowlisted or not.
--
-- Grammar (stdout), unchanged:
--   ok:no-tracked-binaries:<n> binary-classified <m> allowlisted   exit 0
--   blocked:tracked-binaries:<path>[,<path>...]                    exit 1
-- `fixture` runs the five scenarios in scratch repos under target/ (the lua fs
-- is checkout-confined), each judged in-process by the same scan:
--   ok: all no-tracked-binaries scenarios passed                   exit 0
--   fail: no-tracked-binaries fixture scenarios failed             exit 1
--
-- Usage: tillandsias-plan script run scripts/lua/check-no-tracked-binaries.lua [-- fixture]

local ALLOW_PREFIXES = {
    "assets/icons/",                           -- SVG species icon families (git-binary-classified)
    "crates/tillandsias-macos-tray/assets/",   -- icon.icns, icon.png, tray-icon.png
    "crates/tillandsias-windows-tray/assets/", -- tillandsias.ico
    "images/dmg/",                             -- dmg-background.png/.svg
    "tests/fixtures/audio/kumbia/",            -- 2078-kmbx: 11 FLAC excerpts, operator ruling 2026-11-10
}
local EXTS = { so = true, dylib = true, dll = true, exe = true, a = true, o = true, rlib = true, wasm = true, pdb = true }

local function git(cwd, args)
    local argv = { "git" }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    return proc.run({ argv = argv, cwd = cwd, timeout_ms = 120000 })
end
local function lines(s)
    local t = {}
    for l in ((s or "") .. "\n"):gmatch("([^\n]*)\n") do if l ~= "" then t[#t + 1] = l end end
    return t
end

-- Returns ok(bool), the verdict line.
local function scan(cwd)
    local empty = text.trim(git(cwd, { "hash-object", "-t", "tree", "/dev/null" }).stdout or "")
    local offenders, seen = {}, {}
    local classified, allowed = 0, 0
    for _, row in ipairs(lines(git(cwd, { "diff", "--numstat", empty, "HEAD" }).stdout)) do
        local a, b, p = row:match("^([^\t]*)\t([^\t]*)\t(.*)$")
        if a == "-" and b == "-" then
            classified = classified + 1
            local ok = false
            for _, pre in ipairs(ALLOW_PREFIXES) do
                if p:sub(1, #pre) == pre then ok = true; break end
            end
            if ok then allowed = allowed + 1
            else offenders[#offenders + 1] = p; seen[p] = true end
        end
    end
    for _, p in ipairs(lines(git(cwd, { "ls-files" }).stdout)) do
        local ext = p:match("%.([%w]+)$")
        if ext and EXTS[ext:lower()] and not seen[p] then
            offenders[#offenders + 1] = p; seen[p] = true
        end
    end
    if #offenders > 0 then
        return false, "blocked:tracked-binaries:" .. table.concat(offenders, ",")
    end
    return true, ("ok:no-tracked-binaries:%d binary-classified %d allowlisted"):format(classified, allowed)
end

local function fixture()
    fs.mkdir("target")
    local mk = proc.run({ argv = { "mktemp", "-d", "target/no-tracked-binaries-fixture.XXXXXX" }, timeout_ms = 5000 })
    local rel = text.trim(mk.stdout or "")
    local top = text.trim(git(nil, { "rev-parse", "--show-toplevel" }).stdout or "")
    -- proc.run wants an absolute cwd; the scratch stays inside the checkout.
    local tdir = (rel ~= "" and top ~= "") and (top .. "/" .. rel) or ""
    if tdir == "" then out.line("fail: no-tracked-binaries fixture scenarios failed"); verdict.emit("violation:no-tracked-binaries:fixture-scratch", 1) end
    local function repo(name, files)
        local d = tdir .. "/" .. name
        fs.mkdir(d)
        git(d, { "init", "-q" })
        git(d, { "config", "user.email", "fixture@localhost" })
        git(d, { "config", "user.name", "fixture" })
        for p, body in pairs(files) do
            local dir = path.dirname(d .. "/" .. p)
            fs.mkdir(dir)
            fs.write(d .. "/" .. p, body)
        end
        git(d, { "add", "-A" })
        git(d, { "commit", "-qm", name })
        return d
    end
    local fail = false
    local function arm(okmsg, failmsg, cond)
        if cond then out.line("ok: " .. okmsg) else out.line("FIXTURE-FAIL: " .. failmsg); fail = true end
    end
    local ok1, v1 = scan(repo("clean", { ["README.md"] = "just text\n" }))
    arm("NEGATIVE text-only repo passes", "text-only repo did not pass", ok1 and v1:match("^ok:no%-tracked%-binaries:0 ") ~= nil)
    local ok2, v2 = scan(repo("elf", { ["sneaky-artifact"] = "\127ELF\2\1\1\0\0\0\0\0binary\0payload\n" }))
    arm("tracked ELF blob refused (numstat lane)", "tracked ELF blob not refused", not ok2 and v2 == "blocked:tracked-binaries:sneaky-artifact")
    local ok3, v3 = scan(repo("ext", { ["libstub.so"] = "", ["ok.txt"] = "text\n" }))
    arm("zero-byte .so refused (extension lane)", "zero-byte .so not refused", not ok3 and v3 == "blocked:tracked-binaries:libstub.so")
    local ok4, v4 = scan(repo("allow", { ["assets/icons/icon.png"] = "PNG\0\0fake\0image\n" }))
    arm("allowlisted-prefix image passes", "allowlisted image did not pass", ok4 and v4 == "ok:no-tracked-binaries:1 binary-classified 1 allowlisted")
    local ok5, v5 = scan(repo("trojan", { ["assets/icons/helper.so"] = "\127ELF\2trojan\0\n" }))
    arm("executable extension inside allowed prefix still refused", ".so under allowed prefix not refused",
        not ok5 and v5:match("^blocked:tracked%-binaries:.*helper%.so") ~= nil)
    proc.run({ argv = { "find", tdir, "-delete" }, timeout_ms = 30000 })
    if not fail then
        out.line("ok: all no-tracked-binaries scenarios passed")
        verdict.emit("ok:no-tracked-binaries:fixture", 0)
    end
    out.line("fail: no-tracked-binaries fixture scenarios failed")
    verdict.emit("violation:no-tracked-binaries:fixture", 1)
end

if arg and arg[1] == "fixture" then fixture() end

local ok, line = scan(nil)
out.line(line)
if ok then verdict.emit("ok:no-tracked-binaries", 0) end
verdict.emit("blocked:tracked-binaries", 1)
