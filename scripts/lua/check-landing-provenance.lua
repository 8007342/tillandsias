-- @env TILLANDSIAS_PROVENANCE_REPO TILLANDSIAS_PROVENANCE_REF
-- @read-env TILLANDSIAS_PROVENANCE_REPO TILLANDSIAS_PROVENANCE_REF
-- @trace order:1315-4a7j, spec:ci-release
--
-- check-landing-provenance.lua — PORTED from check-landing-provenance.sh
-- (1118-fqfk carry). HOW DOES INTEGRATION ACTUALLY ARRIVE?
--
-- WHY THIS EXISTS AND WHY IT IS NOT A GUARD. 1315-4a7j opens work/<order> as the
-- ungated lane a host commits and pushes to, and the operator was explicit that
-- this phase is MIGRATION, NOT ENFORCEMENT: "adding new hard rules would make a
-- bunch of agents crash and suddenly start failing hard on ways they already
-- know how to work". Nothing new refuses; the preferred workflow arrives as
-- affordances, and enforcement is a later, operator-triggered decision.
--
-- THE TRIGGER IS A NUMBER, WHICH IS WHAT THIS PRINTS. When queue landings are
-- the majority of CODE landings for a week, the operator can flip to
-- enforcement on measured behaviour, and can see when the migration has not
-- taken.
--
-- IT REFUSES NOTHING, EVER. Exit 0 on every classification; the only non-zero
-- exits are "I could not look" (no repo, no ref), which must not read as "the
-- fleet is behaving".
--
--   landing-provenance:<window>:queue=<n> plan=<n> relay=<n> direct=<n>
--
-- CLASSIFICATION IS BY FIRST PARENT, deliberately: the first-parent walk counts
-- INTEGRATION EVENTS, not the contents of a merged branch.
--
-- TILLANDSIAS_PROVENANCE_REPO is the test seam; without it this reads the
-- checkout it runs in (the runner's cwd, the repo root). The REF names trunk's
-- own history, not a diff base (see test-gate-diff-base-frozen.lua).
--
-- Usage: tillandsias-plan script run scripts/lua/check-landing-provenance.lua [-- <window>]

local repo = env.get("TILLANDSIAS_PROVENANCE_REPO") or "."
local window = arg[1] or "7.days"
local ref = env.get("TILLANDSIAS_PROVENANCE_REF") or "origin/linux-next"

local function git(args)
    local argv = { "git", "-C", repo }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    return proc.run{ argv = argv }
end

if git({ "rev-parse", "--git-dir" }).code ~= 0 then
    out.line("blocked:landing-provenance:not-a-git-repo")
    verdict.emit("could-not-run:landing-provenance:not-a-git-repo", 2)
end
if git({ "rev-parse", "--verify", ref }).code ~= 0 then
    out.line("blocked:landing-provenance:no-ref:" .. ref)
    verdict.emit("could-not-run:landing-provenance:no-ref", 2)
end

local function starts(s, p) return s:sub(1, #p) == p end

local queue, plan, relay, direct = 0, 0, 0, 0
local log_r = git({ "log", "--first-parent", "--since=" .. window, "--format=%H%x09%s", ref })
for _, line in ipairs(text.lines(log_r.stdout or "")) do
    local sha, subj = line:match("^(%x+)\t?(.*)$")
    if sha then
        subj = subj or ""
        -- A PR merge is the queue's signature; the queue's own merges name the
        -- work ref they took.
        if starts(subj, "Merge pull request ") or subj:find("from work/", 1, true)
                or starts(subj, "land(") or starts(subj, "queue(") then
            queue = queue + 1
        -- A relay is a platform branch carrying another branch's work across.
        elseif starts(subj, "relay(") or starts(subj, "Merge remote-tracking branch ") then
            relay = relay + 1
        else
            -- PLAN-ONLY IS DECIDED BY CONTENT, NOT BY SUBJECT: every changed
            -- path under plan/ is the fragment lane, whatever it calls itself.
            local names = git({ "show", "--first-parent", "--name-only", "--format=", sha }).stdout or ""
            local changed, nonplan = 0, 0
            for _, n in ipairs(text.lines(names)) do
                if n ~= "" then
                    changed = changed + 1
                    if not starts(n, "plan/") then nonplan = nonplan + 1 end
                end
            end
            if changed > 0 and nonplan == 0 then
                plan = plan + 1
            else
                direct = direct + 1
            end
        end
    end
end

out.line(("landing-provenance:%s:queue=%d plan=%d relay=%d direct=%d"):format(window, queue, plan, relay, direct))
-- THE READING RULE, PRINTED WITH THE NUMBER so it cannot be applied after the
-- fact. Code landings are queue + direct: plan fragments do not race and relays
-- are a platform branch's own traffic.
local code = queue + direct
if code > 0 then
    out.line(("  code landings: queue=%d direct=%d of %d — the flip to enforcement wants queue > direct, sustained for a week"):format(queue, direct, code))
else
    out.line("  code landings: none in this window — the ratio is undefined, which is not the same as favourable")
end
verdict.emit("ok:landing-provenance:" .. window, 0)
