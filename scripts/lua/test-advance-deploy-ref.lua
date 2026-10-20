-- @trace order:1798-khw6, spec:observatorium-dashboard, spec:ci-release
-- @env PATH
--
-- test-advance-deploy-ref.lua — pin scripts/advance-deploy-ref.sh. The
-- observatorium deploys only when refs/heads/deploy/observatorium moves, and
-- the enclave mirror refuses any branch rewind (spec:git-mirror-service). Every
-- arm drives the REAL script against a REAL bare remote whose pre-receive
-- refuses deletions and non-fast-forward branch updates the way the mirror
-- does, then reads the remote back.
--   0 CONTROL    the fixture remote really refuses a rewind (else arm 3 is vacuous)
--   1 SEED       an absent ref receives the release commit itself
--   2 FORWARD    promoting a descendant fast-forwards to the exact commit
--   3 DEMOTE     demoting deploys the older tree WITHOUT rewinding: a restore
--                commit, first parent = the release, old tip an ancestor
--   4 SAME       re-promoting the deployed tree pushes nothing
--   5 RETURN     promoting again after a demotion deploys that tree
--   6 BAD-REF    only refs/heads/deploy/* is accepted
--   7 UNKNOWN    an unresolvable commit is refused and nothing moves
--   8 DRY-RUN    --dry-run reports and moves nothing
--   9 REFUSED    a refused push is named refused:deploy-ref-push-refused
--
-- core.hooksPath is GLOBAL in a forge and REPLACES hooks/ for receive-pack too,
-- so both scratch repositories pin it locally: unpinned, the bare remote runs
-- no pre-receive and every rewind "passes" (measured while writing this, the
-- same class as 889-twhe).
--
-- Usage: tillandsias-plan script run scripts/lua/test-advance-deploy-ref.lua

local NAME = "advance-deploy-ref"
local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.status ~= "exited" or top.code ~= 0 or ROOT == "" then
    verdict.could_not_run(NAME, "git rev-parse --show-toplevel did not answer")
end
local REL = "target/plan-scratch/advance-deploy-ref-" .. time.iso_utc() .. "-" .. tostring(math.random(100000, 999999))
local S = ROOT .. "/" .. REL
local ORIGIN, REPO, NOHOOKS = S .. "/origin.git", S .. "/repo", S .. "/nohooks"
local REF = "refs/heads/deploy/observatorium"

local failed = {}
local function arm(name, cond, got)
    got = tostring(got):gsub("\n", " | ")
    if cond then out.line("ok:   " .. name .. " — " .. got) else
        out.line("FAIL: " .. name .. " — got: " .. got)
        failed[#failed + 1] = name
    end
end
local function run(argv, cwd)
    local r = proc.run({ argv = argv, cwd = cwd or ROOT, timeout_ms = 60000 })
    return r.status == "exited" and r.code == 0, text.trim(r.stdout or ""), text.trim(r.stderr or "")
end
local function git(...)
    return run({ "git", "-C", REPO, "-c", "user.name=fixture", "-c", "user.email=fixture@invalid", ... })
end
local function must(ok_, what, err)
    if not ok_ then
        proc.run({ argv = { "rm", "-rf", S }, timeout_ms = 30000 })
        verdict.could_not_run(NAME, "fixture setup failed at " .. what .. ": " .. tostring(err))
    end
end

-- The mirror's rule: no deletion, no branch rewind.
local MIRROR_HOOK = table.concat({
    "#!/usr/bin/env bash",
    "while read -r old new ref; do",
    '    case "$new" in 0000000000000000000000000000000000000000) echo "refused: deletion" >&2; exit 1 ;; esac',
    '    case "$ref" in refs/heads/*) ;; *) continue ;; esac',
    '    case "$old" in 0000000000000000000000000000000000000000) continue ;; esac',
    '    git merge-base --is-ancestor "$old" "$new" || { echo "refused: rewind of $ref" >&2; exit 1; }',
    "done", "" }, "\n")

fs.mkdir(REL .. "/repo/scripts")
fs.mkdir(REL .. "/nohooks")
local okb, _, e = run({ "git", "init", "-q", "--bare", ORIGIN })
must(okb, "git init --bare", e)
fs.write(REL .. "/origin.git/hooks/pre-receive", MIRROR_HOOK)
must(run({ "chmod", "+x", ORIGIN .. "/hooks/pre-receive" }), "chmod pre-receive")
must(run({ "git", "-C", ORIGIN, "config", "core.hooksPath", ORIGIN .. "/hooks" }), "pin origin hooksPath")
fs.write(REL .. "/repo/scripts/advance-deploy-ref.sh", fs.read("scripts/advance-deploy-ref.sh"))
must(run({ "git", "init", "-q", "-b", "main", REPO }), "git init repo")
must(git("config", "core.hooksPath", NOHOOKS), "pin repo hooksPath")
must(git("remote", "add", "origin", ORIGIN), "remote add")
for v = 1, 3 do
    fs.write(REL .. "/repo/observatorium.txt", "release " .. v .. "\n")
    must(git("add", "-A"), "add " .. v)
    must(git("commit", "-q", "-m", "release " .. v), "commit " .. v)
    must(git("tag", "v" .. v), "tag " .. v)
end
local okp, _, ep = git("push", "-q", "origin", "main", "--tags")
must(okp, "seed push", ep)

local function adv(...)
    local r = proc.run({ argv = { "bash", REPO .. "/scripts/advance-deploy-ref.sh", ... }, cwd = REPO, timeout_ms = 60000 })
    local lines = {}
    for l in ((r.stdout or "") .. "\n"):gmatch("(.-)\n") do if l ~= "" then lines[#lines + 1] = l end end
    return lines[#lines] or "", text.trim(r.stderr or "")
end
local function remote_tip()
    local _, o = git("ls-remote", "origin", REF)
    return (o:match("^(%x+)") or "")
end
local function rev(x) local _, o = git("rev-parse", x) return o end
local function remote_tree()
    local tip = remote_tip()
    if tip == "" then return "" end
    git("fetch", "-q", "origin", REF)
    return rev(tip .. "^{tree}")
end
local function is_ancestor(a, b) return (git("merge-base", "--is-ancestor", a, b)) end

-- 0 CONTROL
git("push", "-q", "origin", "v2:refs/heads/rewind-probe")
local rewound = git("push", "-q", "origin", "v1:refs/heads/rewind-probe")
if rewound then
    proc.run({ argv = { "rm", "-rf", S }, timeout_ms = 30000 })
    verdict.could_not_run(NAME, "the fixture remote accepted a rewind; its pre-receive is not running")
end
arm("0 CONTROL the fixture remote refuses a branch rewind", true, "rewind refused")

local o, err = adv("v2", "--label", "v2")
arm("1 SEED an absent ref receives the release commit itself",
    o:match("^verified:deploy%-ref:") ~= nil and remote_tip() == rev("v2^{commit}"), o .. " " .. err)

o, err = adv("v3", "--label", "v3")
arm("2 FORWARD promoting a descendant fast-forwards to the exact commit",
    o:find("verified:deploy-ref:" .. rev("v3^{commit}"), 1, true) == 1 and remote_tip() == rev("v3^{commit}"), o .. " " .. err)

local before = remote_tip()
o, err = adv("v2", "--label", "v2")
local tip = remote_tip()
arm("3 DEMOTE deploys v2's exact tree without rewinding (first parent = v2)",
    o:match("^verified:deploy%-ref:") ~= nil and tip ~= before and remote_tree() == rev("v2^{tree}")
    and is_ancestor(before, tip) and rev(tip .. "^1") == rev("v2^{commit}"), o .. " " .. err)

before = remote_tip()
o, err = adv("v2", "--label", "v2")
arm("4 SAME re-promoting the deployed tree pushes nothing",
    o:find("verified:deploy-ref:" .. before, 1, true) == 1 and remote_tip() == before, o .. " " .. err)

o, err = adv("v3", "--label", "v3")
arm("5 RETURN promoting v3 after the demotion deploys v3's tree",
    o:match("^verified:deploy%-ref:") ~= nil and remote_tree() == rev("v3^{tree}"), o .. " " .. err)

o = adv("v3", "--ref", "refs/heads/main")
arm("6 BAD-REF a non-deploy ref is refused", o == "refused:deploy-ref-bad-ref:refs/heads/main", o)

before = remote_tip()
o = adv("no-such-release")
arm("7 UNKNOWN an unresolvable commit is refused and nothing moves",
    o:match("^refused:deploy%-ref%-unresolvable:") ~= nil and remote_tip() == before, o)

before = remote_tip()
o = adv("v1", "--dry-run")
arm("8 DRY-RUN reports and moves nothing", o == "would-advance:deploy-ref:" .. REF .. ":v1" and remote_tip() == before, o)

fs.write(REL .. "/origin.git/hooks/pre-receive", "#!/usr/bin/env bash\necho 'refused: closed' >&2; exit 1\n")
run({ "chmod", "+x", ORIGIN .. "/hooks/pre-receive" })   -- fs.write does not keep the mode
o = adv("v1", "--label", "v1")
arm("9 REFUSED a refused push is named", o:match("^refused:deploy%-ref%-push%-refused:") ~= nil, o)

proc.run({ argv = { "rm", "-rf", S }, timeout_ms = 30000 })
if #failed > 0 then
    verdict.emit("violation:" .. NAME .. ":" .. #failed .. "-failed", 1)
end
verdict.ok(NAME, "10 arms")
