-- @env PATH
-- @trace order:1064-r8fv, order:2369-8vq3
--
-- test-land-merges-trunk.lua — scripts/land-on-platform-branch.sh merges TRUNK into a platform branch, and
-- manufactures nothing on trunk itself (arm 2, the negative control). A refused push names the relay lane
-- and does not take it. No network and no real gate: a local bare origin, a stub build.sh, a scratch HOME.
-- Ported from the .sh of the same name.
--
-- Usage: tillandsias-plan script run scripts/lua/test-land-merges-trunk.lua
-- Verdict: ok:land-merges-trunk:<n> arms | violation:land-merges-trunk:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("land-merges-trunk")
local SH = fixture.posix_shell()
local SUBJECT = "scripts/land-on-platform-branch.sh"
if not fs.exists(SUBJECT) then T:refuse("subject-missing") end
local src = fs.read(SUBJECT):gsub("\r\n", "\n")

-- The whole scenario in scratch: trunk ahead of windows-next, one unpushed commit, then the land.
local RUN = [[
cd "$1" || exit 96; branch="$2"; reject="$3"
export HOME="$PWD/home"; mkdir -p home
export GIT_AUTHOR_NAME=f GIT_AUTHOR_EMAIL=f@e.invalid GIT_COMMITTER_NAME=f GIT_COMMITTER_EMAIL=f@e.invalid
{
git init -q -b linux-next seed && mkdir -p seed/scripts && cp land.sh seed/scripts/land-on-platform-branch.sh || exit 96
printf '#!/bin/sh\nexit 0\n' > seed/build.sh; chmod +x seed/build.sh; echo base > seed/base.txt
git -C seed add -A && git -C seed commit -qm base && git -C seed branch windows-next
echo moved > seed/trunk-only.txt; git -C seed add -A && git -C seed commit -qm "trunk advances"
git init -q --bare origin && git -C origin config core.hooksPath hooks
git -C seed push -q "$PWD/origin" linux-next windows-next
git clone -q "$PWD/origin" w && git -C w checkout -q "$branch" && echo work > w/work.txt
git -C w add -A && git -C w commit -qm work || exit 96
if [ "$reject" = reject ]; then printf '#!/bin/sh\necho "refused by fixture" >&2\nexit 1\n' > origin/hooks/pre-receive; chmod +x origin/hooks/pre-receive; fi
} >&2
before="$(git -C w rev-list --merges --count HEAD)"
trunk="$(git -C origin rev-parse linux-next)"
(cd w && "$BASH" scripts/land-on-platform-branch.sh "$branch" 2) > land.log 2>&1 </dev/null
echo "rc=$?"
git -C w merge-base --is-ancestor "$trunk" HEAD && echo contained
git -C origin merge-base --is-ancestor "$trunk" "$branch" && echo pushed
echo "merges=$(( $(git -C w rev-list --merges --count HEAD) - before ))"
grep -q "merging origin/linux-next" land.log && echo announced
grep -q "refs/heads/work/" land.log && echo relay-named
[ -z "$(git -C origin for-each-ref refs/heads/work)" ] || echo relay-taken
exit 0
]]
local function land(tag, branch, body, reject)
    local d = T:scratch(tag)
    fs.write(d.rel .. "/land.sh", body or src)
    local r = proc.run{ argv = { SH, "-s", "--", d.abs, branch, reject and "reject" or "accept" }, stdin = RUN, timeout_ms = 240000,
        env = { PATH = env.get("PATH") }, env_unset = { "TILLANDSIAS_*", "GIT_*" } }
    if r.code ~= 0 then T:refuse("scenario-failed", tostring(r.code) .. " " .. tostring(r.stderr)) end
    local o = "\n" .. r.stdout:gsub("\r", "")
    return function(line) return o:find("\n" .. line .. "\n", 1, true) ~= nil end,
        o:gsub("\n", " ") .. " | " .. fs.read(d.rel .. "/land.log"):sub(-300)
end

local has, got = land("platform", "windows-next")
T:arm("1 a platform land succeeds", has("rc=0"), got)
T:arm("1 and contains trunk, on the remote too", has("contained") and has("pushed"), got)
has, got = land("trunk", "linux-next")
T:arm("2 CONTROL on trunk no merge is manufactured or announced", has("rc=0") and has("merges=0") and not has("announced"), got)
has, got = land("reject", "windows-next", nil, true)
T:arm("3 a refused push is refused, not claimed", has("rc=6"), got)
T:arm("3 it names the relay lane and does not take it", has("relay-named") and not has("relay-taken"), got)

-- MUTATION: a tool that believes its trunk is the branch merges nothing.
local a, b = src:find('TRUNK="[^"\n]*"')
if not a then T:refuse("mutation-anchor-missing", "TRUNK=") end
has, got = land("m-notrunk", "windows-next", src:sub(1, a - 1) .. 'TRUNK="$1"' .. src:sub(b + 1))
T:arm("4 MUTATION a land that merges only its own branch fails arm 1", not has("contained") and not has("pushed"), got)

T:finish()
