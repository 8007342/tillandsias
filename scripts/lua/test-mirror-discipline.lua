-- @env PATH HOME
-- @trace spec:git-mirror-service, spec:branch-discipline, order:1443-uit6, order:2373-8vq6
--
-- test-mirror-discipline.lua — the mirror enforces the project's seeded branch discipline at
-- pre-receive and publishes it as one ref. Ported from the .sh of the same name (2373-8vq6). Scratch
-- mirrors with the shipped hook and a relay stub that records whether it ran; every push uses the
-- flag a client hook cannot stop.
--
--   1 enforced: main refused before the relay, in the seed's words   1b or the default's, whole
--   2 FLOOR no seed: accepted, silently          3 grammar warn        4 grammar enforced
--   5 the integration branch relays as before    6 an unreadable seed applies nothing and says so
--   7 publish: one ref, the seed's sha256, its bytes     8 a changed seed replaces it
--   9 no seed: level 0, digest none              10 neighbouring namespaces are untouched
--   11 no ruby: reported, fails open             12 a seed on the integration branch only
--   13 a level-0 publish names what it tried     14 a project with no linux-next uses HEAD
--   15 promoting the integration tip is accepted; a commit past it is not
--
-- Usage: tillandsias-plan script run scripts/lua/test-mirror-discipline.lua
-- Verdict: ok:mirror-discipline:<n> arms | violation:... | skip:mirror-discipline:no-ruby

local fixture = require "common.fixture"
local T = fixture.new("mirror-discipline")
local SH, ROOT = fixture.posix_shell(), fixture.repo_root()
-- Run ruby, don't stat it: a forge's is a shim that exits 127 (1597-rrku). The image ships ruby.
if T:run{ SH, "-s", stdin = "TILLANDSIAS_BREW_AUTOINSTALL=0 ruby -e 'exit 0' >/dev/null 2>&1\n" }.code ~= 0 then T:skip("no-ruby") end
-- The entrypoint's own shipped values, so fixture and image cannot drift.
local CONF, entry = {}, "\n" .. fs.read("images/git/entrypoint.sh")
for _, k in ipairs{ "TILLANDSIAS_RESCUE_REF_GLOB", "TILLANDSIAS_RESCUE_REF_HINT", "TILLANDSIAS_DISCIPLINE_SEED_REFS" } do
    CONF[k] = entry:match("\n *" .. k .. "='([^\n]*)'\n")
    if not CONF[k] then T:refuse("entrypoint-config-missing", k) end
end
local function seed(branch, grammar)
    return (([==[
version: 1
level: 2
enforcement:
  default_branch: @B
  ref_grammar: @G
default_branch: main
integration:
  linux: linux-next
  forge: linux-next
work_ref: "work/[0-9]{3,4}-[a-z0-9]{4}"
salvage_ref: "salvage/<host>/<yyyymmdd>-<slug>"
messages:
  default_branch_denied: "push to {default} denied: this project uses branch {integration} for integration and {work_ref} for work; switch to the corresponding branch and rebase to remote"
]==]):gsub("@B", branch):gsub("@G", grammar))
end
local w, seq = T:scratch(), 0
local PRE = [==[
set -u
d="$1"; R="$2"; G="git -c init.defaultBranch=main"
push() { rm -f "$d/relayed"; rc=0; $G -C "$d/work" push --no-verify origin "$1" >"$d/out" 2>&1 || rc=$?; cat "$d/out"; echo "rc=$rc relayed=$([ -e "$d/relayed" ] && echo yes || echo no)"; }
commit() { echo "$1" >"$d/work/$1"; $G -C "$d/work" add -A; $G -C "$d/work" commit -qm "$1"; }
pub() { sh "$R/images/git/publish-discipline.sh" "$d/mirror.git" 2>&1; }
refs() { $G -C "$d/mirror.git" for-each-ref --format='%(refname)' refs/tillandsias/discipline; }
raw() { $G -C "$d/mirror.git" config core.hooksPath "$d/nohooks"; $G -C "$d/work" push -q --no-verify origin "$@"; $G -C "$d/mirror.git" config core.hooksPath "$d/mirror.git/hooks"; }
]==]
local function sh(d, body, more)
    local e = { PATH = env.get("PATH"), HOME = w.abs, GIT_CONFIG_NOSYSTEM = "1", LANGUAGE = "en", GIT_AUTHOR_NAME = "f", GIT_AUTHOR_EMAIL = "f@example.invalid", GIT_COMMITTER_NAME = "f", GIT_COMMITTER_EMAIL = "f@example.invalid" }
    for k, v in pairs(CONF) do e[k] = v end
    for k, v in pairs(more or {}) do e[k] = v end
    local r = proc.run{ argv = { SH, "-s", "--", d.abs, ROOT }, cwd = d.abs, stdin = PRE .. body, env = e, env_unset = { "TILLANDSIAS_*", "GIT_*" }, timeout_ms = 60000 }
    local o = "\n" .. (r.stdout or ""):gsub("\r", "") .. (r.stderr or "")
    return { code = r.code, out = o, rc = o:match("\nrc=(%d+) relayed="), relayed = o:match(" relayed=(%a+)") == "yes", why = "code=" .. tostring(r.code) .. " " .. o:sub(1, 600) }
end
-- A mirror whose main (and linux-next) carry `text`; the hook is installed after, as on an existing one.
local function mirror(text_, branches)
    seq = seq + 1
    local d = { rel = w.rel .. "/m" .. seq, abs = w.abs .. "/m" .. seq }
    fs.mkdir(d.rel .. "/mirror.git"); fs.mkdir(d.rel .. "/nohooks")
    local r = sh(d, [==[
set -e
$G init -q --bare "$d/mirror.git"; mkdir -p "$d/mirror.git/hooks"
cp "$R/images/git/pre-receive-hook.sh" "$d/mirror.git/hooks/pre-receive"
printf '#!/bin/sh\ncat >/dev/null\n: >"%s/relayed"\nexit 0\n' "$d" >"$d/mirror.git/hooks/tillandsias-relay-refs"
chmod +x "$d/mirror.git/hooks/pre-receive" "$d/mirror.git/hooks/tillandsias-relay-refs"
$G init -q "$d/work"; $G -C "$d/work" remote add origin "$d/mirror.git"; echo base >"$d/work/base"
]==])
    if r.code ~= 0 then T:refuse("setup-failed", r.why) end
    if text_ then fs.mkdir(d.rel .. "/work/.tillandsias"); fs.write(d.rel .. "/work/.tillandsias/branch-discipline.yaml", text_) end
    r = sh(d, 'set -e\n$G -C "$d/work" add -A; $G -C "$d/work" commit -qm base; raw ' .. (branches or "main main:linux-next"))
    if r.code ~= 0 then T:refuse("setup-failed", r.why) end
    return d
end
local function digest(d) return hash.sha256(fs.read(d.rel .. "/work/.tillandsias/branch-discipline.yaml")) end
local function published(x)
    local l = {}
    for ref in x.out:gmatch("\n(refs/tillandsias/discipline/[^\n]*)") do l[#l + 1] = ref end
    return l[1] or "", #l
end
local function level2(ref, want) return ref:match("^refs/tillandsias/discipline/2/enforced/unknown/(%x+)/%d+$") == want end
local DENIED = "blocked:branch-discipline:default-branch:main"

local d = mirror(seed("enforced", "warn"))
local x = sh(d, "commit c1; push main")
T:arm("1 enforced: main is refused before the relay, in the seed's words", x.rc ~= "0" and x.rc and not x.relayed and text.contains(x.out, "push to main denied: this project uses branch linux-next for integration and work/<order> for work"), x.why)
d = mirror((seed("enforced", "warn"):gsub("\nmessages:.*", "\n")))
x = sh(d, "commit c1b; push main")
T:arm("1b with no message the default denial is whole", x.rc and x.rc ~= "0" and not x.relayed and x.out:find("push to main denied: use linux%-next for integration and work/<order> for work *\n") ~= nil and not text.contains(x.out, "for work}"), x.why)
d = mirror(nil)
x = sh(d, "commit c2; push main")
T:arm("2 FLOOR with no seed main is accepted and relayed, silently", x.rc == "0" and x.relayed and not text.contains(x.out, "branch-discipline") and not text.contains(x.out, "denied") and not text.contains(x.out, "branch grammar") and not text.contains(x.out, "WARNING"), x.why)
d = mirror(seed("enforced", "warn"))
x = sh(d, "commit c3; push HEAD:refs/heads/feature-x")
T:arm("3a grammar warn: feature-x is accepted with a warning", x.rc == "0" and text.contains(x.out, "outside this project's branch grammar"), x.why)
x = sh(d, "push HEAD:refs/heads/work/1443-uit6")
T:arm("3b and a work ref without one", x.rc == "0" and not text.contains(x.out, "WARNING"), x.why)
d = mirror(seed("enforced", "enforced"))
x = sh(d, "commit c4; push HEAD:refs/heads/feature-x")
T:arm("4a grammar enforced: feature-x is refused", x.rc and x.rc ~= "0" and text.contains(x.out, "blocked:branch-discipline:ref-grammar:feature-x"), x.why)
for _, r in ipairs{ "work/1443-uit6", "salvage/lenovinha/20260928-x" } do
    x = sh(d, "push HEAD:refs/heads/" .. r)
    T:arm("4b and " .. r .. " is accepted", x.rc == "0", x.why)
end
d = mirror(seed("enforced", "enforced"))
x = sh(d, "commit c5; push HEAD:refs/heads/linux-next")
T:arm("5 the integration branch relays as before", x.rc == "0" and x.relayed, x.why)
d = mirror("level: [unterminated\n")
x = sh(d, "commit c6; push main")
T:arm("6 an unparseable seed is reported and applies nothing", x.rc == "0" and text.contains(x.out, "present but unreadable"), x.why)

d = mirror(seed("enforced", "warn"))
x = sh(d, 'pub >/dev/null; refs; $G -C "$d/mirror.git" cat-file -p "$(refs)" >"$d/blob"')
local ref, n = published(x)
local first = digest(d)
T:arm("7a one ref: level 2, strictest enforcement, the seed's sha256", n == 1 and level2(ref, first), n .. " " .. x.why)
T:arm("7b the blob is the seed, byte for byte", fs.exists(d.rel .. "/blob") and fs.read(d.rel .. "/blob") == fs.read(d.rel .. "/work/.tillandsias/branch-discipline.yaml"), "differs")
fs.write(d.rel .. "/work/.tillandsias/branch-discipline.yaml", seed("enforced", "enforced"))
x = sh(d, '$G -C "$d/work" commit -qam "raise grammar"; push HEAD:refs/heads/linux-next >/dev/null; sleep 1; pub >/dev/null; refs')
ref, n = published(x)
T:arm("8 a changed seed replaces the ref", n == 1 and digest(d) ~= first and level2(ref, digest(d)), n .. " " .. x.why)
d = mirror(nil)
x = sh(d, "pub >/dev/null; refs")
ref, n = published(x)
T:arm("9 no seed publishes level 0, advised, digest none", n == 1 and ref:match("^refs/tillandsias/discipline/0/advised/unknown/none/%d+$") ~= nil, n .. " " .. x.why)
x = sh(d, 'b="$(echo x | $G -C "$d/mirror.git" hash-object -w --stdin)"; $G -C "$d/mirror.git" update-ref refs/tillandsias/upstream-auth/authorized/1 "$b"; pub >/dev/null; $G -C "$d/mirror.git" rev-parse --verify --quiet refs/tillandsias/upstream-auth/authorized/1 >/dev/null && echo kept; refs')
ref, n = published(x)
T:arm("10 the publisher leaves a neighbouring namespace alone", text.contains(x.out, "\nkept\n") and n == 1, x.why)
d = mirror(seed("enforced", "enforced"))
x = sh(d, [==[
commit c11; mkdir "$d/noruby"
IFS=:; for p in $PATH; do
    [ -d "$p" ] || continue
    for f in "$p"/*; do b="${f##*/}"; [ "$b" = ruby ] && continue; [ -e "$d/noruby/$b" ] || { [ -x "$f" ] && ln -s "$f" "$d/noruby/$b" 2>/dev/null; }; done
done; unset IFS
PATH="$d/noruby"; export PATH; hash -r
command -v ruby >/dev/null 2>&1 && echo still-ruby
push main; pub >/dev/null; refs
]==])
ref, n = published(x)
T:arm("11 no ruby: reported unreadable, the push is accepted, one ref published", not text.contains(x.out, "still-ruby") and x.rc == "0" and x.relayed and text.contains(x.out, "present but unreadable (no-ruby)") and n == 1, n .. " " .. x.why)
d = mirror(nil, "main")
fs.mkdir(d.rel .. "/work/.tillandsias"); fs.write(d.rel .. "/work/.tillandsias/branch-discipline.yaml", seed("enforced", "warn"))
local want = digest(d)
x = sh(d, '$G -C "$d/work" add -A; $G -C "$d/work" commit -qm seed; raw HEAD:refs/heads/linux-next; pub; refs; $G -C "$d/work" reset -q --hard HEAD~1; commit c12; push main')
ref, n = published(x)
T:arm("12a a seed only on the integration branch is published from it", n == 1 and level2(ref, want) and text.contains(x.out, "seed from refs/heads/linux-next"), x.why)
T:arm("12b and an enforced push to main is refused", x.rc and x.rc ~= "0" and not x.relayed and text.contains(x.out, DENIED), x.why)
d = mirror(nil)
x = sh(d, "pub")
T:arm("13 a level-0 publish names the refs it tried", text.contains(x.out, "no seed on:") and text.contains(x.out, "HEAD"), x.why)
d = mirror(seed("enforced", "warn"), "main")
x = sh(d, '$G -C "$d/mirror.git" rev-parse --verify --quiet refs/heads/linux-next && echo has-linux-next; pub; refs; commit c14; push main')
ref, n = published(x)
T:arm("14 a project with no linux-next publishes and enforces HEAD's seed", not text.contains(x.out, "has-linux-next") and level2(ref, digest(d)) and text.contains(x.out, "seed from HEAD") and x.rc and x.rc ~= "0", x.why)
d = mirror(seed("enforced", "warn"))
x = sh(d, "commit c15; push HEAD:refs/heads/linux-next >/dev/null; push main")
T:arm("15a promoting the integration tip is accepted and relayed", x.rc == "0" and x.relayed and text.contains(x.out, "ok:branch-discipline:default-branch:main:promoted-from:linux-next"), x.why)
x = sh(d, "commit c15b; push main")
T:arm("15b CONTROL a commit past it is refused", x.rc and x.rc ~= "0" and not x.relayed and text.contains(x.out, DENIED), x.why)
T:finish()
