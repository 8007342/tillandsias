-- @env TILLANDSIAS_PROVENANCE_REPO TILLANDSIAS_PROVENANCE_REF
-- @trace order:1315-4a7j, spec:ci-release
--
-- check-landing-provenance.lua — HOW DOES INTEGRATION ACTUALLY ARRIVE?
-- Ported from scripts/check-landing-provenance.sh, the shell-to-lua item the
-- 667-kfyn change carried; same classification, window, output and exits.
--
-- WHY THIS EXISTS AND WHY IT IS NOT A GUARD. 1315-4a7j opens work/<order> as the
-- ungated lane a host commits and pushes to, and the operator was explicit that
-- this phase is MIGRATION, NOT ENFORCEMENT: "adding new hard rules would make a
-- bunch of agents crash and suddenly start failing hard on ways they already
-- know how to work". Nothing new refuses. The preferred workflow arrives as
-- affordances, and enforcement becomes a later, operator-triggered decision.
--
-- THE TRIGGER IS A NUMBER, WHICH IS WHAT THIS PRINTS. When queue landings are
-- the majority of CODE landings for a week, the operator can flip to
-- enforcement on measured behaviour rather than on a preference — and, just as
-- importantly, can see if they are NOT the majority and know the migration has
-- not taken.
--
-- IT REFUSES NOTHING, EVER. Exit 0 on every classification; the only non-zero
-- exits are "I could not look" (no repo, no ref), which must not read as "the
-- fleet is behaving".
--
--   landing-provenance:<window>:queue=<n> plan=<n> relay=<n> direct=<n>
--
-- CLASSIFICATION IS BY FIRST PARENT, deliberately. Walking every commit would
-- count the contents of a merged branch as separate landings and inflate
-- whichever lane the author happened to commit in; the first-parent walk counts
-- INTEGRATION EVENTS, which is the question.
--
--   tillandsias-plan script run scripts/lua/check-landing-provenance.lua -- [<window>]

local function getenv(name)
    local v = env.get(name)
    if v == nil or v == "" then return nil end
    return v
end

-- TILLANDSIAS_PROVENANCE_REPO is the test seam. Without it this runs in its OWN
-- checkout, so a fixture that runs it from a scaffold repository silently
-- measures the real fleet history instead — which is what the first version of
-- arm 5 did, reporting direct=766 for a four-commit scaffold.
local REPO = getenv("TILLANDSIAS_PROVENANCE_REPO")
local WINDOW = (arg and arg[1] and arg[1] ~= "") and arg[1] or "7.days"
local REF = getenv("TILLANDSIAS_PROVENANCE_REF") or "origin/linux-next"

local function git(args)
    local argv = { "git" }
    if REPO then argv[#argv + 1] = "-C"; argv[#argv + 1] = REPO end
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local r = proc.run({ argv = argv, timeout_ms = 120000 })
    return r.status == "exited" and r.code == 0, r.stdout or ""
end

if REPO and not git({ "rev-parse", "--git-dir" }) then
    verdict.emit("blocked:landing-provenance:not-a-git-repo", 2)
end
if not git({ "rev-parse", "--verify", "--quiet", REF }) then
    verdict.emit("blocked:landing-provenance:no-ref:" .. REF, 2)
end

local queue, plan, relay, direct = 0, 0, 0, 0
local function starts(s, p) return s:sub(1, #p) == p end

local _, log = git({ "log", "--first-parent", "--since=" .. WINDOW, "--format=%H%x09%s", REF })
for _, line in ipairs(text.lines(log)) do
    local sha, subj = line:match("^(%x+)\t?(.*)$")
    if sha then
        -- A PR merge is the queue's signature. GitHub writes "Merge pull request
        -- #<n>", and the landing queue's own merges name the work ref they took.
        if starts(subj, "Merge pull request ") or subj:find("from work/", 1, true)
            or starts(subj, "land(") or starts(subj, "queue(") then
            queue = queue + 1
        -- A relay is a platform branch carrying another branch's work across.
        elseif starts(subj, "relay(") or starts(subj, "Merge remote-tracking branch ") then
            relay = relay + 1
        else
            -- PLAN-ONLY IS DECIDED BY CONTENT, NOT BY SUBJECT. A commit whose
            -- every changed path is under plan/ is the fragment lane whatever it
            -- calls itself, and a commit that merely SAYS plan( ) while touching
            -- scripts/ is not. The subject is the author's claim; the paths are
            -- what happened.
            local _, names = git({ "show", "--first-parent", "--name-only", "--format=", sha })
            local changed, nonplan = 0, 0
            for _, p in ipairs(text.lines(names)) do
                if p ~= "" then
                    changed = changed + 1
                    if not starts(p, "plan/") then nonplan = nonplan + 1 end
                end
            end
            if changed > 0 and nonplan == 0 then plan = plan + 1 else direct = direct + 1 end
        end
    end
end

out.line(string.format("landing-provenance:%s:queue=%d plan=%d relay=%d direct=%d", WINDOW, queue, plan, relay, direct))

-- THE READING RULE, PRINTED WITH THE NUMBER so it cannot be applied after the
-- fact to whatever the number turned out to be (the "publish the reading rule
-- before the measurement" discipline). Code landings are queue + direct: plan
-- fragments do not race and relays are a platform branch's own traffic, so
-- neither belongs in the ratio the flip depends on.
local code = queue + direct
if code > 0 then
    out.line(string.format("  code landings: queue=%d direct=%d of %d — the flip to enforcement wants queue > direct, sustained for a week", queue, direct, code))
else
    out.line("  code landings: none in this window — the ratio is undefined, which is not the same as favourable")
end
-- The runner reads only an explicit verdict as green (1384-bqhy); the counts
-- stay on the first line, where the shell version printed them.
verdict.emit("ok:landing-provenance:" .. WINDOW, 0)
