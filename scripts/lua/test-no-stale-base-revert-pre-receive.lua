-- @env PATH HOME
-- @trace spec:git-mirror-service, spec:meta-orchestration, order:1001-i5ux, order:1022-73pk, order:2330-sn77
--
-- test-no-stale-base-revert-pre-receive.lua — the RECEIVING half of the stale-base guard:
-- images/git/pre-receive-hook.sh on a real bare remote in scratch. Ported from the .sh of the
-- same name (2330-sn77). Every scratch push skips the client hook, which is the invocation
-- the client half cannot reach.
--
-- The force shape was already refused by the receive hardening (arm 1 pins it). The gap was
-- the FAST-FORWARD one: a merge whose resolution DROPS the trunk's files is a clean
-- fast-forward, and `git log --name-only` does not show a merge's own changes.
--
--   1 a forced stale-base push is refused
--   2 a fast-forward merge that discards the trunk is refused   3 naming the files
--   4 an ordinary push is accepted       5 a deletion the commit made is accepted
--   6 a new ref (salvage) is never blocked
--
-- Usage: tillandsias-plan script run scripts/lua/test-no-stale-base-revert-pre-receive.lua
-- Verdict: ok:no-stale-base-revert-pre-receive:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("no-stale-base-revert-pre-receive")
local SH = fixture.posix_shell()
local d = T:scratch()
fs.write(d.rel .. "/pre-receive", fs.read("images/git/pre-receive-hook.sh"))
local SCRIPT = [==[
set -u
W=$PWD; R="$W/origin.git"
export HOME="$W/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$W/gitconfig"
mkdir -p "$HOME"; printf '[user]\n\tname = f\n\temail = f@example.invalid\n' >"$W/gitconfig"
git init -q --bare -b main "$R" || exit 90
cp pre-receive "$R/hooks/pre-receive"
# The hook refuses without an executable relay helper; the stub reads stdin as the real one does.
printf '#!/bin/sh\ncat >/dev/null\nexit 0\n' >"$R/hooks/tillandsias-relay-refs"
chmod +x "$R/hooks/pre-receive" "$R/hooks/tillandsias-relay-refs"
# Pinned: an ambient core.hooksPath would silently skip the hook under test (1022-73pk).
git -C "$R" config core.hooksPath "$R/hooks"
git init -q -b main "$W/work" && cd "$W/work" || exit 90
git remote add origin "$R"
tip() { git -C "$R" rev-parse refs/heads/main; }
try() { n=$1; shift; b="$(tip)"; git push --no-verify "$@" >"$W/$n.out" 2>&1; echo $? >"$W/$n.rc"; [ "$b" = "$(tip)" ] && echo same >"$W/$n.tip" || echo moved >"$W/$n.tip"; }
for f in trunk_a trunk_b trunk_c; do echo "$f" >"$f"; done
echo mine >mine.txt; git add -A && git commit -qm base && git push -q --no-verify origin main 2>"$W/setup.err" || exit 91
base="$(git rev-parse HEAD)"
git checkout -q -b stale "$base"; echo work >>mine.txt; git commit -qam "innocent: only touches mine.txt"
git checkout -q main; for f in trunk_d trunk_e; do echo "$f" >"$f"; done
git add -A && git commit -qm "another host's work" && git push -q --no-verify origin main 2>>"$W/setup.err" || exit 92
git checkout -q stale
try force --force origin stale:main
git merge -q --no-commit --no-ff origin/main 2>/dev/null || true
git rm -q --cached trunk_d trunk_e 2>/dev/null || true; rm -f trunk_d trunk_e
git commit -qm "merge origin/main (resolution drops the trunk's files)"
git merge-base --is-ancestor origin/main HEAD || exit 93
try discard origin stale:main
git reset -q --hard origin/main; echo clean >>mine.txt; git commit -qam "ordinary commit on a current base"
try ordinary origin stale:main
git rm -q trunk_a && git commit -qm "delete a file on purpose"
try deletion origin stale:main
git checkout -q -b salvage/test; echo salvaged >salvaged.txt; git add -A; git commit -qm "salvage copy"
try salvage origin salvage/test
exit 0
]==]
local r = T:run{ SH, "-s", cwd = d.abs, stdin = SCRIPT, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 120000 }
local function read(f) return fs.exists(d.rel .. "/" .. f) and fs.read(d.rel .. "/" .. f) or "" end
if r.code ~= 0 then T:refuse("setup-failed", "rc=" .. tostring(r.code) .. " " .. (r.stderr or "") .. read("setup.err")) end
local function got(n) return text.trim(read(n .. ".rc")), read(n .. ".out"), text.trim(read(n .. ".tip")) end
local function why(n) local rc, o, tip = got(n); return "rc=" .. rc .. " tip=" .. tip .. " " .. o end
local function refused(n) local rc, _, tip = got(n); return rc ~= "" and rc ~= "0" and tip == "same" end
local function accepted(n) return got(n) == "0" end

-- The message is asserted: without that rule the deletion guard refuses this push too.
T:arm("1 a forced stale-base push is refused by the fast-forward rule and the ref does not move", refused("force") and text.contains(read("force.out"), "non-fast-forward branch update is disabled"), why("force"))
local _, o = got("discard")
T:arm("2 a fast-forward merge that discards the trunk is refused", refused("discard") and text.contains(o, "blocked:stale-base-revert:"), why("discard"))
T:arm("3 the refusal names the files", text.contains(o, "trunk_d") and text.contains(o, "trunk_e"), why("discard"))
local _, _, tip = got("ordinary")
T:arm("4 an ordinary push on a current base is accepted and moves the ref", accepted("ordinary") and tip == "moved", why("ordinary"))
T:arm("5 a deletion the commit made is accepted", accepted("deletion"), why("deletion"))
T:arm("6 a new remote ref is never blocked", accepted("salvage"), why("salvage"))
T:finish()
