-- @trace order:887-bz88, order:889-8tcb, order:1135-z8gn, order:2197-hgit, order:2380-ds8v
--
-- test-mode-only-regression-887-bz88.lua — a MODE-ONLY regression must not reach the trunk.
-- On 2026-08-25 check-credential-channel.sh went 100755 to 100644 in a pushed commit: the
-- exec-bit guard read only the index, before `git add`, and the gate stamp hashed content
-- and never the mode. Both halves are asserted over copies in a scratch repository; only
-- arm 6 reads the real checkout, on purpose. Ported from the .sh (2380-ds8v).
--
-- Arms that must CREATE a worktree-only regression run only where git trusts the mode bit:
-- core.fileMode=false is git's own declaration that it cannot (NTFS, drvfs), and they are a
-- named skip there.
--
-- Verdict: ok:mode-only-regression-fixture:all | violation:mode-only-regression-fixture:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("mode-only-regression-fixture")
local ROOT = fixture.repo_root()
local SH = fixture.posix_shell()
local UNSET = { "TILLANDSIAS_*", "GIT_*", "CARGO_TARGET_DIR" }
local GUARD, STAMP, VICTIM = "scripts/check-script-exec-bits.sh", "scripts/gate-stamp.sh", "scripts/check-credential-channel.sh"
local W = T:git_repo("repo")
local function git(...)
    local a = { "git", "-C", W.abs, ... }
    a.env_unset = UNSET
    return T:must(a)
end
fs.mkdir(W.rel .. "/scripts/lib")
for _, f in ipairs{ GUARD, STAMP, VICTIM, "scripts/lib/exec-bits-filter.awk" } do fs.write(W.rel .. "/" .. f, fs.read(f)) end
fs.write(W.rel .. "/scripts/caller.sh", "#!/usr/bin/env bash\nscripts/check-credential-channel.sh\n")
git("add", "-A")
-- The index carries the bit; the worktree matches it where the filesystem can.
for _, f in ipairs{ GUARD, STAMP, VICTIM, "scripts/caller.sh" } do
    T:must{ "chmod", "+x", W.abs .. "/" .. f }
    git("update-index", "--chmod=+x", f)
end
git("commit", "-qm", "scratch")
local mode = text.trim(T:run{ "git", "-C", W.abs, "config", "--get", "core.fileMode", env_unset = UNSET }.stdout or "")
local modes = mode:lower() ~= "false"
local function chmod(m) T:must{ "chmod", m, W.abs .. "/" .. VICTIM } end
local function guard(script)
    local r = T:run{ SH, script or (W.abs .. "/" .. GUARD), cwd = W.abs, env_unset = UNSET }
    return text.trim(r.stdout or ""), r.stderr or "", r.code
end
local function stamp() return text.trim(T:run{ SH, W.abs .. "/" .. STAMP, "compute", cwd = W.abs, env_unset = UNSET }.stdout or "") end
local function clean(o) return o:find("^ok:script%-exec%-bits:") ~= nil end

local o, err, rc = guard()
T:arm("1 NEGATIVE a clean tree passes the exec-bit guard", clean(o), o .. err)
local before = stamp()
chmod("-x"); local bare = stamp(); chmod("+x")
-- update-index writes the index directly: with core.fileMode=false a chmod and add records
-- nothing, and the arm would fail for a reason that is not the stamp's.
git("update-index", "--chmod=-x", VICTIM); local staged = stamp()
git("update-index", "--chmod=+x", VICTIM); local after = stamp()
T:arm("2 an INDEX mode change moves the gate stamp", before ~= "" and staged ~= "" and before ~= staged, before .. " / " .. staged)
T:arm("2 restoring the bit restores the stamp", before ~= "" and before == after, before .. " / " .. after)
T:arm("2 an unstaged chmod does not move it: the bit is index-sourced", before ~= "" and before == bare, before .. " / " .. bare)
T:arm("2 gate-stamp.sh does not read the worktree bit", not fs.read(STAMP):find('if [[ -x "$absolute" ]]; then execbits', 1, true), "the worktree test is back")

if modes then
    chmod("-x")
    local idx = (T:must{ "git", "-C", W.abs, "ls-files", "-s", "--", VICTIM, env_unset = UNSET }.stdout or ""):match("^%d+")
    o, err, rc = guard()
    chmod("+x")
    T:arm("3 a worktree-only chmod -x is refused before staging", idx == "100755" and o:find("^violation:script%-not%-executable:") and rc ~= 0, tostring(idx) .. " " .. o)
    T:arm("3 the remedy names chmod +x", err:find("chmod +x", 1, true), err)
    T:arm("3 and not the index remedy, which would stage the broken mode", not err:find("update-index --chmod", 1, true), err)
else
    o, err = guard()
    T:arm("3 core.fileMode=false: the guard's worktree arm is inert and passes", clean(o), o .. err)
    out.line("skip: arms 3 and 5 — core.fileMode=false, a worktree-only regression cannot exist here")
end
fs.write(W.rel .. "/scripts/.887-fixture-data.tmp", "just data, no shebang\n")
o, err = guard()
T:run{ "find", W.abs .. "/scripts/.887-fixture-data.tmp", "-delete" }
T:arm("4 NEGATIVE a shebang-less non-executable file is not condemned", clean(o), o .. err)
if modes then
    -- The index-only guard: the 887 block out, the worktree candidate test off, 100644 only.
    local keep, skip, m1, m2 = {}, false, 0, 0
    for _, l in ipairs(text.lines(fs.read(GUARD))) do
        if l:find("^# ORDER 887%-bz88 — READING ONLY THE INDEX") then skip = true end
        if skip and l:find("^candidates=%(%)") then skip = false end
        if not skip then
            if l:find('^    if %[ "%$mode" != "100644" %]; then') then l = "    if false; then"; m1 = m1 + 1 end
            keep[#keep + 1] = l
            if l == '    [ -f "$path" ] || continue' then keep[#keep + 1] = '    [ "$mode" = "100644" ] || continue'; m2 = m2 + 1 end
        end
    end
    fs.write(W.rel .. "/pre.sh", table.concat(keep, "\n") .. "\n")
    chmod("-x"); o, err = guard(W.abs .. "/pre.sh"); chmod("+x")
    -- A mutation that did not apply looks like teeth (1135-z8gn): it must have applied.
    T:arm("5 MUTATION the index-only guard passes the incident tree", m2 > 0 and clean(o), m1 .. " " .. m2 .. " " .. o .. err)
end
local real = (T:must{ "git", "-C", ROOT, "ls-files", "-s", "--", VICTIM, env_unset = { "GIT_*" } }.stdout or ""):match("^%d+")
T:arm("6 the committed check-credential-channel.sh is 100755", real == "100755", real)
T:finish({ ok = function() return "ok:mode-only-regression-fixture:all" end })
