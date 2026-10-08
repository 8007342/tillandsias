-- @trace order:1528-ekri, order:1063-363b
--
-- check-tracked-files-unwritten.lua — PORTED from
-- check-tracked-files-unwritten.sh, byte for byte on stdout/stderr/exit. The
-- gate must not write into the checkout it is measuring. See the .sh's
-- header (kept in git history) for the 2026-09-05 incident this exists to
-- detect, and why content hashing rather than `git status` is the signal.
--
-- DISCLOSED DEVIATION — WHY proc.run INSTEAD OF fs.read/fs.write FOR THE
-- STATE FILE. build.sh snapshots to `$(git rev-parse --absolute-git-dir)/
-- tillandsias-tracked-baseline`, which is OUTSIDE the repository root for a
-- linked worktree (its git-dir lives under the main checkout's .git/
-- worktrees/<name>, not under the worktree's own tree) — exactly the state
-- this port was developed and tested under. fs.read/fs.write are
-- repo-rooted and `-- @read-env` only widens fs.read/fs.walk, never
-- fs.write, so the state path cannot go through either without narrowing
-- what the .sh always allowed. `test -s`, `cat` and `tee`, run through
-- proc.run exactly like the git invocations below, reproduce the .sh's own
-- unrestricted file I/O rather than regressing it under a sandbox the
-- original script never had.
--
-- THE TRACKED FILES THEMSELVES are hashed with fs.read + hash.sha256
-- (sha2, the same algorithm sha256sum uses) instead of spawning
-- `sha256sum` once per file — every tracked path is inside the repository
-- root by definition, so fs.read's rooting is never in the way, and this
-- avoids a few thousand process spawns the .sh paid for one at a time
-- (`git ls-files -z | xargs -0 sha256sum`). The scratch temp file the .sh
-- used to hold the "now" hash listing for its awk comparison does not exist
-- here either: "now" is a Lua table, so the `mktemp-failed` verdict the .sh
-- could print has no equivalent — there is nothing left for mktemp to do.
--
-- NON-UTF8 PATH NAMES: proc.run's `stdout` is lossily decoded to UTF-8
-- (tillandsias_exec -> String::from_utf8_lossy), where the .sh's NUL-delimited
-- `xargs -0` carried raw bytes. Every tracked path in this repository is
-- plain ASCII (confirmed: `git ls-files | LC_ALL=C grep -P '[^\x00-\x7f]'`
-- finds none), so this is unobservable today; a future non-UTF8 path would
-- be lossily mangled here where the .sh would hash it correctly.
--
-- Usage:   tillandsias-plan script run check-tracked-files-unwritten.lua -- snapshot <state-file>
--          tillandsias-plan script run check-tracked-files-unwritten.lua -- verify   <state-file>
--
-- Grammar (one line on stdout, unchanged legacy):
--   ok:tracked-files-unwritten:<n> files
--   violation:gate-wrote-tracked-files:<n>
--   blocked:tracked-files-unwritten:<reason>

local mode = arg[1] or ""
local state = arg[2] or ""
if mode == "" or state == "" then
    verdict.emit("blocked:tracked-files-unwritten:usage", 2)
end

-- Every tracked path (NUL-delimited, so a path with a space or newline
-- cannot split), hashed with fs.read + hash.sha256 rather than a
-- `sha256sum` subprocess per file.
local function hash_tracked()
    local r = proc.run({ argv = { "git", "ls-files", "-z" } })
    if not r.ok then return nil end
    local out = {}
    for _, p in ipairs(text.split(r.stdout, "\0")) do
        if p ~= "" then
            local ok_r, content = pcall(fs.read, p)
            if ok_r then
                out[p] = hash.sha256(content)
            end
        end
    end
    return out
end

local function count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

if mode == "snapshot" then
    local r = proc.run({ argv = { "git", "rev-parse", "--is-inside-work-tree" } })
    if not r.ok then
        verdict.emit("blocked:tracked-files-unwritten:not-a-git-repo", 2)
    end
    local tracked = hash_tracked() or {}
    -- Judge the ARTEFACT, not a write command's exit status (the .sh's own
    -- rule, 1063-363b's header): write, then re-read what is actually on
    -- disk, exactly like the .sh's `grep -c . "$state"` after the redirect.
    proc.run({ argv = { "tee", state }, stdin = json.encode(tracked) })
    local check = proc.run({ argv = { "cat", state } })
    local ok_c, written = false, nil
    if check.ok then ok_c, written = pcall(json.parse, check.stdout) end
    local n = (ok_c and written and count(written)) or 0
    if n < 1 then
        verdict.emit("blocked:tracked-files-unwritten:snapshot-empty", 2)
    end
    verdict.emit("ok:tracked-files-unwritten:" .. n .. " files", 0)
elseif mode == "verify" then
    local present = proc.run({ argv = { "test", "-s", state } })
    if not present.ok then
        -- A missing baseline must not read as a clean tree — the fail-open
        -- shape this file exists to refuse.
        verdict.emit("blocked:tracked-files-unwritten:no-snapshot-at:" .. state, 2)
    end
    local r = proc.run({ argv = { "cat", state } })
    local ok_parse, before = false, nil
    if r.ok then
        ok_parse, before = pcall(json.parse, r.stdout)
    end
    before = (ok_parse and before) or {}

    local now = hash_tracked() or {}

    -- SAME PATH, DIFFERENT HASH. Only paths present in BOTH snapshots count
    -- — an added or removed path is not "a tracked file that was written".
    local changed = {}
    for p, h in pairs(before) do
        if now[p] ~= nil and now[p] ~= h then
            changed[#changed + 1] = p
        end
    end
    table.sort(changed)

    if #changed > 0 then
        log.raw("  The gate modified files in the checkout it was measuring.")
        log.raw("  Every verdict taken after the write measured different bytes")
        log.raw("  than the tree under test (1063-363b).")
        for i = 1, math.min(#changed, 20) do
            log.raw("    " .. changed[i])
        end
        log.raw("  Restore with: git checkout --")
        log.raw("")
        log.raw("  THE WRITER IS ONE OF TWO KINDS AND THE FILE LIST TELLS")
        log.raw("  YOU WHICH. Order 1230-26sy: this text used to name only")
        log.raw("  the first, and both hosts that hit it on 2026-09-16 were")
        log.raw("  the second — one lost a 40-minute gate hunting fixtures")
        log.raw("  that were innocent.")
        log.raw("")
        log.raw("  (a) SOMETHING BESIDE THE GATE wrote in this checkout while")
        log.raw("      it ran: an agent editing or committing, a second land,")
        log.raw("      an editor saving. Likely if the paths are ones you were")
        log.raw("      working on. 1063-363b is about the BYTES UNDER")
        log.raw("      MEASUREMENT CHANGING — a commit is only one way to do")
        log.raw("      that, and an edit or a staged file does it just as")
        log.raw("      well. From gate start, nothing tracked changes.")
        log.raw("")
        log.raw("  (b) A FIXTURE OR GATE STEP escaped its temp dir. Likely if")
        log.raw("      the paths are ones you never touched. Check")
        log.raw("      three-argument cp, a $TMPDIR that was empty so a")
        log.raw("      relative path resolved into the repo, and any")
        log.raw("      'cp $src $dst' where $dst was unset.")
        log.raw("")
        log.raw("  This check cannot tell (a) from (b) — it sees only that")
        log.raw("  the bytes moved. The file list above is the discriminator.")
        verdict.emit("violation:gate-wrote-tracked-files:" .. #changed, 1)
    end
    verdict.emit("ok:tracked-files-unwritten:" .. count(now) .. " files", 0)
else
    verdict.emit("blocked:tracked-files-unwritten:unknown-mode:" .. mode, 2)
end
