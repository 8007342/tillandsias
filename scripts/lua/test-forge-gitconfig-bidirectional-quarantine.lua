-- @env PATH HOME XDG_RUNTIME_DIR TILLANDSIAS_FORGE_IMAGE
-- @trace spec:git-mirror-service, order:321, order:2368-efqj
--
-- test-forge-gitconfig-bidirectional-quarantine.lua — a forge working on a host checkout
-- through a facade git dir reads none of the host's git config (credential helper, URL
-- rewrites, includes, hooksPath), and what it writes to its own never reaches the host's.
-- Objects and refs are shared, so its commit and push land. Ported from the .sh (2368-efqj).
--
-- Verdict: ok:forge-gitconfig-bidirectional-quarantine:<n> arms
--        | violation:forge-gitconfig-bidirectional-quarantine:<n>-failed
--        | refused:forge-gitconfig-bidirectional-quarantine:no-forge-image

local fixture = require "common.fixture"
local forge = require "common.forge_image"
local T = fixture.new("forge-gitconfig-bidirectional-quarantine")
local IMAGE = forge.pick(T)
if not IMAGE then T:refuse("no-forge-image", "no tillandsias-forge image available (need one build first)") end
local W = T:scratch()
fs.mkdir(W.rel .. "/home")
local ENV = { HOME = W.abs .. "/home", GIT_CONFIG_NOSYSTEM = "1" }
local function try(e, ...)
    local argv = { "git" }
    for _, a in ipairs({ ... }) do argv[#argv + 1] = a end
    local full = {}
    for k, v in pairs(ENV) do full[k] = v end
    for k, v in pairs(e or {}) do full[k] = v end
    argv.env, argv.env_unset = full, { "GIT_*" }
    local r = T:run(argv)
    return r.code == 0, text.trim(r.stdout or ""), r.stderr or ""
end
local function git(...)
    local ok, o, e = try(nil, ...)
    if not ok then T:refuse("setup-failed", "git " .. table.concat({ ... }, " ") .. ": " .. e) end
    return o
end
local UP, P, F = W.abs .. "/upstream.git", W.abs .. "/project", W.abs .. "/forge-gitdir"
git("init", "--bare", "-q", UP)
git("init", "-q", "-b", "main", P)
git("-C", P, "config", "user.name", "Host"); git("-C", P, "config", "user.email", "host@example.test")
fs.write(W.rel .. "/project/tracked.txt", "host\n")
git("-C", P, "add", "tracked.txt"); git("-C", P, "commit", "-qm", "host")
git("-C", P, "remote", "add", "origin", "file://" .. UP); git("-C", P, "push", "-q", "-u", "origin", "main")
for _, kv in ipairs{ { "credential.helper", "host-secret-helper" }, { "url.ssh://host-only/.insteadOf", "https://github.com/" },
    { "include.path", "/host/secret.gitconfig" }, { "core.hooksPath", "/host/hooks" } } do git("-C", P, "config", kv[1], kv[2]) end
local before = fs.read(W.rel .. "/project/.git/config")

for _, d in ipairs{ "objects", "refs", "logs" } do fs.mkdir(W.rel .. "/forge-gitdir/" .. d) end
fs.write(W.rel .. "/forge-gitdir/HEAD", fs.read(W.rel .. "/project/.git/HEAD"))
fs.write(W.rel .. "/forge-gitdir/config", "[core]\n\trepositoryformatversion = 0\n\tbare = false\n\tlogallrefupdates = true\n[gc]\n\tauto = 0\n[maintenance]\n\tauto = false\n"
    .. '[remote "origin"]\n\turl = file:///upstream\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n')
local ok, _, e = try({ GIT_OBJECT_DIRECTORY = P .. "/.git/objects" }, "--git-dir=" .. F, "read-tree", git("-C", P, "rev-parse", "HEAD^{tree}"))
if not ok then T:refuse("setup-failed", "read-tree: " .. e) end

local r = forge.run(T, IMAGE, {
    "--mount", "type=bind,source=" .. P .. ",target=/workspace",
    "--mount", "type=bind,source=" .. F .. ",target=/workspace/.git",
    "--mount", "type=bind,source=" .. P .. "/.git/objects,target=/workspace/.git/objects",
    "--mount", "type=bind,source=" .. P .. "/.git/refs,target=/workspace/.git/refs",
    "--mount", "type=bind,source=" .. UP .. ",target=/upstream",
    "--env", "GIT_CONFIG_GLOBAL=/dev/null", "--env", "GIT_CONFIG_SYSTEM=/dev/null" }, [[
cd /workspace
echo "helper=$(git config --local --get credential.helper || true)"
echo "url=$(git config --local --get-regexp '^url\..*\.insteadOf$' || true)"
echo "include=$(git config --local --get include.path || true)"
echo "hooks=$(git config --local --get core.hooksPath || true)"
git fetch --quiet origin
git config --local user.x forge-only
git config --local url.git://forge-only/.insteadOf https://example.test/
git config user.name Forge
git config user.email forge@example.test
printf "forge\n" >>tracked.txt
git add tracked.txt
git commit --quiet -m forge
git push --quiet origin HEAD:refs/heads/main
echo "head=$(git rev-parse HEAD)"
]])
local f = {}
for k, v in (r.stdout or ""):gmatch("(%w+)=([^\n]*)\n") do f[k] = v end
local raw = "rc=" .. tostring(r.code) .. " " .. ((r.stdout or "") .. (r.stderr or "")):gsub("\n", " | ")
T:arm("the forge reads no host credential helper, URL rewrite, include or hooksPath", f.helper == "" and f.url == "" and f.include == "" and f.hooks == "", raw)
T:arm("the forge fetches, commits and pushes", r.code == 0 and f.head ~= nil, raw)
local after = fs.read(W.rel .. "/project/.git/config")
T:arm("the host's git config is byte-identical", after == before, after)
local facade = fs.read(W.rel .. "/forge-gitdir/config")
T:arm("what the forge wrote is in its own config", facade:find("x = forge-only", 1, true) and facade:find("git://forge-only/", 1, true), facade)
local head = f.head or "none"
local _, hm = try(nil, "-C", P, "rev-parse", "refs/heads/main")
local _, um = try(nil, "--git-dir=" .. UP, "rev-parse", "refs/heads/main")
T:arm("the host's main is the forge's commit", hm == head, hm .. " want " .. head)
T:arm("upstream's main is the forge's commit", um == head, um .. " want " .. head)
T:arm("the forge's commit and edit are in the host checkout", (try(nil, "-C", P, "cat-file", "-e", head .. "^{commit}"))
    and fs.read(W.rel .. "/project/tracked.txt"):find("forge", 1, true), head)
T:finish()
