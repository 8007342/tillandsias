-- @trace order:1528-ekri, order:731-d89b, spec:ci-release
--
-- check-script-exec-bits.lua — PORTED from check-script-exec-bits.sh, byte
-- for byte. Refuse a script that callers RUN by path but git tracks as
-- non-executable. See the .sh's header (kept in git history) for the
-- resolve-release-run.sh defect this closes, why the rule is narrow (most
-- scripts are invoked `bash scripts/x.sh`), and why BOTH the index and the
-- worktree are consulted (order 887-bz88: a pre-staging mode regression).
--
-- RUNS ON EVERY PUSH (pre-push hook / relay-preflight / build.sh fast
-- refusal): this port's parity proof is therefore run against several real
-- recent diffs, not only the clean tree (see the task report).
--
-- DISCLOSED DEVIATIONS, both the same shape as other ports in this batch:
--
--   * git ls-files / git config / grep / awk run through proc.run exactly as
--     the .sh ran them as subprocesses — the filter half,
--     scripts/lib/exec-bits-filter.awk, is reused UNCHANGED rather than
--     reimplemented in Lua: it is intricate, carries its own extensive
--     rationale in its own comments, and a byte-for-byte port of its CALLER
--     is a safer bet than a parallel port of ITS logic. The awk file is not
--     one of this batch's six scripts and stays exactly where it is.
--   * The two scratch files the awk invocation reads (candidate list, grep
--     hits) are written via `tee`/read via `cat` into a directory from
--     `mktemp -d`, run through proc.run — the same reasoning as
--     check-tracked-files-unwritten.lua: fs.write/fs.read are repo-rooted
--     and an external scratch dir (matching the .sh's own `mktemp -d`, never
--     inside the repository) is not widened by anything short of a real
--     subprocess.
--
-- Grammar (one line on stdout, unchanged legacy):
--   ok:script-exec-bits:<n> checked            exit 0
--   violation:script-not-executable:<n>        exit 1 (or exit 2 if the awk filter is missing)

local function run(argv, stdin)
    return proc.run({ argv = argv, stdin = stdin })
end

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local caller_files_r = run({
    "git", "ls-files",
    "scripts/*.sh", "build.sh", "skills/*/SKILL.md",
    "openspec/litmus-tests/*.yaml", ".github/workflows/*.yml",
})
local caller_files = {}
if caller_files_r.ok then
    for _, l in ipairs(text.lines(caller_files_r.stdout)) do
        if l ~= "" then caller_files[#caller_files + 1] = l end
    end
end
if #caller_files == 0 then
    log.raw("  note: no caller files found (not a git checkout?)")
    verdict.emit("ok:script-exec-bits:0 checked", 0)
end

-- ── candidates: non-executable in the INDEX or the WORKTREE, with a shebang ─
local filemode_honoured = true
do
    local cfg = run({ "git", "config", "--get", "core.filemode" })
    local v = trim(cfg.stdout)
    if v == "false" or v == "False" or v == "FALSE" then filemode_honoured = false end
end

local candidates = {}
do
    local ls = run({ "git", "ls-files", "-s", "scripts/" })
    if ls.ok then
        for _, entry in ipairs(text.lines(ls.stdout)) do
            if entry ~= "" then
                local sp = entry:find(" ", 1, true)
                local mode = sp and entry:sub(1, sp - 1) or ""
                local tab_at = nil
                for i = #entry, 1, -1 do
                    if entry:sub(i, i) == "\t" then tab_at = i; break end
                end
                local path = tab_at and entry:sub(tab_at + 1) or ""
                if path ~= "" then
                    local proceed = true
                    if mode ~= "100644" then
                        if not filemode_honoured then
                            proceed = false
                        elseif run({ "test", "-x", path }).ok then
                            proceed = false
                        end
                    end
                    if proceed then
                        local ok_r, content = pcall(fs.read, path)
                        if ok_r then
                            local nl = content:find("\n")
                            local first_line = nl and content:sub(1, nl - 1) or content
                            if first_line:sub(1, 2) == "#!" then
                                candidates[#candidates + 1] = path
                            end
                        end
                    end
                end
            end
        end
    end
end
local checked = #candidates

-- ── the awk filter, unchanged, run through proc.run ─────────────────────────
local AWK_PATH = "scripts/lib/exec-bits-filter.awk"
if not run({ "test", "-f", AWK_PATH }).ok then
    log.raw("  REFUSED: " .. AWK_PATH .. " is missing — this checker cannot run and will not")
    log.raw("  report a clean tree it never examined.")
    verdict.emit("violation:script-not-executable:0", 2)
end

local violations = {}

if #candidates > 0 then
    local scratch = trim(run({ "mktemp", "-d" }).stdout)

    local cands_text = table.concat(candidates, "\n") .. "\n"
    run({ "tee", scratch .. "/cands" }, cands_text)

    -- The sweep pattern is the UNION over all candidates — its per-candidate
    -- precision does not matter here, the awk pass re-tests each hit against
    -- each candidate — so this only has to be a superset. Candidate paths are
    -- interpolated UNESCAPED, exactly as the .sh did (a "." in a path name is
    -- a harmless wildcard here, not a correctness issue the .sh ever guarded
    -- against either).
    local alt = table.concat(candidates, "|")
    local pattern =
        [==[((^|[;&|(])[[:space:]]*"?(\./)?(]==] .. alt .. [==[))|(\$\([[:space:]]*"?(\./)?(]==] .. alt .. [==[))|(command:[[:space:]]*"?(([A-Za-z_][A-Za-z_0-9]*=[^[:space:]]*[[:space:]]+)*)(\./)?(]==] .. alt .. [==[))|((test[[:space:]]+-x|\[[[:space:]]+-x)[[:space:]]+"?(\./)?(]==] .. alt .. [==[))]==]

    local grep_argv = { "grep", "-nHE", pattern }
    for _, f in ipairs(caller_files) do grep_argv[#grep_argv + 1] = f end
    local hits_r = run(grep_argv)
    run({ "tee", scratch .. "/hits" }, hits_r.stdout or "")

    local awk_r = run({ "awk", "-f", AWK_PATH, scratch .. "/cands", scratch .. "/hits" })
    for _, line in ipairs(text.lines(awk_r.stdout or "")) do
        if line ~= "" then
            local tab_at = line:find("\t", 1, true)
            if tab_at then
                violations[#violations + 1] = { path = line:sub(1, tab_at - 1), hit = line:sub(tab_at + 1) }
            end
        end
    end

    run({ "rm", "-rf", scratch })
end

if #violations > 0 then
    for _, v in ipairs(violations) do
        local mode = trim(run({ "git", "ls-files", "-s", "--", v.path }).stdout)
        local sp = mode:find(" ", 1, true)
        mode = sp and mode:sub(1, sp - 1) or mode
        if mode == "100644" then
            log.raw("REFUSED: " .. v.path .. " is invoked by path but tracked as mode 100644 —")
            log.raw("         on a POSIX host that invocation is a permission error, not a verdict.")
            log.raw("         Fix: git update-index --chmod=+x " .. v.path)
        else
            log.raw("REFUSED: " .. v.path .. " is invoked by path but is NOT EXECUTABLE in the worktree —")
            log.raw("         on a POSIX host that invocation is a permission error, not a verdict.")
            log.raw("         The index still says 100755, so this would become a mode-only")
            log.raw("         regression the moment you stage it (order 887-bz88).")
            log.raw("         Fix: chmod +x " .. v.path)
        end
        log.raw("   caller: " .. v.hit:sub(1, 140))
    end
    verdict.emit("violation:script-not-executable:" .. #violations, 1)
end

verdict.emit("ok:script-exec-bits:" .. checked .. " checked", 0)
