-- @trace spec:git-mirror-service, order:318, order:369, order:2342-9f4k
--
-- test-git-mirror-relay-verified-ack.lua — offline: a configured upstream failure
-- rejects the forge push, and successful and multi-ref transactions converge
-- atomically. Drives the real images/git hooks in scratch repositories. Ported
-- from the .sh (2342-9f4k).
--
--   1 no Vault credential: the push is rejected, names the durable-relay rejection,
--     and the mirror ref does not move
--   2 a relayable push reports "Relay verified" and mirror and upstream converge
--   3 one rejected member leaves both repositories without any of the refs
--   4 (369) a stale push is rejected, the mirror fast-forwards from upstream, a
--     locally stranded head survives, and fetch, rebase, retry converges
--
-- Hermetic git config: a forge exports GIT_CONFIG_GLOBAL with core.hooksPath, which
-- silently disables every fixture repository's hooks, so both outer scopes are
-- fixture-owned empty files.
--
-- Verdict: ok:git-mirror-relay-verified-ack:<n> arms | violation:git-mirror-relay-verified-ack:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("git-mirror-relay-verified-ack")
local ROOT = fixture.repo_root()
local W = T:scratch()
local UP, MIRROR, CLIENT, SCOUT = W.abs .. "/upstream.git", W.abs .. "/mirror.git", W.abs .. "/client", W.abs .. "/scout"
fs.mkdir(W.rel .. "/home")
fs.write(W.rel .. "/gitconfig", "")
local ENV = { HOME = W.abs .. "/home", GIT_CONFIG_NOSYSTEM = "1", GIT_CONFIG_GLOBAL = W.abs .. "/gitconfig",
    GIT_AUTHOR_NAME = "fixture", GIT_AUTHOR_EMAIL = "fixture@example.invalid",
    GIT_COMMITTER_NAME = "fixture", GIT_COMMITTER_EMAIL = "fixture@example.invalid", GIT_TERMINAL_PROMPT = "0" }
local function argv(a) a.env, a.env_unset, a.timeout_ms = ENV, { "TILLANDSIAS_*" }, 60000; return a end
local function try(dir, ...) local r = T:run(argv{ "git", "-C", dir, ... }); return r.code, (r.stdout or "") .. (r.stderr or "") end
local function git(dir, ...) return (text.trim(T:must(argv{ "git", "-C", dir, ... }).stdout or "")) end
local function ref(dir, name) local r = T:run(argv{ "git", "-C", dir, "rev-parse", "--verify", "--quiet", "refs/heads/" .. name }); return r.code == 0 and text.trim(r.stdout or "") or nil end
local function has(s, w) return s:find(w, 1, true) ~= nil end

T:must(argv{ "git", "init", "-q", "--bare", UP })
T:must(argv{ "git", "init", "-q", "--bare", MIRROR })
T:must(argv{ "git", "init", "-q", CLIENT })
git(CLIENT, "config", "core.hooksPath", "")
git(CLIENT, "remote", "add", "mirror", MIRROR)
git(MIRROR, "config", "core.hooksPath", MIRROR .. "/hooks")
for name, from in pairs({ ["pre-receive"] = "pre-receive-hook.sh", ["post-receive"] = "post-receive-hook.sh", ["tillandsias-relay-refs"] = "relay-refs.sh" }) do
    T:must{ "cp", ROOT .. "/images/git/" .. from, MIRROR .. "/hooks/" .. name }
    T:must{ "chmod", "+x", MIRROR .. "/hooks/" .. name }
end
fs.write(W.rel .. "/client/file", "base\n")
git(CLIENT, "add", "file"); git(CLIENT, "commit", "-qm", "base")

-- 1
git(MIRROR, "remote", "add", "origin", "https://github.example.invalid/org/repo.git")
local c, o = try(CLIENT, "push", "mirror", "HEAD:refs/heads/main")
T:arm("1 a push with no upstream credential is rejected", c ~= 0, o)
T:arm("1 the rejection names the durable relay", has(o, "configured upstream did not durably accept"), o)
T:arm("1 the rejected push moved no mirror ref", ref(MIRROR, "main") == nil, tostring(ref(MIRROR, "main")))

-- A local transport inherits receive-pack's quarantine variables; ext sanitizes only
-- the upstream receiver, as an HTTPS or SSH process boundary would.
git(MIRROR, "remote", "set-url", "origin",
    "ext::env -u GIT_QUARANTINE_PATH -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES %S " .. UP)
ENV.GIT_ALLOW_PROTOCOL = "ext:file"
-- 2
c, o = try(CLIENT, "push", "mirror", "HEAD:refs/heads/main")
T:arm("2 a relayable push succeeds and reports Relay verified", c == 0 and has(o, "Relay verified"), "rc=" .. tostring(c) .. " " .. o)
T:arm("2 mirror and upstream converge", ref(MIRROR, "main") ~= nil and ref(MIRROR, "main") == ref(UP, "main"), tostring(ref(MIRROR, "main")) .. " vs " .. tostring(ref(UP, "main")))
c, o = try(UP, "fsck", "--full", "--strict")
T:arm("2 the upstream passes a strict fsck", c == 0, o)

-- 3
fs.write(W.rel .. "/upstream.git/hooks/pre-receive", '#!/bin/sh\nwhile read -r old new ref; do\n    [ "$ref" != "refs/heads/rejected" ] || exit 1\ndone\nexit 0\n')
T:must{ "chmod", "+x", UP .. "/hooks/pre-receive" }
git(CLIENT, "branch", "accepted"); git(CLIENT, "branch", "rejected")
c, o = try(CLIENT, "push", "mirror", "accepted", "rejected")
T:arm("3 a multi-ref push with one rejected member is rejected", c ~= 0, o)
local partial = {}
for _, n in ipairs({ "accepted", "rejected" }) do
    if ref(UP, n) then partial[#partial + 1] = "upstream " .. n end
    if ref(MIRROR, n) then partial[#partial + 1] = "mirror " .. n end
end
T:arm("3 neither repository holds any of the refs", #partial == 0, table.concat(partial, ", "))
local relay = fs.read("images/git/relay-refs.sh")
T:arm("3 the relay is an atomic push of explicit, quoted refspecs", has(relay, 'git push --atomic "$PUSH_URL" "$@"')
    and not has(relay, "git push --mirror") and not has(relay, "git push --all"), "relay-refs.sh push shape")

-- 4
fs.write(W.rel .. "/upstream.git/hooks/pre-receive", "#!/bin/sh\nexit 0\n")
T:must(argv{ "git", "clone", "-q", "-b", "main", UP, SCOUT })
git(SCOUT, "config", "core.hooksPath", "")
fs.write(W.rel .. "/scout/file", "upstream-advance\n")
git(SCOUT, "commit", "-qam", "upstream-advance"); git(SCOUT, "push", "-q", "origin", "HEAD:refs/heads/main")
local new = ref(UP, "main")
T:arm("4 CONTROL upstream is ahead of the mirror", new ~= nil and new ~= ref(MIRROR, "main"), tostring(new))
c, o = try(CLIENT, "push", "-q", "mirror", "accepted")
if c ~= 0 then T:refuse("setup-failed", "push accepted: " .. o) end
local stranded = git(MIRROR, "commit-tree", "refs/heads/accepted^{tree}", "-p", ref(MIRROR, "accepted"), "-m", "stranded")
git(MIRROR, "update-ref", "refs/heads/accepted", stranded)
fs.write(W.rel .. "/client/file2", "stale-work\n")
git(CLIENT, "add", "file2"); git(CLIENT, "commit", "-qm", "stale-work")
c, o = try(CLIENT, "push", "mirror", "HEAD:refs/heads/main")
T:arm("4 a stale push is rejected and attempts the reconcile fetch", c ~= 0 and has(o, "Reconcile fetch"), "rc=" .. tostring(c) .. " " .. o)
T:arm("4 the mirror fast-forwarded to upstream", ref(MIRROR, "main") == new, tostring(ref(MIRROR, "main")) .. " want " .. tostring(new))
T:arm("4 the stranded mirror head survived", ref(MIRROR, "accepted") == stranded, tostring(ref(MIRROR, "accepted")) .. " want " .. stranded)
git(CLIENT, "fetch", "-q", "mirror", "main")
c, o = try(CLIENT, "rebase", "-q", git(CLIENT, "rev-parse", "FETCH_HEAD"))
T:arm("4 the client rebases onto the reconciled head", c == 0, o)
c, o = try(CLIENT, "push", "mirror", "HEAD:refs/heads/main")
T:arm("4 the retry lands and both repositories converge", c == 0 and ref(MIRROR, "main") ~= new and ref(MIRROR, "main") == ref(UP, "main"), "rc=" .. tostring(c) .. " " .. o)
T:finish()
