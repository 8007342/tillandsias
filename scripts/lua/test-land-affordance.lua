-- @env PATH HOME
-- @trace order:1247-lwek, order:1247-amcu, spec:ci-release, order:2331-8emp
--
-- test-land-affordance.lua — every refused:land:* of land-on-platform-branch.sh is followed by
-- `  why:` and `  remedy:`, and the remedy works. Ported from the .sh of the same name
-- (2331-8emp). A scratch seed with the script and a stub build.sh as the gate, a bare
-- scratch origin with its own hooks path, and clones that land into it.
--
--   1 dirty-worktree: why/remedy, and committing lands
--   2 trunk-merge-conflict: why/remedy, and merging, resolving and committing lands
--   3 gate-failed: why/remedy, and fixing what the gate named lands
--   4 STATIC every refused:land:* site is followed within three lines by _afford
--
-- Usage: tillandsias-plan script run scripts/lua/test-land-affordance.lua
-- Verdict: ok:land-affordance:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("land-affordance")
local SH = fixture.posix_shell()
local TOOL = fs.read("scripts/land-on-platform-branch.sh"):gsub("\r", "")
local PRE = [==[
set -u
W=$PWD; export HOME="$W/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$W/gitconfig" GIT_TERMINAL_PROMPT=0
mkdir -p "$HOME"; printf '[user]\n\tname = f\n\temail = f@example.invalid\n' >"$W/gitconfig"
git init -q -b linux-next seed && mkdir -p seed/scripts || exit 90
cp tool.sh seed/scripts/land-on-platform-branch.sh
printf '#!/bin/sh\nexit 0\n' >seed/build.sh; chmod +x seed/build.sh; echo base >seed/shared.txt
git -C seed add -A && git -C seed commit -qm base && git -C seed branch windows-next
echo "trunk version" >seed/shared.txt; git -C seed commit -qam "trunk edits shared.txt"
git init -q --bare origin.git && git -C origin.git config core.hooksPath hooks && git -C origin.git symbolic-ref HEAD refs/heads/linux-next
git -C seed remote add origin "$W/origin.git" && git -C seed push -q origin linux-next windows-next || exit 91
git clone -q "$W/origin.git" c && cd c && git config core.hooksPath "$W/c/.git/hooks" && git checkout -q "$1" || exit 92
B=$1
land() { bash scripts/land-on-platform-branch.sh "$B" 2 >"$W/$1.log" 2>&1 </dev/null; echo $? >"$W/$1.rc"; }
]==]
-- the refusal, then the remedy executed, then a second landing that must reach origin.
local POST = "\nland second\n[ \"$(git rev-parse HEAD)\" = \"$(git -C \"$W/origin.git\" rev-parse \"refs/heads/$B\")\" ] && echo yes >\"$W/landed\" || echo no >\"$W/landed\"\n"
local function arm(name, branch, verdict, want_rc, break_it, remedy)
    local d = T:scratch()
    fs.write(d.rel .. "/tool.sh", TOOL)
    local r = T:run{ SH, "-s", "--", branch, cwd = d.abs, stdin = PRE .. break_it .. "\nland first\n" .. remedy .. POST, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 180000 }
    local function read(f) return fs.exists(d.rel .. "/" .. f) and fs.read(d.rel .. "/" .. f):gsub("\r", "") or "" end
    local log, rc = "\n" .. read("first.log"), text.trim(read("first.rc"))
    local at = log:find("\n" .. verdict, 1, true)
    local after = at and log:sub(at + 1) or ""
    T:arm(name .. ": says why and what clears it", (want_rc and rc == want_rc or not want_rc and rc ~= "0" and rc ~= "") and at ~= nil and text.contains(after, "\n  why: ") and text.contains(after, "\n  remedy: "),
        "setup=" .. tostring(r.code) .. " rc=" .. rc .. " " .. log:sub(1, 500) .. (r.stderr or ""))
    T:arm(name .. ": the remedy lands", text.trim(read("second.rc")) == "0" and text.trim(read("landed")) == "yes", "rc=" .. read("second.rc") .. " landed=" .. read("landed") .. read("second.log"):sub(-500))
end
arm("1 dirty-worktree", "linux-next", "refused:land:dirty-worktree", "1", "echo local >local.txt; git add local.txt", "git commit -qm remedy")
arm("2 trunk-merge-conflict", "windows-next", "refused:land:trunk-merge-conflict", "2", 'echo "platform version" >shared.txt; git commit -qam "platform edits shared.txt"',
    'git merge -q origin/linux-next >/dev/null 2>&1; echo resolved >shared.txt; git add shared.txt; git commit -qm resolve')
arm("3 gate-failed", "linux-next", "refused:land:gate-failed", nil, [[printf '#!/bin/sh\necho "violation:fixture:the tree is wrong"\nexit 1\n' >build.sh; git commit -qam "a tree the gate refuses"]],
    [[printf '#!/bin/sh\nexit 0\n' >build.sh; git commit -qam "fix what the gate named"]])
local lines, sites, missing = {}, 0, {}
for l in (TOOL .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = l end
for i, l in ipairs(lines) do
    if text.contains(l, 'echo "refused:land:') then
        sites = sites + 1
        local near = (lines[i + 1] or "") .. (lines[i + 2] or "") .. (lines[i + 3] or "")
        if not text.contains(near, "_afford ") then missing[#missing + 1] = i .. ": " .. l end
    end
end
T:arm("4 every refused:land:* site is followed by an _afford call", #missing == 0 and sites >= 13, "sites=" .. sites .. " " .. table.concat(missing, " | "))
T:finish()
