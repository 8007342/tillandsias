-- @trace spec:git-mirror-service, order:579, order:2373-f26m
--
-- test-git-mirror-existing-volume-hardening.lua — the mirror entrypoint upgrades a
-- PERMISSIVE pre-existing volume, idempotently, and then a rewind or any deletion is
-- rejected BEFORE the privileged relay, while a fast-forward converges both repositories.
-- The real entrypoint, hooks and relay helper, offline. The upstream stays permissive, so a
-- relay-before-reject bug shows as real upstream mutation. Ported from the .sh (2373-f26m).
--
--   1 two starts harden the config and change no ref on either side
--   2 a fast-forward relays once and converges
--   3 branch deletion  4 branch rewind  6 tag and custom-ref deletion  7 a mixed
--     transaction: each refused by name, the relay never invoked, both ref sets identical
--     4 is fed to the hook: the command policy refuses a force push through proc.run
--   5 pre-receive: a stale old OID, an invalid or non-refs/* name, a non-commit branch tip
--   8 the relay helper called directly refuses deletion, smuggled fields, short refs and
--     non-commit tips
--   9 a SHA-256 repository's 64-hex zero OID is still a deletion
--
-- Verdict: ok:git-mirror-existing-volume-hardening:<n> arms | violation:...:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("git-mirror-existing-volume-hardening")
local ROOT = fixture.repo_root()
local SH = fixture.posix_shell()
local W = T:scratch()
fs.mkdir(W.rel .. "/home"); fs.mkdir(W.rel .. "/existing-volume"); fs.write(W.rel .. "/gitconfig", "")
local UP, VOL, CLIENT = W.abs .. "/upstream.git", W.abs .. "/existing-volume", W.abs .. "/client"
local MIRROR = VOL .. "/project"
local MARK = W.rel .. "/relay-invocations"
local ENV = { HOME = W.abs .. "/home", GIT_CONFIG_NOSYSTEM = "1", GIT_CONFIG_GLOBAL = W.abs .. "/gitconfig", GIT_ALLOW_PROTOCOL = "ext:file",
    GIT_AUTHOR_NAME = "fixture", GIT_AUTHOR_EMAIL = "fixture@example.invalid", GIT_COMMITTER_NAME = "fixture", GIT_COMMITTER_EMAIL = "fixture@example.invalid",
    TILLANDSIAS_RELAY_MARKER = W.abs .. "/relay-invocations", TILLANDSIAS_SHA256_RELAY_MARKER = W.abs .. "/relay-invocations" }
local function run(argv, cwd, stdin, extra)
    local e = {}
    for k, v in pairs(ENV) do e[k] = v end
    for k, v in pairs(extra or {}) do e[k] = v end
    argv.cwd, argv.stdin, argv.env, argv.env_unset = cwd or W.abs, stdin or "", e, { "TILLANDSIAS_*", "GIT_*" }
    local r = T:run(argv)
    return r.code, (r.stdout or "") .. (r.stderr or ""), r.stdout or ""
end
local function try(dir, stdin, ...)
    local argv = { "git", "-C", dir }
    for _, a in ipairs({ ... }) do argv[#argv + 1] = a end
    return run(argv, W.abs, stdin)
end
local function git(dir, ...)
    local rc, all, out_ = try(dir, nil, ...)
    if rc ~= 0 then T:refuse("setup-failed", "git " .. table.concat({ ... }, " ") .. ": " .. all) end
    return text.trim(out_)
end
local function sha(dir, ref) local rc, _, o = try(dir, nil, "rev-parse", "--verify", "--quiet", ref); return rc == 0 and text.trim(o) or "absent" end
local function refs() return git(MIRROR, "for-each-ref", "--format=%(refname) %(objectname)") .. "\n--\n" .. git(UP, "for-each-ref", "--format=%(refname) %(objectname)") end
local function has(o, s) return o:find(s, 1, true) ~= nil end
local function relayed() local _, n = fs.read(MARK):gsub("invoked\n", ""); return n end

git(W.abs, "init", "-q", "--bare", UP); git(W.abs, "init", "-q", "--bare", MIRROR); git(W.abs, "init", "-q", CLIENT)
git(CLIENT, "config", "core.hooksPath", ""); git(CLIENT, "remote", "add", "mirror", MIRROR)
fs.write(W.rel .. "/client/file", "base\n")
git(CLIENT, "add", "file"); git(CLIENT, "commit", "-qm", "base"); git(CLIENT, "branch", "-M", "main"); git(CLIENT, "tag", "v-existing")
local BASE = sha(CLIENT, "HEAD")
for _, spec in ipairs{ "HEAD:refs/heads/main", "refs/tags/v-existing", "HEAD:refs/meta/existing" } do git(CLIENT, "push", "-q", UP, spec) end
for _, ref in ipairs{ "refs/heads/main", "refs/tags/v-existing", "refs/meta/existing" } do git(MIRROR, "fetch", "-q", UP, ref .. ":" .. ref) end
git(MIRROR, "symbolic-ref", "HEAD", "refs/heads/main"); git(MIRROR, "config", "core.hooksPath", MIRROR .. "/hooks")
-- A volume the old image created: permissive, no fsck policy.
for _, dir in ipairs{ MIRROR, UP } do git(dir, "config", "receive.denyNonFastForwards", "false"); git(dir, "config", "receive.denyDeletes", "false") end

-- Through ext: a direct filesystem transport would inherit receive-pack's quarantine.
local REMOTE = "ext::env -u GIT_QUARANTINE_PATH -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES %S " .. UP
local function start()
    return run({ SH, ROOT .. "/images/git/entrypoint.sh" }, W.abs, nil, { PROJECT = "project", TILLANDSIAS_PROJECT_DEFAULT_BRANCH = "main", TILLANDSIAS_PROJECT_REMOTE_URL = REMOTE,
        TILLANDSIAS_GIT_SERVICE_ROOT = VOL, TILLANDSIAS_GIT_SERVICE_SHARE = ROOT .. "/images/git", TILLANDSIAS_GIT_SERVICE_SETUP_ONLY = "1" })
end
local function hardened()
    for _, k in ipairs{ "receive.denyNonFastForwards", "receive.denyDeletes", "receive.fsckObjects" } do
        local _, _, o = try(MIRROR, nil, "config", "--get", k)
        if text.trim(o) ~= "true" then return false end
    end
    return true
end
local before = refs()
for i, name in ipairs{ "first", "second" } do
    local rc, log_ = start()
    T:arm("1 the " .. name .. " start hardens the config and changes no ref", rc == 0 and hardened() and refs() == before
        and (i == 1 or has(log_, "setup-only startup complete")), "rc=" .. tostring(rc) .. " " .. log_:sub(-400))
end
if not fs.exists(W.rel .. "/existing-volume/project/hooks/tillandsias-relay-refs") then T:finish() end

-- Count invocations, then exec the exact helper the entrypoint installed.
T:must{ "mv", MIRROR .. "/hooks/tillandsias-relay-refs", MIRROR .. "/hooks/tillandsias-relay-refs.real" }
fs.write(W.rel .. "/wrapper", '#!/bin/sh\n: "${TILLANDSIAS_RELAY_MARKER:?missing relay marker}"\nprintf \'invoked\\n\' >> "$TILLANDSIAS_RELAY_MARKER"\nexec "$(dirname "$0")/tillandsias-relay-refs.real"\n')
T:must{ "cp", W.abs .. "/wrapper", MIRROR .. "/hooks/tillandsias-relay-refs" }
T:must{ "chmod", "+x", MIRROR .. "/hooks/tillandsias-relay-refs" }
local _, _, sample = try(MIRROR, "", "hash-object", "--stdin")
local ZERO = ("0"):rep(#text.trim(sample))
local function commit(s) fs.write(W.rel .. "/client/file", fs.read(W.rel .. "/client/file") .. s .. "\n"); git(CLIENT, "commit", "-qam", s); return sha(CLIENT, "HEAD") end

local ff = commit("fast-forward")
fs.write(MARK, "")
local rc, o = try(CLIENT, nil, "push", "mirror", "HEAD:refs/heads/main")
T:arm("2 a fast-forward relays once and converges both", rc == 0 and relayed() == 1 and sha(MIRROR, "refs/heads/main") == ff and sha(UP, "refs/heads/main") == ff, "rc=" .. tostring(rc) .. " relayed=" .. relayed() .. " " .. o)

-- A refusal: fails, names its reason, never reaches the relay, moves no ref anywhere.
local function refused(name, want, f)
    local b = refs()
    fs.write(MARK, "")
    local code, said = f()
    local n, same = relayed(), refs() == b
    T:arm(name, code ~= 0 and code ~= nil and has(said, want) and n == 0 and same, "rc=" .. tostring(code) .. " relayed=" .. n .. " refs-same=" .. tostring(same) .. " " .. said:sub(-400))
end
local function push(...) local a = { ... }; return function() return try(CLIENT, nil, "push", table.unpack(a)) end end
refused("3 branch deletion stops before relay", "ref deletion is disabled: refs/heads/main", push("mirror", ":refs/heads/main"))

-- The hook and the helper, fed a transaction git would not have built.
local function feed(hook, ...)
    local line = table.concat({ ... }, " ") .. "\n"
    return function() return run({ MIRROR .. "/hooks/" .. hook }, MIRROR, line) end
end
local _, _, blob = try(MIRROR, "not-a-commit\n", "hash-object", "-w", "--stdin")
blob = text.trim(blob)
local _, _, tag = try(MIRROR, "object " .. ff .. "\ntype commit\ntag annotated-probe\ntagger Fixture <fixture@example.invalid> 1 +0000\n\nprobe\n", "hash-object", "-t", "tag", "-w", "--stdin")
tag = text.trim(tag)
local P, R = "pre-receive", "tillandsias-relay-refs.real"
refused("4 a branch rewind stops before relay", "non-fast-forward branch update is disabled", feed(P, ff, BASE, "refs/heads/main"))
refused("5 a stale old OID is refused", "stale old object ID", feed(P, BASE, ff, "refs/heads/main"))
refused("5 an invalid refname is refused", "invalid refname", feed(P, ZERO, ff, "refs/heads/invalid..name"))
refused("5 a ref outside refs/* is refused", "outside refs/*", feed(P, ZERO, ff, "foo/bar"))
refused("5 a blob branch tip is refused", "branch tip is not a commit", feed(P, ZERO, blob, "refs/heads/blob-tip"))
refused("5 an annotated-tag branch tip is refused", "branch tip is not a commit", feed(P, ZERO, tag, "refs/heads/tag-object-tip"))
for _, ref in ipairs{ "refs/tags/v-existing", "refs/meta/existing" } do
    refused("6 deletion of " .. ref .. " stops before relay", "ref deletion is disabled: " .. ref, push("mirror", ":" .. ref))
end
commit("mixed-transaction")
refused("7 a mixed fast-forward and deletion rejects atomically", "ref deletion is disabled: refs/tags/v-existing", push("--atomic", "mirror", "HEAD:refs/heads/main", ":refs/tags/v-existing"))
refused("8 the relay refuses a direct deletion", "upstream ref deletion", feed(R, sha(MIRROR, "refs/tags/v-existing"), ZERO, "refs/tags/v-existing"))
refused("8 the relay refuses a smuggled delete refspec", "malformed receive transaction", feed(R, ZERO, ff, "refs/heads/smuggled", ":refs/tags/v-existing"))
refused("8 the relay refuses a smuggled --force", "malformed receive transaction", feed(R, ff, BASE, "refs/heads/main", "--force"))
refused("8 the relay refuses a ref outside refs/*", "outside refs/*", feed(R, ZERO, ff, "foo/bar"))
refused("8 the relay refuses a blob tip", "branch tip is not a commit", feed(R, ZERO, blob, "refs/heads/blob-direct"))
refused("8 the relay refuses an annotated-tag tip", "branch tip is not a commit", feed(R, ZERO, tag, "refs/heads/tag-object-direct"))

local S, SC = W.abs .. "/sha256.git", W.abs .. "/sha256-client"
git(W.abs, "init", "-q", "--bare", "--object-format=sha256", S); git(W.abs, "init", "-q", "--object-format=sha256", SC)
git(SC, "config", "core.hooksPath", ""); git(SC, "commit", "--allow-empty", "-qm", "sha256-base"); git(SC, "branch", "-M", "main"); git(SC, "push", "-q", S, "HEAD:refs/heads/main")
git(S, "config", "core.hooksPath", S .. "/hooks")
T:must{ "cp", ROOT .. "/images/git/pre-receive-hook.sh", S .. "/hooks/pre-receive" }
fs.write(W.rel .. "/relay256", '#!/bin/sh\nprintf \'invoked\\n\' >> "$TILLANDSIAS_SHA256_RELAY_MARKER"\nexit 0\n')
T:must{ "cp", W.abs .. "/relay256", S .. "/hooks/tillandsias-relay-refs" }
T:must{ "chmod", "+x", S .. "/hooks/pre-receive", S .. "/hooks/tillandsias-relay-refs" }
local head = sha(S, "refs/heads/main")
fs.write(MARK, "")
rc, o = run({ S .. "/hooks/pre-receive" }, S, head .. " " .. ("0"):rep(#head) .. " refs/heads/main\n")
T:arm("9 a SHA-256 deletion is refused before relay", #head == 64 and rc ~= 0 and has(o, "ref deletion is disabled") and relayed() == 0 and sha(S, "refs/heads/main") == head, "rc=" .. tostring(rc) .. " len=" .. #head .. " " .. o)

local bad = {}
for _, dir in ipairs{ MIRROR, UP, S } do local code, said = try(dir, nil, "fsck", "--full", "--strict"); if code ~= 0 then bad[#bad + 1] = said end end
T:arm("every repository passes a strict fsck", #bad == 0, table.concat(bad, " "))
T:finish()
