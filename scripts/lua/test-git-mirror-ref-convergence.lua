-- @trace spec:git-mirror-service, order:301, order:2356-d66j
--
-- test-git-mirror-ref-convergence.lua — the git mirror's reconciliation fetch must not
-- clobber a just-received exported ref (order 301). Bare repositories, no network, no
-- podman, the real hooks and relay helper. Ported from the .sh (2356-d66j).
--
--   1 one push converges mirror and upstream through the pre-receive relay
--   2 startup retry preserves and forwards a commit stranded in the mirror; CONTROL: the
--     legacy unsafe refspec strands it
--   3 empty-mirror seeding needs the explicit refspec (the safe default makes no heads),
--     and the seed yields cloneable heads and tags
-- Local receive-pack would inherit the hook's quarantine marker, so upstream is reached
-- through ext, the process boundary production's HTTPS and SSH remotes give.
--
-- Verdict: ok:git-mirror-ref-convergence:<n> arms | violation:git-mirror-ref-convergence:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("git-mirror-ref-convergence")
local ROOT = fixture.repo_root()
local W = T:scratch()
fs.mkdir(W.rel .. "/home")
-- A scratch HOME: the hooks' log-path probing writes under it, never on the real host.
local ENV = { HOME = W.abs .. "/home", GIT_CONFIG_NOSYSTEM = "1", GIT_ALLOW_PROTOCOL = "ext:file",
    GIT_AUTHOR_NAME = "fixture", GIT_AUTHOR_EMAIL = "fixture@t", GIT_COMMITTER_NAME = "fixture", GIT_COMMITTER_EMAIL = "fixture@t" }
local SAFE, UNSAFE = "+refs/heads/*:refs/remotes/origin/*", "+refs/*:refs/*"

local function try(dir, ...)
    local argv = { "git", "-C", dir }
    for _, a in ipairs({ ... }) do argv[#argv + 1] = a end
    argv.env, argv.env_unset = ENV, { "TILLANDSIAS_*", "GIT_*" }
    local r = T:run(argv)
    return r.code == 0, text.trim(r.stdout or ""), r.stderr or ""
end
local function git(dir, ...)
    local ok, o, e = try(dir, ...)
    if not ok then T:refuse("setup-failed", "git " .. table.concat({ ... }, " ") .. ": " .. e) end
    return o
end
local function sha(dir, ref) local ok, o = try(dir, "rev-parse", "--verify", "--quiet", ref); return ok and o or "absent" end

local D
local function case(name)
    D = { rel = W.rel .. "/" .. name, abs = W.abs .. "/" .. name }
    fs.mkdir(D.rel)
    git(D.abs, "init", "-q", "--bare", "upstream")
    git(D.abs, "clone", "-q", "upstream", "work")
    fs.write(D.rel .. "/work/f", "base\n")
    git(D.abs .. "/work", "add", "f"); git(D.abs .. "/work", "commit", "-qm", "base")
    git(D.abs .. "/work", "branch", "-M", "main")
    git(D.abs .. "/work", "push", "-q", "origin", "HEAD:refs/heads/main")
    return D
end
local function commit(s)
    fs.write(D.rel .. "/work/f", fs.read(D.rel .. "/work/f") .. s .. "\n")
    git(D.abs .. "/work", "commit", "-qam", s)
    return sha(D.abs .. "/work", "HEAD")
end
-- The mirror's origin, as entrypoint.sh configures it, and the hooks this case needs.
local HOOKS = { ["pre-receive"] = "images/git/pre-receive-hook.sh", ["post-receive"] = "images/git/post-receive-hook.sh",
    ["tillandsias-relay-refs"] = "images/git/relay-refs.sh" }
local function mirror(name, refspec, hooks)
    git(D.abs, "init", "-q", "--bare", name)
    local m = D.abs .. "/" .. name
    git(m, "config", "receive.denyNonFastforwards", "false")
    git(m, "config", "receive.denyDeletes", "false")
    git(m, "config", "core.hooksPath", m .. "/hooks") -- a forge's global one would win
    git(m, "remote", "add", "origin", "ext::env -u GIT_QUARANTINE_PATH -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES %S " .. D.abs .. "/upstream")
    git(m, "config", "remote.origin.fetch", refspec)
    if refspec == SAFE then git(m, "config", "remote.origin.tagOpt", "--no-tags") end
    for _, h in ipairs(hooks or {}) do
        T:must{ "cp", ROOT .. "/" .. HOOKS[h], m .. "/hooks/" .. h }
        T:must{ "chmod", "+x", m .. "/hooks/" .. h }
    end
    return m
end

case("push")
local m = mirror("mirror", SAFE, { "pre-receive", "post-receive", "tillandsias-relay-refs" })
try(D.abs .. "/work", "push", "-q", m, "main")
local probe = commit("probe")
try(D.abs .. "/work", "push", "-q", m, "main")
local ms, us = sha(m, "refs/heads/main"), sha(D.abs .. "/upstream", "refs/heads/main")
T:arm("1 one push converges mirror and upstream", ms == probe and us == probe, "mirror " .. ms .. " upstream " .. us .. " want " .. probe)

-- No receive hook: the entrypoint's startup retry (reconcile fetch, then push each head).
local function retry(name, refspec)
    case(name)
    local b = mirror("mirror", refspec, { "tillandsias-relay-refs" })
    git(b, "fetch", "origin", "+refs/heads/*:refs/heads/*")
    local stranded = commit("stranded")
    git(D.abs .. "/work", "push", "-q", b, "main")
    try(b, "fetch", "origin")
    local updates = ""
    for ref in git(b, "for-each-ref", "--format=%(refname)", "refs/heads", "refs/tags"):gmatch("[^\n]+") do
        updates = updates .. sha(b, ref) .. " " .. sha(b, ref) .. " " .. ref .. "\n"
    end
    T:run{ b .. "/hooks/tillandsias-relay-refs", cwd = b, stdin = updates, env = ENV, env_unset = { "TILLANDSIAS_*", "GIT_*" } }
    return sha(b, "refs/heads/main"), sha(D.abs .. "/upstream", "refs/heads/main"), stranded
end
local rm, ru, rs = retry("retry-safe", SAFE)
T:arm("2 safe: the mirror keeps the stranded commit across the reconcile fetch", rm == rs, rm .. " want " .. rs)
T:arm("2 safe: upstream receives the stranded commit", ru == rs, ru .. " want " .. rs)
rm, ru, rs = retry("retry-unsafe", UNSAFE)
T:arm("2 CONTROL the unsafe refspec strands the commit", rm ~= rs, "it was preserved: " .. rm)

case("seed")
git(D.abs .. "/work", "tag", "v1"); git(D.abs .. "/work", "push", "-q", "origin", "v1")
local base = sha(D.abs .. "/work", "HEAD")
m = mirror("plain", SAFE)
try(m, "fetch", "origin")
T:arm("3 the safe default refspec alone makes no exported head", sha(m, "refs/heads/main") == "absent", sha(m, "refs/heads/main"))
T:arm("3 it does make the tracking ref", sha(m, "refs/remotes/origin/main") == base, sha(m, "refs/remotes/origin/main"))
m = mirror("mirror", SAFE)
local seeded = try(m, "fetch", "origin", "+refs/heads/*:refs/heads/*", "+refs/tags/*:refs/tags/*")
T:arm("3 the explicit seed makes the head and the tag", seeded and sha(m, "refs/heads/main") == base and sha(m, "refs/tags/v1") == base,
    sha(m, "refs/heads/main") .. " " .. sha(m, "refs/tags/v1"))
git(m, "symbolic-ref", "HEAD", "refs/heads/main")
local cloned = try(D.abs, "clone", "-q", "mirror", "clone")
T:arm("3 the seeded mirror clones with content and tag", cloned and fs.exists(D.rel .. "/clone/f") and sha(D.abs .. "/clone", "refs/tags/v1") == base, "cloned=" .. tostring(cloned))
T:finish()
