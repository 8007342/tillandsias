-- @trace order:835-h2wq, order:2049-ndde, spec:default-image
-- @class observing
--
-- ledger-freshness.lua — the body of images/default/lib-ledger-freshness.sh,
-- run by `tillandsias-plan script run --helper` (openspec change
-- forge-lua-helpers D3.3). Three git reads through proc.run replace the
-- for-each-ref | while-read pipeline.
--
-- Argument: the project directory.
-- Output, three lines in this order, never an empty line:
--   1 head     short HEAD sha, or unknown
--   2 lag_h    whole hours the newest origin head is ahead of HEAD's commit
--              time; 0 when current, equal, or unknowable (never negative)
--   3 newest   the origin/<branch> holding that commit, prefix stripped, or unknown
--
-- Environment (2029-39bt): git runs from the base environment, which keeps
-- HOME (so a global safe.directory still applies) and sets
-- GIT_TERMINAL_PROMPT=0. The checkout is an argument (-C), never GIT_DIR.

local dir = arg[1] or ""
local head, lag, newest = "unknown", 0, "unknown"

local function git(args)
    local argv = { "git", "-C", dir }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local r = proc.run{ argv = argv, timeout_ms = 10000 }
    if r.status ~= "exited" or r.code ~= 0 then return nil end
    return r.stdout or ""
end

-- The .sh already checked the directory; fs.* is confined to the repo root
-- and the project may live anywhere, so git -C is the only reader here.
if dir ~= "" then
    local sha = text.trim(git({ "rev-parse", "--short", "HEAD" }) or "")
    if sha ~= "" then head = sha end
    local head_ts = tonumber(text.trim(git({ "log", "-1", "--format=%ct" }) or ""))
    local refs = git({ "for-each-ref", "refs/remotes/origin", "--sort=-committerdate",
        "--format=%(refname:short) %(committerdate:unix)" }) or ""
    for _, l in ipairs(text.lines(refs)) do
        local ref, ts = l:match("^(%S+) (%d+)$")
        -- origin/HEAD (short name: bare `origin`) duplicates the branch it
        -- points at and must not shadow the real newest branch's NAME.
        if ref and ref ~= "origin" and ref ~= "origin/HEAD" then
            newest = ref:gsub("^origin/", "")
            local nts = tonumber(ts)
            if head_ts and nts and nts > head_ts then lag = (nts - head_ts) // 3600 end
            break
        end
    end
end

print(head)
print(tostring(math.floor(lag)))
print(newest)
