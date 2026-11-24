-- @trace order:1362-u8ww, order:2303-h6qe, spec:git-mirror-service
--
-- test-forge-seed-branch-resolution.lua — a forge clone never takes its branch
-- from the mirror's HEAD. Ported from the .sh (2303-h6qe).
--
-- Measured on pirria 2026-09-22: a cloud launch cloned a mirror whose HEAD named
-- work/1325-ygq5 (that host's own work branch) and the project opened there. The
-- clone transports now RESOLVE an unset seed (the discipline seed's integration
-- branch, else its default_branch, else main/master) and print which they chose.
--
-- Hermetic: scratch bare mirrors and clones; the functions are cut from
-- images/default/lib-common.sh, trace_lifecycle is a stub.
--
--   1 THE CLOSURE mirrors whose HEADs name DIFFERENT branches seed the SAME one,
--     the discipline seed's integration.forge, and the forge says why
--   2 no discipline seed: the remote default by convention (main), named
--   3 an explicit TILLANDSIAS_FORGE_SEED_BRANCH still wins
--   4 nothing resolvable: a LOUD warning naming the mirror's HEAD, the clone
--     stays, and the status is 0 (never hard-fails a launch)
--   5 the HOST-MOUNT call (no `resolve`) never switches the user's own tree
--   6 CONTROL a clone of that mirror with no seeding lands on the stray branch,
--     so arm 1 is not passing on a mirror that already named linux-next. (The
--     .sh ran trunk's pre-fix function here, a permanent skip once it landed.)
--
-- Verdict: ok:forge-seed-branch-resolution:6 arms | violation:forge-seed-branch-resolution:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("forge-seed-branch-resolution")
local W = T:scratch()
fs.write(W.rel .. "/gitconfig", "[user]\n\tname = t\n\temail = t@example.invalid\n[init]\n\tdefaultBranch = main\n[commit]\n\tgpgsign = false\n")
local E = { GIT_CONFIG_GLOBAL = W.abs .. "/gitconfig", GIT_CONFIG_NOSYSTEM = "1" }
local function git(...)
    local a = { "git", ... }
    a.env = E
    return T:must(a)
end

local funcs, on = {}, false
for _, l in ipairs(text.lines(fs.read("images/default/lib-common.sh"))) do
    if l:match("^resolve_forge_seed_branch%(%) {") or l:match("^checkout_forge_seed_branch%(%) {") then on = true end
    if on then
        funcs[#funcs + 1] = l
        if l:sub(1, 1) == "}" then on = false end
    end
end
local src = table.concat(funcs, "\n")
if not (src:find("resolve_forge_seed_branch() {", 1, true) and src:find("checkout_forge_seed_branch() {", 1, true)) then
    T:arm("0 both functions are in lib-common.sh", false, "missing")
    T:finish()
end
-- proc.run passes TILLANDSIAS_* through, so a launch's own seed is unset here.
fs.write(W.rel .. "/seed.sh", "[ -n \"${ARM_SEED:-}\" ] && export TILLANDSIAS_FORGE_SEED_BRANCH=\"$ARM_SEED\" || unset TILLANDSIAS_FORGE_SEED_BRANCH\ntrace_lifecycle() { :; }\n" .. src .. '\ncheckout_forge_seed_branch ${1:+"$1"}\necho "rc=$?"\n')

local function mirror(name, head, seed, branches)
    local d, rel = W.abs .. "/src-" .. name, W.rel .. "/src-" .. name
    git("init", "-q", "-b", "main", d)
    if seed then
        fs.mkdir(rel .. "/.tillandsias")
        fs.write(rel .. "/.tillandsias/branch-discipline.yaml",
            "version: 1\nlevel: 2\ndefault_branch: main\nintegration:\n  linux: linux-next\n  forge: linux-next\n  macos: osx-next\n")
    end
    fs.write(rel .. "/README", "base\n")
    git("-C", d, "add", "-A"); git("-C", d, "commit", "-q", "-m", "base")
    for _, b in ipairs(branches) do git("-C", d, "branch", "-q", b) end
    git("clone", "-q", "--bare", d, W.abs .. "/" .. name .. ".git")
    git("-C", W.abs .. "/" .. name .. ".git", "symbolic-ref", "HEAD", "refs/heads/" .. head)
end
local n = 0
local function clone(m)
    n = n + 1
    local c = W.abs .. "/clone-" .. n
    git("clone", "-q", W.abs .. "/" .. m .. ".git", c)
    return c
end
local function head(c) return text.trim(git("-C", c, "symbolic-ref", "--short", "-q", "HEAD").stdout or "") end
-- branch after, everything said
local function forge(m, arg, extra)
    local c, e = clone(m), {}
    for k, v in pairs(E) do e[k] = v end
    for k, v in pairs(extra or {}) do e[k] = v end
    local r = T:run{ fixture.posix_shell(), W.abs .. "/seed.sh", arg, cwd = c, env = e, timeout_ms = 60000 }
    return head(c), (r.stdout or "") .. (r.stderr or "")
end
local function has(s, w) return s:find(w, 1, true) ~= nil end

mirror("stray", "work/1325-ygq5", true, { "linux-next", "osx-next", "work/1325-ygq5" })
mirror("other", "main", true, { "linux-next", "osx-next", "work/9999-abcd" })
local b1, o1 = forge("stray", "resolve")
local b2 = forge("other", "resolve")
T:arm("1 CLOSURE mirrors with different HEADs both seed linux-next, and say why",
    b1 == "linux-next" and b2 == "linux-next" and has(o1, "[forge] Seed branch: 'linux-next' — the discipline seed's integration.forge"),
    "stray -> " .. b1 .. " other -> " .. b2 .. " out=" .. o1)

mirror("noseed", "work/1325-ygq5", false, { "linux-next", "work/1325-ygq5" })
local b, o = forge("noseed", "resolve")
T:arm("2 with no discipline seed, main by convention, named", b == "main" and has(o, "the remote default by convention (origin/main exists"), b .. " " .. o)

b, o = forge("stray", "resolve", { ARM_SEED = "osx-next" })
T:arm("3 an explicit TILLANDSIAS_FORGE_SEED_BRANCH wins", b == "osx-next", b .. " " .. o)

local d = W.abs .. "/src-nothing"
git("init", "-q", "-b", "work/x", d)
fs.write(W.rel .. "/src-nothing/f", "x\n")
git("-C", d, "add", "-A"); git("-C", d, "commit", "-q", "-m", "x")
git("clone", "-q", "--bare", d, W.abs .. "/nothing.git")
b, o = forge("nothing", "resolve")
T:arm("4 nothing resolvable is a loud warning naming the mirror's HEAD; the clone stays; rc 0",
    b == "work/x" and has(o, "WARNING: no seed branch could be resolved") and has(o, "MIRROR'S HEAD") and has(o, "rc=0"), b .. " " .. o)

b, o = forge("stray")
T:arm("5 HOST-MOUNT the call with no `resolve` does not switch the tree", b == "work/1325-ygq5" and not has(o, "Seed branch") and has(o, "rc=0"), b .. " " .. o)
b = head(clone("stray"))
T:arm("6 CONTROL an unseeded clone of that mirror lands on the stray work branch", b == "work/1325-ygq5", b)
T:finish()
