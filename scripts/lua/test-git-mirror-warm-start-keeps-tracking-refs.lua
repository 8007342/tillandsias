-- @env PATH
-- @trace order:1977-xpus, spec:git-mirror-service
--
-- test-git-mirror-warm-start-keeps-tracking-refs.lua — a warm mirror start
-- keeps the mirror's refs/remotes/origin/* tracking refs (1977-xpus).
--
-- MEASURED on yoga 2026-11-03: every warm forge launch waited 6.7-12 s on
-- `bringup: step=mirror-seed`, and the mirror log printed EVERY upstream branch
-- as "[new branch] ... -> origin/...". /srv/git is a persistent volume, but the
-- entrypoint ran `git remote remove origin` then `remote add` on every start,
-- and `git remote remove` deletes the remote's tracking refs.
--
-- The arms EXECUTE the real origin-setup block, cut out of
-- images/git/entrypoint.sh by its markers, over a scratch bare repo:
--   1 WARM      the same URL twice: refs/remotes/origin/main survives (red
--               before 1977-xpus: the second start deleted it)
--   2 CHANGED   a new URL: origin points at it, the refspec and --no-tags hold
--   3 FRESH     a repo with no origin gets one, with the refspec
--
-- Usage: tillandsias-plan script run scripts/lua/test-git-mirror-warm-start-keeps-tracking-refs.lua
-- Verdict: ok:git-mirror-warm-start-keeps-tracking-refs:<n> arms | violation:git-mirror-warm-start-keeps-tracking-refs:<n>-failed

local NAME = "git-mirror-warm-start-keeps-tracking-refs"
local ENTRY = "images/git/entrypoint.sh"
local passed, failed = 0, {}
local function arm(name, cond, got)
    if cond then
        passed = passed + 1
        out.line("ok:   " .. name)
    else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got))
        failed[#failed + 1] = name
    end
end

-- cut the origin-setup block: from its `if [ -n "$TILLANDSIAS_PROJECT_REMOTE_URL" ]`
-- to the matching four-space `fi`
local block, inside = {}, false
for _, l in ipairs(text.lines(fs.read(ENTRY) or "")) do
    if not inside and l:find('^    if %[ %-n "%$TILLANDSIAS_PROJECT_REMOTE_URL" %]; then') then inside = true end
    if inside then
        block[#block + 1] = l
        if l == "    fi" then break end
    end
end
local blk = table.concat(block, "\n")
arm("0 premise: the origin-setup block was cut and configures origin",
    #block > 3 and blk:find("origin", 1, true) ~= nil and block[#block] == "    fi", #block)

local root = text.trim(proc.run{ argv = { "pwd", "-P" } }.stdout or "")
local REL = "target/plan-scratch/mirror-warm-" .. tostring(time.now_ms())
local ABS = root .. "/" .. REL
fs.mkdir(REL)
fs.write(REL .. "/block.sh", blk .. "\n")
local ENV = { PATH = "/usr/bin:/bin", HOME = ABS, GIT_CONFIG_NOSYSTEM = "1" }

local function sh(script)
    fs.write(REL .. "/run.sh", "set -e\n" .. script .. "\n")
    return proc.run{ argv = { "/bin/bash", ABS .. "/run.sh" }, env = ENV, timeout_ms = 30000 }
end
-- one mirror start: the real block, with this URL
local function start(repo, url)
    return sh('PROJECT_REPO="' .. repo .. '"\nTILLANDSIAS_PROJECT_REMOTE_URL="' .. url .. '"\n. "' .. ABS .. '/block.sh"')
end
local function git(repo, ...)
    local argv = { "git", "-C", repo }
    for _, a in ipairs({ ... }) do argv[#argv + 1] = a end
    return proc.run{ argv = argv, env = ENV }
end

-- a bare repo with one commit, exported as heads/main and tracked as origin/main
local REPO = ABS .. "/mirror.git"
sh(table.concat({
    "export GIT_AUTHOR_NAME=f GIT_AUTHOR_EMAIL=f@example.invalid GIT_COMMITTER_NAME=f GIT_COMMITTER_EMAIL=f@example.invalid",
    "git init -q --bare " .. REPO,
    "git init -q " .. ABS .. "/work",
    "git -C " .. ABS .. "/work commit -q --allow-empty -m base",
    "git -C " .. ABS .. "/work push -q " .. REPO .. " HEAD:refs/heads/main",
}, "\n"))
local URL = "https://github.com/example/project.git"
start(REPO, URL)
local head = text.trim(git(REPO, "rev-parse", "refs/heads/main").stdout or "")
git(REPO, "update-ref", "refs/remotes/origin/main", head)

local r = start(REPO, URL)
local tracked = git(REPO, "rev-parse", "--verify", "-q", "refs/remotes/origin/main")
arm("1 WARM: a second start with the same URL keeps refs/remotes/origin/main",
    r.code == 0 and tracked.code == 0 and text.trim(tracked.stdout or "") == head,
    "rc=" .. tostring(r.code) .. " rev-parse rc=" .. tostring(tracked.code))

local URL2 = "https://github.com/example/renamed.git"
r = start(REPO, URL2)
local url_now = text.trim(git(REPO, "config", "remote.origin.url").stdout or "")
local refspec = text.trim(git(REPO, "config", "remote.origin.fetch").stdout or "")
local tagopt = text.trim(git(REPO, "config", "remote.origin.tagOpt").stdout or "")
arm("2 CHANGED: a new URL is set, with the tracking refspec and --no-tags",
    r.code == 0 and url_now == URL2 and refspec == "+refs/heads/*:refs/remotes/origin/*" and tagopt == "--no-tags",
    "url=" .. url_now .. " fetch=" .. refspec .. " tagOpt=" .. tagopt)

local FRESH = ABS .. "/fresh.git"
sh("git init -q --bare " .. FRESH)
r = start(FRESH, URL)
url_now = text.trim(git(FRESH, "config", "remote.origin.url").stdout or "")
refspec = text.trim(git(FRESH, "config", "remote.origin.fetch").stdout or "")
arm("3 FRESH: a repo with no origin gets one, with the refspec",
    r.code == 0 and url_now == URL and refspec == "+refs/heads/*:refs/remotes/origin/*",
    "url=" .. url_now .. " fetch=" .. refspec)

proc.run{ argv = { "rm", "-rf", ABS } }
if #failed > 0 then
    verdict.emit("violation:" .. NAME .. ":" .. #failed .. "-failed", 1)
else
    verdict.emit("ok:" .. NAME .. ":" .. passed .. " arms", 0)
end
