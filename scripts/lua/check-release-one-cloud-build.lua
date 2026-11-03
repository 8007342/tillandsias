-- @trace order:1950-b4f3, spec:ci-release
--
-- check-release-one-cloud-build.lua — a release is ONE cloud build: the
-- release workflow carries no GitHub Actions cache step and no seed input, and
-- the release skill dispatches it exactly once, on the tag.
--
-- WHY (measured on the five releases v56.10.20.1 .. v56.11.1.1, runs
-- 39495753986 41137103161 41212733409 41249590255 41283100284):
--   * the Nix cache restore step found nothing in 5/5 runs ("Could not find a
--     cache", 0-1 s) — GitHub scopes a cache to the ref that saved it and a
--     release runs on a fresh tag, so no tag can ever restore another's save;
--   * each tag run then SAVED a 3.3 GB store (49-87 s) that nothing could
--     read, three of them filling the 10 GB quota and evicting each other;
--   * the only producer whose save main-scoped restores could reach is a
--     second full build dispatched on main (the 1942-mijg cache_seed run): run
--     41352565247 spent 66 min cold-building before the operator cancelled
--     it. A warm-up that costs a whole build is not a cache, and it breaks the
--     one-cloud-build-per-day rule the operator set.
-- A cache that pays off needs a producer on main inside the one daily run
-- (the release dispatched on main, tagging from the workflow) or a substituter
-- that is not the Actions cache; that is a redesign, filed under 1950-b4f3,
-- not a flag. Until it lands, no cache step may sit in the release.
--
-- RULES (as amended by 1953-jmvb; see the comment at the first loop)
--   1. release.yml declares no `cache_seed` input, and no cache save is
--      scoped to a ref other than refs/heads/main;
--   2. every uncommented `gh workflow run release.yml` in the release skill
--      runs on main (`--ref main`), none on a tag or with a seed input.
--
-- GRAMMAR (exactly one line on stdout)
--   ok:release-one-cloud-build:main-dispatches=<n> cache-steps=<k>   exit 0
--   refused:release-one-cloud-build:<rule>=<detail>[,...]            exit 1
--   could-not-run:release-one-cloud-build:<reason>                   exit 3
--
-- Usage: tillandsias-plan script run scripts/lua/check-release-one-cloud-build.lua [-- <workflow.yml> [<release SKILL.md>]]
local wf = arg[1] or ".github/workflows/release.yml"
local ok, src = pcall(fs.read, wf)
if not ok or not src then verdict.emit("could-not-run:release-one-cloud-build:no-file:" .. wf, 3) end
local skill = arg[2] or "skills/merge-to-main-and-release/SKILL.md"
local sok, ssrc = pcall(fs.read, skill)
if not sok or not ssrc then verdict.emit("could-not-run:release-one-cloud-build:no-file:" .. skill, 3) end

local CACHE_ACTIONS = {
    "^nix%-community/cache%-nix%-action",
    "^[Ss]watinem/rust%-cache",
    "^actions/cache",
}

-- ORDER 1953-jmvb (operator ruling 2026-11-01: "start the release from
-- main"): the release is dispatched on refs/heads/main and the workflow tags
-- from there, so a cache step IS restorable by the next release and is
-- allowed again. What stays refused: a seed input (a second build) and, in
-- the workflow, a cache save that is scoped to anything but main (a `save:`
-- or `save-if:` that names another ref) — with the run on main a bare save
-- is main-scoped, so only an explicit non-main condition is a defect.
local bad, caches = {}, 0
local line_no = 0
for _, l in ipairs(text.lines(src)) do
    line_no = line_no + 1
    if not l:find("^%s*#") then
        if l:find("^%s+cache_seed:") then
            bad[#bad + 1] = "seed-input=cache_seed@line" .. line_no
        end
        local action = l:match("uses:%s*(%S+)")
        if action then
            for _, pat in ipairs(CACHE_ACTIONS) do
                if action:find(pat) then caches = caches + 1 end
            end
        end
        local save = l:match("^%s+save[%-if]*:%s*(.-)%s*$")
        if save and save:find("refs/") and not save:find("refs/heads/main") then
            bad[#bad + 1] = "cache-save-not-main@line" .. line_no
        end
    end
end

-- Every dispatch of release.yml the skill writes runs on main (`--ref main`)
-- and none carries a seed input; a dispatch on a tag or another ref is a run
-- whose caches and SAN are not main's. The failure-recovery note that tells
-- the operator to re-run the SAME main dispatch by hand is allowed.
local main_dispatches = 0
local sline = 0
for _, l in ipairs(text.lines(ssrc)) do
    sline = sline + 1
    if not l:find("^%s*#") then
        if l:find("gh workflow run release%.yml") then
            if l:find("%-%-ref main") and not l:find("cache_seed") then main_dispatches = main_dispatches + 1
            else bad[#bad + 1] = "dispatch-not-on-main@line" .. sline end
        elseif l:find("%-f%s+cache_seed") then
            bad[#bad + 1] = "seed-dispatch@line" .. sline
        end
    end
end
if main_dispatches == 0 then bad[#bad + 1] = "no-main-dispatch=" .. skill end

if #bad > 0 then verdict.emit("refused:release-one-cloud-build:" .. table.concat(bad, ","), 1) end
verdict.emit(("ok:release-one-cloud-build:main-dispatches=%d cache-steps=%d"):format(main_dispatches, caches), 0)
