-- @env PATH HOME
-- @trace spec:meta-orchestration, order:1000-rqmx, order:2328-r8qf
--
-- test-no-stale-base-revert.lua — a forced push from a stale base is refused before it reverts
-- other hosts' files, and the same commit rebased is accepted. Ported from the .sh of the same
-- name (2328-r8qf). EVERY ARM drives a REAL push through the real hook, alone, against a real
-- bare remote in scratch. A plain non-fast-forward push is rejected by git itself and the hook
-- gets an empty ref list, so the case this guard can reach is a FORCED push.
--
--   1 a stale-base force push is refused      2 the refusal names the files it would revert
--   3 --force-with-lease after a FRESH FETCH is refused too: the lease proves only that the
--     remote has not moved since your fetch, so a careful loop refreshes it and reverts
--   4 the SAME commit rebased is accepted     5 a deletion the commit made is accepted
--   6 a new remote ref (the salvage path, 872-c9nd) is never blocked
--
-- Usage: tillandsias-plan script run scripts/lua/test-no-stale-base-revert.lua
-- Verdict: ok:no-stale-base-revert:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("no-stale-base-revert")
local SH, ROOT = fixture.posix_shell(), fixture.repo_root()
local d = T:scratch()
local SCRIPT = [==[
set -u
G=$1; W=$PWD
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$W/gitconfig"
printf '[user]\n\tname = f\n\temail = f@example.invalid\n' >"$W/gitconfig"
git init -q --bare "$W/origin.git" || exit 90
git init -q -b main "$W/work" || exit 90
cd "$W/work" || exit 90
git config core.hooksPath "$W/work/.githooks"
mkdir -p .githooks
printf '#!/usr/bin/env bash\necho ran >>"%s/hook-ran"\nexec bash "%s" "$@"\n' "$W" "$G" >.githooks/pre-push
chmod +x .githooks/pre-push
git remote add origin "$W/origin.git"
for f in trunk_a trunk_b trunk_c; do echo "$f" >"$f"; done
echo mine >mine.txt
git add -A && git commit -qm base && git push -q origin main 2>/dev/null || exit 91
base="$(git rev-parse HEAD)"
git checkout -q -b stale "$base"; echo work >>mine.txt; git commit -qam "innocent: only touches mine.txt"
git checkout -q main; for f in trunk_d trunk_e; do echo "$f" >"$f"; done
git add -A && git commit -qm "another host's work" && git push -q origin main 2>/dev/null || exit 92
try() { n=$1; shift; "$@" >"$W/$n.out" 2>&1; echo $? >"$W/$n.rc"; }
git checkout -q stale
try force git push --force origin stale:main
git fetch -q origin
try lease git push --force-with-lease origin stale:main
git rev-parse origin/main >"$W/remote-after"; git rev-parse main >>"$W/remote-after"
git rebase -q origin/main 2>/dev/null || true
try rebased git push origin stale:main
git checkout -q main && git pull -q --ff-only origin main 2>/dev/null || true
git rm -q trunk_a && git commit -qm "delete a file on purpose"
try deletion git push origin main
git checkout -q -b salvage/test; echo salvaged >salvaged.txt; git add -A; git commit -qm "salvage copy"
try salvage git push origin salvage/test
exit 0
]==]
local r = T:run{ SH, "-s", "--", ROOT .. "/scripts/hooks/pre-push-no-stale-base-revert.sh", cwd = d.abs, stdin = SCRIPT, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 120000 }
if r.code ~= 0 then T:refuse("setup-failed", "rc=" .. tostring(r.code) .. " " .. (r.stderr or "")) end
local function read(f) return fs.exists(d.rel .. "/" .. f) and fs.read(d.rel .. "/" .. f) or "" end
local function got(n) local rc, o = text.trim(read(n .. ".rc")), read(n .. ".out"); return rc, o, "rc=" .. rc .. " " .. o end
local function refused(n) local rc, o = got(n); return rc ~= "" and rc ~= "0" and text.contains("\n" .. o, "\nblocked:stale-base-revert:") end

local _, force, why = got("force")
T:arm("1 a stale-base force push is refused", refused("force"), why)
T:arm("2 the refusal names the files that would be reverted", text.contains(force, "trunk_d") and text.contains(force, "trunk_e"), why)
local _, _, lease = got("lease")
local a, z = read("remote-after"):match("^(%x+)%s+(%x+)")
T:arm("3 --force-with-lease after a fresh fetch is refused too, and the remote did not move", refused("lease") and a ~= nil and a == z, lease .. read("remote-after"))
for _, x in ipairs{ { "4 the SAME commit rebased is accepted", "rebased" }, { "5 a deletion the commit made is accepted", "deletion" },
    { "6 a new remote ref is never blocked", "salvage" } } do
    local rc, _, w = got(x[2])
    T:arm(x[1], rc == "0" and text.contains(read("hook-ran"), "ran"), w)
end
T:finish()
