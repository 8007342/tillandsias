-- @trace order:2118-98dq
--
-- check-skill-canonicalization.lua — PORTED from check-skill-canonicalization.sh
-- (2118-98dq, check-[n-z] batch 3). Hand-written skills live ONCE, in skills/,
-- and every harness (.claude .opencode .codex .gemini .github) reaches them by
-- symlink. Rules are the .sh's, unchanged:
--   * a harness whose skills/ is itself a committed directory symlink must
--     point into skills/;
--   * otherwise each entry <h>/skills/<name> is judged. A symlink, read from
--     the INDEX first (so a checkout with core.symlinks=false agrees once the
--     symlink is committed) and else from the disk, must end in
--     /skills/<name> or be ../../skills/<name>. A generated openspec-* skill
--     whose SKILL.md carries generatedBy: is allowed. Anything else is a
--     harness-exclusive copy.
--
-- Grammar (stdout), unchanged:
--   ok:skills-canonical:<n> entries checked across 5 harnesses        exit 0
--   violation:harness-exclusive-skill:<n> offender(s)  + list + remedy   exit 1
--   violation:skills-canonical:index-unreadable — ...                  exit 1
--
-- Usage: tillandsias-plan script run scripts/lua/check-skill-canonicalization.lua

local CANONICAL = "skills"
local HARNESSES = { ".claude", ".opencode", ".codex", ".gemini", ".github" }
local GENERATED_PREFIX = "openspec-"

local function run(argv, stdin)
    return proc.run({ argv = argv, stdin = stdin, timeout_ms = 60000 })
end
local function okrun(argv) local r = run(argv); return r.status == "exited" and r.code == 0, r end
local function lines(s)
    local t = {}
    for l in ((s or "") .. "\n"):gmatch("([^\n]*)\n") do if l ~= "" then t[#t + 1] = l end end
    return t
end

-- The committed symlink targets (mode 120000) under every <h>/skills.
local idx = {}
do
    local argv = { "git", "ls-files", "-s", "--" }
    for _, h in ipairs(HARNESSES) do argv[#argv + 1] = h .. "/skills" end
    local _, r = okrun(argv)
    for _, l in ipairs(lines(r.stdout)) do
        local mode, sha, p = l:match("^(%d+) (%x+) %d+\t(.+)$")
        if mode == "120000" then
            local okc, c = okrun({ "git", "cat-file", "-p", sha })
            if not okc then
                out.line("violation:skills-canonical:index-unreadable — a committed symlink target could not be read back (1055-6yp8)")
                verdict.emit("violation:skills-canonical:index-unreadable", 1)
            end
            idx[p] = c.stdout or ""
        end
    end
end

local violations, checked = {}, 0
for _, h in ipairs(HARNESSES) do
    local dir = h .. "/skills"
    if okrun({ "test", "-d", dir }) then
        local whole = idx[dir]
        if whole then
            if whole:sub(-#CANONICAL) == CANONICAL or whole:sub(-(#CANONICAL + 1)) == CANONICAL .. "/" then
                checked = checked + 1
            else
                violations[#violations + 1] = dir .. " -> " .. whole .. " (directory symlink does not point into " .. CANONICAL .. "/)"
            end
        else
            local _, ls = okrun({ "ls", "-1", dir })
            for _, name in ipairs(lines(ls.stdout)) do
                local d = dir .. "/" .. name
                if okrun({ "test", "-e", d }) then
                    checked = checked + 1
                    local target = idx[d]
                    if (target == nil or target == "") and okrun({ "test", "-L", d }) then
                        local _, rl = okrun({ "readlink", d })
                        target = text.trim(rl.stdout or "")
                    end
                    if target and target ~= "" then
                        local want = "/" .. CANONICAL .. "/" .. name
                        if not (target:sub(-#want) == want or target == "../../" .. CANONICAL .. "/" .. name) then
                            violations[#violations + 1] = d .. " -> " .. target .. " (symlink does not point into " .. CANONICAL .. "/)"
                        end
                    else
                        local generated = false
                        if name:sub(1, #GENERATED_PREFIX) == GENERATED_PREFIX then
                            local okg = okrun({ "grep", "-qs", "generatedBy:", d .. "/SKILL.md" })
                            generated = okg
                        end
                        if not generated then
                            local kind = okrun({ "test", "-d", d }) and "real directory" or "regular file, not a symlink in the index"
                            violations[#violations + 1] = d .. " (" .. kind .. "; hand-written skills belong in " .. CANONICAL .. "/ and are reached by symlink)"
                        end
                    end
                end
            end
        end
    end
end

if #violations > 0 then
    out.line("violation:harness-exclusive-skill:" .. #violations .. " offender(s)")
    for _, v in ipairs(violations) do out.line("  " .. v) end
    for _, l in ipairs({
        "  why: a hand-written skill reached by only one harness drifts from the",
        "  canonical copy every other harness loads.",
        "  REMEDY: only when skills/<name> does NOT already exist —",
        "    git mv <path> skills/<name>",
        "  then, in every case, replace the harness path with a symlink:",
        "    rm -rf <path> && ln -s ../../skills/<name> <path>",
        "  If skills/<name> DOES exist, the harness copy is redundant: delete it",
        "  and symlink. Never 'git mv' onto an existing directory — it moves the",
        "  source into it and reports success.",
        "  On a checkout without symlink support (core.symlinks=false), make the",
        "  change on a host that has them; this check reads the index, so it will",
        "  agree once the symlink is committed.",
    }) do out.line(l) end
    verdict.emit("violation:harness-exclusive-skill:" .. #violations, 1)
end
out.line("ok:skills-canonical:" .. checked .. " entries checked across " .. #HARNESSES .. " harnesses")
verdict.emit("ok:skills-canonical", 0)
