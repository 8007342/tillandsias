-- @trace order:776-cm74, order:2302-yqv5, spec:user-runtime-lifecycle
--
-- test-hash-image-sources.lua — canonical skills take part in the forge image
-- cache key. Ported from test-hash-image-sources.sh (2302-yqv5).
--
--   1 POLICY    the squash-new layer policy is in the shell cache key
--   2 LOCATION  two checkouts of one commit hash the same
--   3 MODE      a STAGED executable bit moves the hash. Through the index on
--               purpose (776-cm74): the hasher reads `git ls-files -s`, so an
--               unstaged chmod rightly moves nothing, and this form also works
--               with core.fileMode=false.
--   4 LINK      a symlink-target change moves the hash
--   5 CONTENT   a skill's content change moves the hash
--   6, 7        an untracked, or an ignored, canonical skill is refused
--   8 CRLF      a CRLF worktree over an LF blob (what core.autocrlf=true leaves)
--               does NOT move the hash
--   9 CONTROL   a real staged change does, or arm 8 would pass on a hasher that
--               ignores content
--
-- Arms 4 and 5 compare with the hash taken BEFORE arm 3, as the .sh did, but
-- arm 3's staged mode stays in the index there, so either would pass on the mode
-- alone. Here each is compared with the hash taken just before it, staged.
--
-- Verdict: ok:hash-image-sources:<n> arms | violation:hash-image-sources:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("hash-image-sources")
local ROOT = fixture.repo_root()
local HASHER = ROOT .. "/scripts/hash-image-sources.sh"
local R = T:git_repo("repo")
local W = T:scratch("clone")
local function git(...) return T:must{ "git", "-C", R.abs, ... } end
local function put(f, s) fs.write(R.rel .. "/" .. f, s) end
local function hash_rc(root)
    local r = T:run{ fixture.posix_shell(), HASHER, "forge", root .. "/images/default", root }
    return r.code, text.trim(r.stdout or ""), r.stderr or ""
end
local function hash(root)
    local rc, h, e = hash_rc(root or R.abs)
    if rc ~= 0 or h == "" then T:refuse("hasher-failed", "rc=" .. tostring(rc) .. " " .. e) end
    return h
end

for _, d in ipairs({ "images/default", "skills/meta", "cheatsheets", "cheatsheet-sources" }) do fs.mkdir(R.rel .. "/" .. d) end
put("images/default/Containerfile", "FROM scratch\n")
put("skills/meta/SKILL.md", "safe contract v1\n")
put("skills/meta/alternate.md", "alternate contract\n")
put("cheatsheets/test.md", "cheat\n")
put("cheatsheet-sources/test.md", "source\n")
put(".gitignore", "*.tmp\n")
-- A link blob through the index, so a host without symlinks still has one.
local function link(to)
    local r = T:run{ "git", "-C", R.abs, "hash-object", "-w", "--stdin", stdin = to }
    if r.code ~= 0 then T:refuse("hash-object", r.stderr) end
    git("update-index", "--add", "--cacheinfo", "120000," .. text.trim(r.stdout) .. ",skills/meta/current")
end
git("add", ".")
link("SKILL.md")
git("commit", "-qm", "baseline")
git("checkout", "-q", "--", "skills/meta/current")

T:arm("1 POLICY the squash-new policy is in the cache key", fs.read("scripts/hash-image-sources.sh"):find("layer-policy:squash-new", 1, true) ~= nil, "absent")
local before = hash()
T:must{ "git", "clone", "-q", R.abs, W.abs .. "/clone" }
local c = hash(W.abs .. "/clone")
T:arm("2 LOCATION the hash does not depend on the checkout's location", c == before, before .. " vs " .. c)

T:must{ "chmod", "+x", R.abs .. "/skills/meta/SKILL.md" }
git("update-index", "--chmod=+x", "skills/meta/SKILL.md")
local mode = hash()
T:arm("3 MODE a staged executable bit moves the hash", mode ~= before, mode)

git("update-index", "--chmod=-x", "skills/meta/SKILL.md")
T:must{ "chmod", "-x", R.abs .. "/skills/meta/SKILL.md" }
local clean = hash()
link("alternate.md")
git("checkout", "-q", "--", "skills/meta/current")
local linked = hash()
T:arm("4 LINK a symlink-target change moves the hash", clean == before and linked ~= clean, "clean=" .. clean .. " linked=" .. linked)

link("SKILL.md")
git("checkout", "-q", "--", "skills/meta/current")
put("skills/meta/SKILL.md", "safe contract v2\n")
git("add", "skills/meta/SKILL.md")
local after = hash()
T:arm("5 CONTENT a canonical skill change moves the hash", after ~= before, after)

put("skills/meta/untracked.md", "untracked skill\n")
local rc = hash_rc(R.abs)
T:arm("6 UNTRACKED an untracked canonical skill is refused", rc ~= 0, "rc=" .. tostring(rc))
T:must({ "rm", R.abs .. "/skills/meta/untracked.md" })
put("skills/meta/ignored.tmp", "ignored skill\n")
rc = hash_rc(R.abs)
T:arm("7 IGNORED an ignored canonical skill is refused", rc ~= 0, "rc=" .. tostring(rc))
T:must({ "rm", R.abs .. "/skills/meta/ignored.tmp" })

local base = hash()
put("images/default/Containerfile", "FROM scratch\r\n")
local crlf = hash()
T:arm("8 CRLF an unstaged CRLF worktree does not move the hash", crlf == base, base .. " vs " .. crlf)
git("checkout", "-q", "--", "images/default/Containerfile")
put("images/default/Containerfile", "FROM scratch\ngenuinely new line\n")
git("add", "images/default/Containerfile")
local real = hash()
T:arm("9 CONTROL a real staged change moves it", real ~= base, real)
T:finish()
