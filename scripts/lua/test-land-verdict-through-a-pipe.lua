-- @env PATH
-- @trace order:1137-da83, order:1033-iycs, order:2369-8vq3
--
-- test-land-verdict-through-a-pipe.lua — what a caller sees of a refused land read through a pipe. The
-- tool is right (arm D); `land | tail` reports tail's 0 and captures no refusal at all, because the
-- verdict goes to stderr. Three false claims in one hour came from that reading. The pipelines are the
-- subject, so they run in the shell. Ported from the .sh of the same name.
--
-- Usage: tillandsias-plan script run scripts/lua/test-land-verdict-through-a-pipe.lua
-- Verdict: ok:land-verdict-pipe-fixture:<n> arms | violation:land-verdict-pipe-fixture:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("land-verdict-pipe-fixture")
local SH = fixture.posix_shell()
local SUBJECT = "scripts/land-on-platform-branch.sh"
if not fs.exists(SUBJECT) then T:refuse("subject-missing") end
local src = fs.read(SUBJECT):gsub("\r\n", "\n")

-- No pipefail in this shell: it is one of the remedies (arm F), not the situation. PIPESTATUS is
-- snapshotted whole, on the next line: any command between, even an assignment, resets it.
local RUN = [[
cd "$1" || exit 96
export HOME="$PWD/home"; mkdir -p home
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@e.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@e.invalid
{
git init -q --bare origin.git && git init -q -b windows-next w && mkdir -p w/scripts && cp land.sh w/scripts/land-on-platform-branch.sh || exit 96
git -C w remote add origin "$PWD/origin.git"
printf '#!/usr/bin/env bash\necho "violation:stub-gate-refuses:1"\nexit 1\n' > w/build.sh; chmod +x w/build.sh
git -C w add -A && git -C w commit -qm base
git -C w push -q origin windows-next windows-next:linux-next && git -C w commit -q --allow-empty -m unpushed || exit 96
} >&2
cd w || exit 96
L=scripts/land-on-platform-branch.sh
"$BASH" $L windows-next 1 >/dev/null 2>../d.err </dev/null
echo "D=$?"
"$BASH" $L windows-next 1 2>/dev/null </dev/null | tail -3 > ../a.out
ps=("${PIPESTATUS[@]}")
echo "A=${ps[1]} B=${ps[0]}"
"$BASH" $L windows-next 1 2>&1 </dev/null | tail -25 > ../c.out
echo "C=$?"
set -o pipefail
"$BASH" $L windows-next 1 2>/dev/null </dev/null | tail -3 >/dev/null
echo "F=$?"
exit 0
]]
local function land(tag, body)
    local d = T:scratch(tag)
    fs.write(d.rel .. "/land.sh", body)
    local r = proc.run{ argv = { SH, "-s", "--", d.abs }, stdin = RUN, timeout_ms = 240000,
        env = { PATH = env.get("PATH") }, env_unset = { "TILLANDSIAS_*", "GIT_*" } }
    if r.code ~= 0 then T:refuse("scenario-failed", tostring(r.code) .. " " .. tostring(r.stderr)) end
    local x = {}
    for k, v in r.stdout:gmatch("(%u)=(%d+)") do x[k] = tonumber(v) end
    for _, f in ipairs{ "d.err", "a.out", "c.out" } do x[f] = fs.read(d.rel .. "/" .. f) end
    return x
end

local REFUSAL = "refused:land:gate-failed"
local x = land("real", src)
T:arm("D unpiped, a refused gate exits 3", x.D == 3, x.D)
T:arm("D and is named on stderr", text.contains(x["d.err"], REFUSAL), x["d.err"])
T:arm("E with the gate's first failing line", text.contains(x["d.err"], "violation:stub-gate-refuses:1"), x["d.err"])
T:arm("A piped, the status is tail's 0", x.A == 0, x.A)
T:arm("A and what was captured holds no refusal", not text.contains(x["a.out"], "refused:land"), x["a.out"])
T:arm("B the same pipeline's PIPESTATUS recovers the 3", x.B == 3, x.B)
T:arm("C with 2>&1 the refusal is captured and the status is still 0", text.contains(x["c.out"], REFUSAL) and x.C == 0, x.C)
T:arm("F pipefail propagates the 3", x.F == 3, x.F)

-- MUTATION: a land whose refusal goes to stdout makes arm A's claim false; arm D and A must notice.
local n
local mutated
mutated, n = src:gsub('("refused:land:gate%-failed[^\n]*) >&2', "%1")
if n == 0 then T:refuse("mutation-anchor-missing") end
x = land("m-stdout", mutated)
T:arm("G MUTATION a refusal printed to stdout fails arm D", not text.contains(x["d.err"], REFUSAL), x["d.err"])

T:finish()
