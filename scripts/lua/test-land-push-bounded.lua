-- @env PATH
-- @trace order:1131-iax2, order:2369-8vq3
--
-- test-land-push-bounded.lua — a push that blocks forever is a NAMED refusal within a bound, not silence
-- and a success-shaped exit (macneo, 2026-09-11: 2362 s and 2360 s on a locked keychain). A fake git
-- whose push blocks; every other subcommand is the real one. Ported from the .sh of the same name.
--
-- Usage: tillandsias-plan script run scripts/lua/test-land-push-bounded.lua
-- Verdict: ok:land-push-bounded:<n> arms | violation:land-push-bounded:<n>-failed | skip:...:no-timeout

local fixture = require "common.fixture"
local T = fixture.new("land-push-bounded")
local SH = fixture.posix_shell()
local SUBJECT = "scripts/land-on-platform-branch.sh"
if not fs.exists(SUBJECT) then T:refuse("subject-missing") end
local src = fs.read(SUBJECT):gsub("\r\n", "\n")

-- The fake leaves the scratch before it sleeps, and becomes the sleep, so the bound kills it and no
-- cwd holds the scratch. Exit 95: no bounder on this host. The sentinel proves the fake was reached.
local RUN = [[
cd "$1" || exit 96; limit="$2"; W="$PWD"
export HOME="$W/home"; mkdir -p home bin
export GIT_AUTHOR_NAME=f GIT_AUTHOR_EMAIL=f@e.invalid GIT_COMMITTER_NAME=f GIT_COMMITTER_EMAIL=f@e.invalid
bounder="$(command -v timeout || command -v gtimeout)" || exit 95
real="$(command -v git)"
{
git init -q --bare origin.git
git init -q -b linux-next repo && mkdir -p repo/scripts && cp land.sh repo/scripts/land-on-platform-branch.sh || exit 96
printf '#!/usr/bin/env bash\nexit 0\n' > repo/build.sh; chmod +x repo/build.sh
git -C repo remote add origin "$W/origin.git"
git -C repo add -A && git -C repo commit -qm seed && git -C repo push -q origin linux-next
git -C repo commit -q --allow-empty -m work || exit 96
} >&2
printf '#!/usr/bin/env bash\nfor a in "$@"; do if [ "$a" = push ]; then : > "%s/reached"; cd /; exec sleep 90; fi; done\nexec "%s" "$@"\n' "$W" "$real" > bin/git
chmod +x bin/git
cd repo || exit 96
PATH="$W/bin:$PATH" TILLANDSIAS_PUSH_TIMEOUT=3 TILLANDSIAS_SKIP_VERSION_BUMP=1 "$bounder" "$limit" "$BASH" scripts/land-on-platform-branch.sh linux-next 1 > ../land.log 2>&1 </dev/null
echo "rc=$?"
exit 0
]]
local function land(tag, body, limit)
    local d = T:scratch(tag)
    fs.write(d.rel .. "/land.sh", body)
    local r = proc.run{ argv = { SH, "-s", "--", d.abs, tostring(limit) }, stdin = RUN, timeout_ms = 200000,
        env = { PATH = env.get("PATH") }, env_unset = { "TILLANDSIAS_*", "GIT_*" } }
    if r.code == 95 then T:skip("no-timeout") end
    if r.code ~= 0 then T:refuse("scenario-failed", tostring(r.code) .. " " .. tostring(r.stderr)) end
    return tonumber(r.stdout:match("rc=(%d+)")), fs.read(d.rel .. "/land.log"), fs.exists(d.rel .. "/reached")
end

local rc, o, reached = land("real", src, 120)
T:arm("0 POSITIVE CONTROL the blocked push was reached", reached, o:sub(-300))
T:arm("1 it is refused by name, carrying the bound and not a varying elapsed", o:find("refused:land:push-emitted-nothing:3\n", 1, true) ~= nil, o:sub(-400))
T:arm("1 with exit 7, its own code", rc == 7, rc)
T:arm("1 naming the first suspect and how to raise the bound", text.contains(o, "credential helper") and text.contains(o, "TILLANDSIAS_PUSH_TIMEOUT=<seconds>"), o:sub(-400))

-- MUTATION: the pre-fix push, unbounded, hangs until it is killed (124).
local a = src:find("\n[^\n]*# ORDER 1131%-iax2: BOUND THE PUSH%.")
local b = a and select(2, src:find("\n[^\n]*# END ORDER 1131%-iax2 push bound[^\n]*", a))
if not b then T:refuse("mutation-anchor-missing") end
rc, o, reached = land("m-unbounded", src:sub(1, a) .. '    git push origin "$BRANCH" > "$_plog" 2>&1\n    rc=$?' .. src:sub(b + 1), 20)
T:arm("2 MUTATION an unbounded push hangs until killed and says nothing", reached and rc == 124
    and not text.contains(o, "push-emitted-nothing"), "rc=" .. tostring(rc) .. " " .. o:sub(-300))

T:finish()
