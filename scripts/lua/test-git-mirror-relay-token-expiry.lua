-- @env PATH
-- @trace spec:git-mirror-service, spec:tillandsias-vault, order:414, order:424, order:2373-f26m
--
-- test-git-mirror-relay-token-expiry.lua — the relay tells an unavailable Vault Agent sink
-- from an absent GitHub token. Before, an expired MIRROR token said "run GitHub Login" and
-- sent operators to fix a credential that was fine. `vault-cli lookup-self` is the
-- discriminator; here it is a stub, and the relay rejects before any push, so nothing is
-- contacted. Ported from the .sh (2373-f26m).
--
--   1 sink expired: the honest auto-auth diagnosis, and no claim about GitHub
--   2 sink valid, GitHub read failing: GitHub Login, and no claim about expiry
--   3 vault-cli routes renew-self and lookup-self
--
-- Verdict: ok:git-mirror-relay-token-expiry:<n> arms | violation:git-mirror-relay-token-expiry:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("git-mirror-relay-token-expiry")
local ROOT = fixture.repo_root()
local SH = fixture.posix_shell()
local W = T:scratch()
fs.mkdir(W.rel .. "/home"); fs.mkdir(W.rel .. "/bin"); fs.write(W.rel .. "/gitconfig", "")
fs.write(W.rel .. "/bin/vault-cli", '#!/bin/sh\ncase "$1" in\n    renew-self)  exit "${STUB_RENEW_RC:-0}" ;;\n    lookup-self) exit "${STUB_LOOKUP_RC:-0}" ;;\n'
    .. '    read)        exit "${STUB_READ_RC:-0}" ;;\n    *)           exit 0 ;;\nesac\n')
fs.write(W.rel .. "/vault-token", "stub-approle-token")
T:must{ "cp", ROOT .. "/images/git/relay-refs.sh", W.abs .. "/relay" }
T:must{ "chmod", "+x", W.abs .. "/bin/vault-cli", W.abs .. "/relay" }
local function run(argv, cwd, stdin, extra)
    local e = { HOME = W.abs .. "/home", PATH = W.abs .. "/bin:" .. env.get("PATH"), GIT_CONFIG_NOSYSTEM = "1", GIT_CONFIG_GLOBAL = W.abs .. "/gitconfig", VAULT_TOKEN_FILE = W.abs .. "/vault-token",
        GIT_AUTHOR_NAME = "fixture", GIT_AUTHOR_EMAIL = "fixture@example.invalid", GIT_COMMITTER_NAME = "fixture", GIT_COMMITTER_EMAIL = "fixture@example.invalid" }
    for k, v in pairs(extra or {}) do e[k] = v end
    argv.cwd, argv.stdin, argv.env, argv.env_unset = cwd or W.abs, stdin or "", e, { "TILLANDSIAS_*", "GIT_*", "VAULT_*" }
    local r = T:run(argv)
    return r.code, (r.stdout or "") .. (r.stderr or ""), text.trim(r.stdout or "")
end
local M = W.abs .. "/mirror.git"
local function git(stdin, ...)
    local argv = { "git" }
    for _, a in ipairs({ ... }) do argv[#argv + 1] = a end
    local rc, all, o = run(argv, W.abs, stdin)
    if rc ~= 0 then T:refuse("setup-failed", table.concat({ ... }, " ") .. ": " .. all) end
    return o
end
git(nil, "init", "-q", "--bare", M)
git(nil, "-C", M, "config", "core.hooksPath", M .. "/hooks")
git(nil, "-C", M, "remote", "add", "origin", "https://github.example.invalid/org/repo.git")
local sha = git("", "-C", M, "commit-tree", git("", "-C", M, "mktree"), "-m", "relay-fixture")
local zero = ("0"):rep(#git("", "-C", M, "hash-object", "--stdin"))
local function relay(read, lookup, renew)
    return run({ W.abs .. "/relay" }, M, zero .. " " .. sha .. " refs/heads/main\n", { STUB_READ_RC = read, STUB_LOOKUP_RC = lookup, STUB_RENEW_RC = renew })
end
local function has(o, s) return o:find(s, 1, true) ~= nil end
local EXPIRED, GITHUB = "expired or unavailable", "HTTPS upstream credential is unavailable"
local rc, o = relay("2", "2", "2")
T:arm("1 an expired sink gets the auto-auth diagnosis, not GitHub Login", rc ~= 0 and has(o, EXPIRED) and not has(o, GITHUB), "rc=" .. tostring(rc) .. " " .. o)
rc, o = relay("2", "0", "0")
T:arm("2 a valid sink and an absent GitHub token get GitHub Login, not expiry", rc ~= 0 and has(o, GITHUB) and not has(o, EXPIRED), "rc=" .. tostring(rc) .. " " .. o)
for _, verb in ipairs{ "renew-self", "lookup-self" } do
    rc, o = run({ SH, ROOT .. "/images/git/vault-cli.sh", verb }, W.abs, nil, { VAULT_TOKEN_FILE = "/nonexistent/path" })
    T:arm("3 vault-cli routes " .. verb, o ~= "" and not has(o, "unknown subcommand"), "rc=" .. tostring(rc) .. " " .. o)
end
T:finish()
