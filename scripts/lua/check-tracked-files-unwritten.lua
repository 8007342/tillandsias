-- @env PATH
-- @trace order:1063-363b, order:2188-qaaj, order:1230-26sy, order:2384-5fj5
--
-- check-tracked-files-unwritten.lua — the gate must not write into the checkout it is measuring.
--
-- On lenovinha 2026-09-05 scripts/plan-binary-probe.sh in the WORKING TREE was overwritten with
-- check-fragment-status-loss.sh mid-gate; trunk was intact and no commit touched it. The probe is an
-- instrument: half the gate resolves the plan binary through it, so every verdict after the write measured
-- something else, confidently. The writer was never found; this makes the next one name itself.
--
-- CONTENT, NOT `git status`: a modify-then-restore leaves git clean while every measurement in between saw
-- different bytes. Every tracked path is hashed by `git hash-object --no-filters` (the bytes on disk, one
-- spawn for the whole tree); a tracked symlink by its target string, never through it (2188-qaaj: a link
-- to a directory used to drop out of the baseline, so retargeting it went unseen). A tracked path that is
-- gone counts as written. Ported from the .sh of the same name.
--
-- Usage: tillandsias-plan script run scripts/lua/check-tracked-files-unwritten.lua -- snapshot|verify <state-file> [<checkout>]
-- Verdict (one line on stdout):
--   ok:tracked-files-unwritten:<n> files                exit 0
--   violation:gate-wrote-tracked-files:<n>              exit 1, the paths on stderr
--   blocked:tracked-files-unwritten:<reason>            exit 2

local SH = require("common.fixture").posix_shell()
local function afford(why, remedy) log.raw("  why: " .. why .. "\n  remedy: " .. remedy) end
local function blocked(reason, why, remedy) afford(why, remedy); verdict.emit("blocked:tracked-files-unwritten:" .. reason, 2) end

local mode, state = (arg or {})[1], (arg or {})[2]
if not mode or mode == "" or not state or state == "" then
    blocked("usage", "it needs a mode and a state file, and was given " .. (mode or "no mode") .. "/" .. (state or "no state file"),
        "check-tracked-files-unwritten.lua -- snapshot <state-file> before the gate, then -- verify <state-file> after it")
end
if mode ~= "snapshot" and mode ~= "verify" then
    blocked("unknown-mode:" .. mode, mode .. " is not a mode of this script", "use snapshot <state-file> or verify <state-file>")
end

local DIR = (arg or {})[3] or "." -- the checkout; a fixture names its scratch repo
local function git(argv, stdin)
    table.insert(argv, 1, DIR); table.insert(argv, 1, "-C"); table.insert(argv, 1, "git")
    return proc.run{ argv = argv, stdin = stdin, timeout_ms = 300000 }
end

-- path -> hash for the whole tracked set; nil and a reason when it cannot be had.
local function hash_tracked()
    local ls = git{ "ls-files", "-s", "-z" }
    if ls.code ~= 0 then return nil, "ls-files" end
    local files, links, n, gone = {}, {}, 0, {}
    for p in (git{ "ls-files", "-d", "-z" }.stdout or ""):gmatch("([^%z]+)") do gone[p] = true end
    for e in (ls.stdout or ""):gmatch("([^%z]+)") do
        local m, p = e:match("^(%d+) %x+ %d\t(.*)$")
        if p then
            n = n + 1
            if m == "120000" then links[#links + 1] = p elseif not gone[p] then files[#files + 1] = p end
        end
    end
    local h = {}
    if #files > 0 then
        local r = git({ "hash-object", "--no-filters", "--stdin-paths" }, table.concat(files, "\n") .. "\n")
        local i = 0
        for x in (r.stdout or ""):gmatch("%x+") do i = i + 1; h[files[i]] = x end
        if r.code ~= 0 or i ~= #files then return nil, "unhashable", n - i end
    end
    if #links > 0 then
        -- On a checkout without symlinks git writes the target as a plain file; its content is the target.
        local argv = { SH, "-s", "--", DIR }
        for _, p in ipairs(links) do argv[#argv + 1] = p end
        local r = proc.run{ argv = argv, timeout_ms = 120000, stdin = 'cd "$1" || exit 9; shift\n'
            .. 'for p in "$@"; do if [ -L "$p" ]; then printf "L%s\\n" "$(readlink -- "$p")"; '
            .. 'elif [ -f "$p" ]; then printf "L%s\\n" "$(cat -- "$p")"; else printf "G\\n"; fi; done\n' }
        local i = 0
        for l in ((r.stdout or ""):gsub("\r", "")):gmatch("([^\n]*)\n") do
            i = i + 1
            local p, kind, target = links[i], l:sub(1, 1), l:sub(2)
            if kind ~= "G" then h[p] = hash.sha256("symlink:" .. target) end
        end
        if i ~= #links then return nil, "unhashable", #links - i end
    end
    return h, n
end

if git{ "rev-parse", "--is-inside-work-tree" }.code ~= 0 then
    blocked("not-a-git-repo", "the checkout this script runs in is not a git work tree, so there is no tracked set to hash",
        "run it from a git checkout of tillandsias")
end

local function lines(h)
    local out_ = {}
    for p, x in pairs(h) do out_[#out_ + 1] = x .. "  " .. p end
    table.sort(out_)
    return out_
end

if mode == "snapshot" then
    local h, n, missing = hash_tracked()
    if not h and n == "unhashable" then
        blocked("unhashable:" .. tostring(missing), tostring(missing) .. " tracked path(s) could not be hashed, so they could be rewritten unseen",
            "find them with: git ls-files -z | xargs -0 git hash-object --no-filters >/dev/null, fix them, then snapshot again")
    elseif not h then
        blocked("snapshot-empty", "git could not list the tracked set, so there is no baseline to verify against",
            "check that git ls-files works here, then snapshot again")
    end
    local l = lines(h)
    if #l < 1 then blocked("snapshot-empty", "the tracked set is empty, so there is no baseline to verify against", "run it from a checkout with tracked files") end
    if #l ~= n then
        blocked("unhashable:" .. (n - #l), "the baseline holds " .. #l .. " of " .. n .. " tracked paths, so the missing ones could be rewritten unseen",
            "restore the missing tracked path(s) (git status names them), then snapshot again")
    end
    -- Through the shell, not fs.write: the gate keeps its baseline in the git dir, which for a worktree is
    -- outside the checkout the fs door is confined to.
    fs.mkdir("target/plan-scratch")
    local tmp = "target/plan-scratch/tracked-baseline-" .. tostring(time.now_ms())
    fs.write(tmp, table.concat(l, "\n") .. "\n")
    local w = proc.run{ argv = { SH, "-s", "--", tmp, state }, stdin = 'cp "$1" "$2"; rc=$?; rm -f "$1"; exit $rc\n', timeout_ms = 60000 }
    local ok_, err = w.code == 0, w.stderr
    if not ok_ then blocked("snapshot-unwritable", "the baseline could not be written to " .. state .. ": " .. tostring(err), "give a writable state path inside the checkout") end
    verdict.emit("ok:tracked-files-unwritten:" .. #l .. " files", 0)
end

-- verify: a missing baseline must not read as a clean tree — the fail-open shape this exists to refuse.
local rd = proc.run{ argv = { SH, "-s", "--", state }, stdin = '[ -s "$1" ] && cat "$1"\n', timeout_ms = 60000 }
local base = rd.code == 0 and rd.stdout or ""
if base == "" then
    blocked("no-snapshot-at:" .. state, "no baseline at " .. state .. ", and a missing baseline must not read as a clean tree",
        "run snapshot " .. state .. " at gate start, then verify the same path")
end
local before = {}
for x, p in base:gsub("\r", ""):gmatch("(%x+)  ([^\n]+)") do before[p] = x end
local now = hash_tracked()
if not now then blocked("verify-unhashable", "the tracked set could not be hashed again", "run git ls-files -s here to see why, then verify again") end
local changed = {}
for p, x in pairs(before) do if now[p] ~= x then changed[#changed + 1] = p end end
table.sort(changed)
if #changed > 0 then
    local msg = { "  why: the gate modified files in the checkout it was measuring.",
        "  Every verdict taken after the write measured different bytes than the tree under test (1063-363b).",
        "  remedy: find the writer from the file list below ((a) or (b)), stop it, restore the files, and run the gate again." }
    for i = 1, math.min(20, #changed) do msg[#msg + 1] = "    " .. changed[i] .. (now[changed[i]] and "" or "  (gone)") end
    for _, l in ipairs{ "  Restore with: git checkout --", "",
        "  THE WRITER IS ONE OF TWO KINDS AND THE FILE LIST TELLS YOU WHICH (1230-26sy: this text used to name only",
        "  the first, and both hosts that hit it on 2026-09-16 were the second).",
        "  (a) SOMETHING BESIDE THE GATE wrote in this checkout while it ran: an agent editing or committing, a second",
        "      land, an editor saving. Likely if the paths are ones you were working on. From gate start, nothing",
        "      tracked changes; a commit is only one way to change the bytes under measurement.",
        "  (b) A FIXTURE OR GATE STEP escaped its temp dir. Likely if the paths are ones you never touched. Check",
        "      three-argument cp, a $TMPDIR that was empty so a relative path resolved into the repo, and any",
        "      'cp $src $dst' where $dst was unset.",
        "  This check cannot tell (a) from (b); it sees only that the bytes moved." } do msg[#msg + 1] = l end
    log.raw(table.concat(msg, "\n"))
    verdict.emit("violation:gate-wrote-tracked-files:" .. #changed, 1)
end
verdict.emit("ok:tracked-files-unwritten:" .. #lines(now) .. " files", 0)
