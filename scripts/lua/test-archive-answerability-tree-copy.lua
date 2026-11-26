-- @trace order:2187-9cws, order:1392-6tbs, order:964-js34
--
-- test-archive-answerability-tree-copy.lua — the answerability tree copy
-- skips an IGNORED symlink whose target does not exist (a nix `result`), on
-- both copy paths, and still copies a tracked symlink.
--
-- The block between # BEGIN-TREE-COPY and # END-TREE-COPY in
-- scripts/check-archive-answerability.sh is cut and driven against a scratch
-- git repo under target/plan-scratch. GNU tar and cp recreate a dangling link
-- happily, so the red is observed as PRESENCE, host-independently: before
-- 2187-9cws the copy carried `result`; on MSYS that is where tar died.
--
-- Arms: premise (cut found, scratch repo shaped), CP (fast path), TAR (cp
-- masked so the probe fails), and MUTANT (the prune loop removed: the link
-- is copied again, so the arms are not vacuous).

local SRC = "scripts/check-archive-answerability.sh"
local pass, fail = 0, 0
local function ok(m) log.raw("ok:   " .. m); pass = pass + 1 end
local function bad(m) log.raw("FAIL: " .. m); fail = fail + 1 end
local function sh(argv) return proc.run({ argv = argv, timeout_ms = 60000 }) end

local pw = sh({ "pwd" })
local ROOT = text.trim(pw.stdout)
local rel = "target/plan-scratch/aatc-" .. math.floor(time.now_ms())
local S = ROOT .. "/" .. rel
sh({ "mkdir", "-p", S .. "/repo/plan" })

local body = fs.read(SRC)
local cut = body:match("\n(# BEGIN%-TREE%-COPY.-\n# END%-TREE%-COPY)\n")
if not cut then
    verdict.emit("violation:archive-answerability-tree-copy:no-cut-markers", 1)
end
local LOOP_PAT = "\nwhile IFS= read %-r %-d '' _aa_ign; do\n.-\ndone < <%(git [^\n]*\n"
local mutant, nsub = cut:gsub(LOOP_PAT, "\n")

-- Scratch repo: a tracked file, a tracked valid symlink, an ignored dangling one.
local R = S .. "/repo"
fs.write(rel .. "/repo/.gitignore", "/result\n")
fs.write(rel .. "/repo/plan/index.yaml", "packets: []\n")
sh({ "git", "-C", R, "init", "-q" })
sh({ "ln", "-s", "plan/index.yaml", R .. "/tracked-link" })
sh({ "ln", "-s", "/nonexistent/nix/store/aatc-tillandsias-0.0.0", R .. "/result" })
sh({ "git", "-C", R, "add", ".gitignore", "plan/index.yaml", "tracked-link" })
local ign = sh({ "git", "-C", R, "ls-files", "-o", "-i", "--exclude-standard", "--directory" })
if nsub == 1 and ign.stdout:find("result", 1, true) and not ign.stdout:find("tracked-link", 1, true) then
    ok("premise: copy block cut, prune loop found once, result is ignored and dangling")
else
    bad("premise: nsub=" .. nsub .. " ignored=[" .. text.trim(ign.stdout) .. "]")
end

-- drive <name> <block> <mask_cp> -> tree path, rc
local function drive(name, block, mask_cp)
    local T, L = S .. "/" .. name .. "/tree", S .. "/" .. name .. "/log"
    sh({ "mkdir", "-p", T, L })
    local pre = "set -uo pipefail\nREPO_ROOT='" .. R .. "'\nWORK='" .. S .. "/" .. name ..
        "'\nTREE='" .. T .. "'\nLOG='" .. L .. "'\nNAME=archive-answerability\nKEEP=0\n"
    if mask_cp then pre = pre .. "cp() { return 1; }\n" end
    fs.write(rel .. "/" .. name .. ".sh", pre .. block .. "\necho copy-block-completed\n")
    local r = proc.run({ argv = { "bash", S .. "/" .. name .. ".sh" }, timeout_ms = 60000 })
    return T, r
end
local function present(p) return sh({ "test", "-L", p }).ok end

for _, arm in ipairs({ { "cp", false }, { "tar", true } }) do
    local T, r = drive(arm[1], cut, arm[2])
    local done = r.stdout:find("copy-block-completed", 1, true)
    if done and not present(T .. "/result") and present(T .. "/tracked-link")
        and sh({ "test", "-f", T .. "/plan/index.yaml" }).ok then
        ok(arm[1] .. ": the ignored dangling result is skipped; the tracked link and the ledger are copied")
    else
        bad(arm[1] .. ": completed=" .. tostring(done ~= nil) .. " result=" .. tostring(present(T .. "/result")) ..
            " tracked-link=" .. tostring(present(T .. "/tracked-link")) .. " out=" .. r.stdout .. r.stderr)
    end
end

local MT = drive("mutant", mutant, false)
if present(MT .. "/result") then
    ok("mutant: without the prune loop the dangling result is copied again (the arms are not vacuous)")
else
    bad("mutant: the link was skipped without the prune loop, so the arms prove nothing")
end

-- ORDER 2390-kivc. The budget counted .git's LOOSE objects: #1599 was evicted at
-- 1049356 KB against 1048576 KB on a host whose .git was 851 MB, 532 MB of it loose,
-- whatever the change. A scratch repo with ~3 MB of loose objects and a 2048 KB
-- budget (lowered in the cut, never in the script) is that host in miniature: the
-- copy must complete on both paths, read the live objects through an alternate, and
-- leave the live object store as it was.
local SHB = require("common.fixture").posix_shell()
local B = S .. "/loose"
sh({ "mkdir", "-p", B .. "/plan" })
fs.write(rel .. "/loose/plan/index.yaml", "packets: []\n")
sh({ "git", "-C", B, "init", "-q" })
local mk = proc.run({ argv = { SHB, "-s", "--", B }, timeout_ms = 60000, stdin =
    'cd "$1" || exit 9\nfor i in 1 2 3; do head -c 1048576 /dev/urandom > blob$i; git hash-object -w blob$i; rm -f blob$i; done\n' })
local oid = (mk.stdout or ""):match("(%x+)\n?$") or ""
local function objects_kb()
    local r = proc.run({ argv = { "du", "-sk", B .. "/.git/objects" }, timeout_ms = 30000 })
    return tonumber((r.stdout or ""):match("^(%d+)")) or 0
end
local live_kb = objects_kb()
local small, nb = cut:gsub("\nBUDGET_KB=%$%(%( 1024 %* 1024 %)%)", "\nBUDGET_KB=2048")
if nb == 1 and live_kb > 2048 and #oid >= 40 then
    ok("premise: the budget line is cut once, and the scratch .git holds " .. live_kb .. " KB of loose objects over a 2048 KB budget")
else
    bad("premise: budget lines=" .. nb .. " loose=" .. live_kb .. " KB oid=[" .. oid .. "]")
end
local R0 = R
R = B
for _, arm in ipairs({ { "loose-cp", false }, { "loose-tar", true } }) do
    local T, r = drive(arm[1], small, arm[2])
    local done = r.stdout:find("copy-block-completed", 1, true)
    local read = proc.run({ argv = { "git", "-C", T, "cat-file", "-e", oid }, timeout_ms = 30000 })
    local copied = tonumber((proc.run({ argv = { "du", "-sk", T .. "/.git/objects" }, timeout_ms = 30000 }).stdout or ""):match("^(%d+)")) or -1
    if done and read.code == 0 and objects_kb() == live_kb and copied >= 0 and copied < 256 then
        ok(arm[1] .. ": loose objects over the budget do not refuse the copy; the copy reads them through the alternate (" .. copied .. " KB of its own) and the live store is unchanged")
    else
        bad(arm[1] .. ": completed=" .. tostring(done ~= nil) .. " readable=" .. tostring(read.code == 0) ..
            " live=" .. live_kb .. "->" .. objects_kb() .. " KB copied=" .. copied .. " KB out=" .. (r.stdout .. r.stderr):sub(1, 300))
    end
end
R = R0

sh({ "find", S, "-delete" })
if fail > 0 then
    verdict.emit("violation:archive-answerability-tree-copy:" .. pass .. "/" .. (pass + fail), 1)
end
verdict.emit("ok:archive-answerability-tree-copy:" .. pass .. " arms", 0)
