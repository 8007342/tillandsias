-- @trace order:1321-2ixp, order:2350-psb7
-- @env PATH HOME
--
-- test-salvage-preserves-exec-bits.lua — order 1321-2ixp, items 2 and 3. Ported from the
-- .sh of the same name (2350-psb7); same four arms.
--
-- A Windows checkout cannot express the executable bit (core.filemode is false; a NEW file
-- stages 100644), so a fixture handed over by scripts/salvage-dirty-worktree.sh reaches the
-- relaying host with the bit gone. MEASURED: test-windows-host-lane-refusal.sh arrived at
-- 100644, every --check passed for a day, and the v56.9.20.1 release gate refused its
-- `test -x` 45 minutes in. Snapshot time is the last moment anyone knows the bit was meant,
-- so the salvage restores it there.
--
-- HERMETIC: each arm is a throwaway repo; `git update-index --chmod=-x` reproduces what a
-- core.filemode=false checkout produces. The restore block is CUT FROM THE TOOL
-- (`restored=0` .. `done`) and run in a bash child, never restated.
--
--   1 a shebang file staged at 100644 reaches the tree at 100755
--   2 ... and the salvage names it (note:exec-bit-restored:<path>)
--   3 NEGATIVE CONTROL a file with no shebang keeps 100644 and is not named
--   4 the tool still carries the block arms 1-3 ran (else they tested nothing)
--
-- GRAMMAR ok:salvage-exec-bits:4 arms | violation:salvage-exec-bits:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("salvage-exec-bits")
local SH = fixture.posix_shell()
local SALVAGE = "scripts/salvage-dirty-worktree.sh"
if not fs.exists(SALVAGE) then T:refuse("missing", SALVAGE) end
local src = fs.read(SALVAGE)

local blk, on = {}, false
for l in (src .. "\n"):gmatch("([^\n]*)\n") do
    if l == "restored=0" then on = true end
    if on then blk[#blk + 1] = l end
    if on and l == "done" then break end
end
local BLOCK = #blk > 1 and (table.concat(blk, "\n") .. "\n") or ""

-- run(name, file, body, strip): a scaffold repo, the file staged (stripped of +x as a
-- Windows checkout would), then the tool's block over the porcelain paths. Mode and output.
local function run(name, file, body, strip)
    local W = T:scratch(name)
    local r = T:run{ SH, "-s", "--", body, file, strip and "strip" or "", BLOCK, cwd = W.abs, timeout_ms = 60000, stdin = [[
git init -q . && git config user.email s@t && git config user.name s || exit 9
printf 'seed\n' > seed.txt && git add seed.txt && git commit -qm seed || exit 9
printf '%s' "$1" > "$2" && git add -A -- "$2" || exit 9
[ "$3" = strip ] && git update-index --chmod=-x -- "$2"
paths_to_stage=()
while IFS= read -r -d '' _e; do paths_to_stage+=("${_e:3}"); done < <(git status --porcelain=v1 --untracked-files=all -z)
for p in ${paths_to_stage[@]+"${paths_to_stage[@]}"}; do git add -A -- "$p"; done
eval "$4"
echo "mode=$(git ls-files -s -- "$2" | cut -d' ' -f1)"
]] }
    local o = (r.stdout or "") .. (r.stderr or "")
    return o:match("mode=(%d+)") or "none", o
end

local mode, o = run("a", "scripts_test_x.sh", "#!/usr/bin/env bash\necho hi\n", true)
T:arm("1 a shebang file staged at 100644 reaches the tree at 100755", BLOCK ~= "" and mode == "100755", "mode=" .. mode .. " " .. o)
T:arm("2 the salvage names each file it restored, so the change is not silent",
    text.contains("\n" .. o, "\nnote:exec-bit-restored:scripts_test_x.sh\n"), o)

mode, o = run("b", "data.yaml", "key: value\n", false)
T:arm("3 CONTROL a file with no shebang keeps 100644 and is not named as restored",
    BLOCK ~= "" and mode == "100644" and not text.contains(o, "note:exec-bit-restored:"), "mode=" .. mode .. " " .. o)

T:arm("4 salvage-dirty-worktree.sh still carries the restore the arms above ran",
    BLOCK ~= "" and text.contains(src, "note:exec-bit-restored"), "the restore block is gone from the tool: arms 1-3 tested nothing")

T:finish()
