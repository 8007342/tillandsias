-- @trace order:2246-fkea, order:2218-x4s3, order:2084-senw
-- @env TILLANDSIAS_NATIVE_ARGV_BASE TILLANDSIAS_GATE_DIFF_BASE
--
-- check-lua-fixture-native-argv-added.lua — refuse, in ADDED lines of
-- scripts/lua/*.lua and lib/lua/**/*.lua, the two shapes that pass on Linux
-- and macOS and fail on a native Windows runner:
--
--   a root from `pwd -P`     { "pwd", "-P" }. Under MSYS it answers /c/...,
--                            which the native runner refuses as a RELATIVE
--                            cwd ("proc.run: cwd '/c/Users/...' is relative").
--                            Use require("common.fixture").repo_root(), which
--                            asks git and gets C:/... there.
--   a "$PWD" probe join     `$PWD/${p#./}` inside a probe's shell: Git bash
--                            answers /c/..., which a native spawn cannot find.
--                            Use require("common.fixture").plan_binary().
--   a bare "bash" or "sed"   { "bash", ... } / { "sed", ... } as an argv.
--                            On native Windows a bare name resolves to WSL's
--                            bash.exe (another filesystem, another git) or to
--                            nothing. Use require("common.fixture").posix_shell()
--                            for the shell, and do sed's work in Lua (text.*).
--
-- MEASURED: three ports in one day hit these (steps 886 and 888, then #1388,
-- 2245-pf7x, on yolanda-windows' msys run 2026-11-23), each green on every
-- Linux host first. The fix was a hand-copied idiom at five sites, and nothing
-- stopped the next fixture writing either shape.
--
-- DIFF-SCOPED: only lines this change ADDS (tracked and untracked), so
-- standing code is not re-litigated. Comment lines are skipped. A site that
-- truly needs the shape (a fixture pinning MSYS behaviour itself) states why
-- with a `native-argv: <reason>` marker on the line or in the two lines above.
--
-- Grammar (one line on stdout; each refused site on stderr):
--   ok:lua-fixture-native-argv-added:<n> checked                 exit 0
--   ok:lua-fixture-native-argv-added:base-unavailable            exit 0  (no base; nothing judged)
--   violation:lua-fixture-native-argv-added:<n>                  exit 1
--   could-not-run:lua-fixture-native-argv-added                  exit 3  (not inside a git work tree)
--
-- Pinned by scripts/lua/test-lua-fixture-native-argv-added.lua.

local function nonempty(v) return v ~= nil and v ~= "" end

local function git(argv, cwd)
    local r = proc.run({ argv = argv, cwd = cwd, timeout_ms = 60000 })
    if r.status ~= "exited" or r.code ~= 0 then return nil end
    return r.stdout or ""
end

local top = git({ "git", "rev-parse", "--show-toplevel" })
if not top then
    verdict.could_not_run("lua-fixture-native-argv-added", "not inside a git work tree")
end
local ROOT = text.trim(top)

local base_ref = env.get("TILLANDSIAS_NATIVE_ARGV_BASE")
if not nonempty(base_ref) then base_ref = env.get("TILLANDSIAS_GATE_DIFF_BASE") end
if not nonempty(base_ref) then base_ref = "origin/linux-next" end

-- 2241-f8jg: `--verify <40-hex>` answers 0 for an object that does not exist;
-- peel to a commit so a missing base is named, never judged as ok.
if not git({ "git", "rev-parse", "--verify", "--quiet", base_ref .. "^{commit}" }, ROOT) then
    log.raw("  note: base ref '" .. base_ref .. "' unavailable — added-line enforcement skipped")
    verdict.ok("lua-fixture-native-argv-added", "base-unavailable")
end

-- Each shape: a Lua pattern over one line, and the remedy it names.
local SHAPES = {
    { pat = '"pwd"%s*,%s*"%-P"', what = 'a root taken from `pwd -P` (MSYS answers /c/..., a "relative" cwd natively)',
      fix = 'require("common.fixture").repo_root()' },
    { pat = '{%s*"bash"%s*[,}]', what = 'a bare "bash" argv (resolves to WSL\'s bash.exe on native Windows)',
      fix = 'require("common.fixture").posix_shell() as argv[1]' },
    { pat = '{%s*"sed"%s*[,}]', what = 'a bare "sed" argv (absent or WSL\'s on native Windows)',
      fix = 'text.* in Lua, or posix_shell() running a script that calls sed' },
    -- The third trap (yolanda, #1389): a probe that joins its answer to
    -- "$PWD" INSIDE Git bash hands back /c/..., which a native spawn cannot
    -- resolve. Plain-text match: `$PWD/${p#./}` is the shape every copy uses.
    -- native-argv: the shape this decider refuses, as its own pattern literal
    { plain = '$PWD/${p#./}', what = 'a probe path joined to "$PWD" inside the shell (Git bash answers /c/..., unresolvable natively)',
      fix = 'require("common.fixture").plan_binary(), or native_path() on the answer' },
}

local SPECS = { "scripts/lua/*.lua", "lib/lua/*.lua", "lib/lua/**/*.lua" }
local function with_specs(argv)
    argv[#argv + 1] = "--"
    for _, s in ipairs(SPECS) do argv[#argv + 1] = s end
    return argv
end

local seen, files = {}, {}
for _, argv in ipairs({
    with_specs({ "git", "diff", "--name-only", "--diff-filter=AM", base_ref }),
    with_specs({ "git", "ls-files", "--others", "--exclude-standard" }),
}) do
    for _, f in ipairs(text.lines(git(argv, ROOT) or "")) do
        f = text.trim(f)
        if f ~= "" and not seen[f] then seen[f] = true; files[#files + 1] = f end
    end
end
table.sort(files)

-- New-file line numbers of the lines a unified -U0 diff adds.
local function added_lines(diff)
    local out, n = {}, 0
    for _, l in ipairs(text.lines(diff)) do
        if text.starts_with(l, "@@") then
            n = tonumber(l:match("^@@ %-[%d,]+ %+(%d+)")) or 0
        elseif text.starts_with(l, "+++") then
            -- file header
        elseif text.starts_with(l, "+") then
            out[#out + 1] = n
            n = n + 1
        end
    end
    return out
end

local checked, violations = 0, 0
for _, f in ipairs(files) do
    local path = ROOT .. "/" .. f
    if fs.exists(path) then
        checked = checked + 1
        local lines = text.lines(fs.read(path) or "")
        local added
        if git({ "git", "ls-files", "--error-unmatch", "--", f }, ROOT) then
            added = added_lines(git({ "git", "diff", "-U0", base_ref, "--", f }, ROOT) or "")
        else
            added = {}
            for i = 1, #lines do added[#added + 1] = i end
        end
        for _, ln in ipairs(added) do
            local line = lines[ln] or ""
            local trimmed = line:gsub("^%s+", "")
            if not text.starts_with(trimmed, "--") then
                for _, sh in ipairs(SHAPES) do
                    if (sh.plain and line:find(sh.plain, 1, true)) or (sh.pat and line:find(sh.pat)) then
                        local reasoned = false
                        for i = math.max(1, ln - 2), ln do
                            if text.contains(lines[i] or "", "native-argv:") then reasoned = true; break end
                        end
                        if not reasoned then
                            violations = violations + 1
                            log.raw("REFUSED: " .. f .. ":" .. ln .. " adds " .. sh.what .. ":")
                            log.raw("    " .. trimmed)
                            log.raw("  use " .. sh.fix .. " (2246-fkea), or keep it and say why with a")
                            log.raw("  `native-argv: <reason>` comment on the line or just above it.")
                        end
                    end
                end
            end
        end
    end
end

if violations > 0 then
    log.raw("  why: each site above passes on Linux and macOS and fails on a native Windows runner (2246-fkea)")
    log.raw("  remedy: common.fixture's repo_root() / posix_shell(), or a native-argv: <reason> marker, as each REFUSED block says")
    verdict.emit("violation:lua-fixture-native-argv-added:" .. violations, 1)
end
verdict.ok("lua-fixture-native-argv-added", checked .. " checked")
