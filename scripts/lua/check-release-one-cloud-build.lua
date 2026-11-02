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
-- RULES
--   1. release.yml declares no `cache_seed` input and uses none of
--      nix-community/cache-nix-action, swatinem/rust-cache, actions/cache*;
--   2. every uncommented `gh workflow run release.yml` in the release skill
--      runs on the tag (`new_tag`), none on another ref or with a seed input.
--
-- GRAMMAR (exactly one line on stdout)
--   ok:release-one-cloud-build:tag-dispatches=<n> cache-steps=0      exit 0
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
                if action:find(pat) then
                    caches = caches + 1
                    bad[#bad + 1] = "cache-step=" .. action:gsub("@.*", "") .. "@line" .. line_no
                end
            end
        end
    end
end

-- Every dispatch of release.yml the skill writes runs on the tag (`new_tag`);
-- a dispatch on any other ref (`--ref main`) or carrying a seed input is a
-- second cloud build. The failure-recovery note that tells the operator to
-- re-run the SAME tag dispatch by hand is a tag dispatch too, and allowed.
local tag_dispatches, other = 0, 0
local sline = 0
for _, l in ipairs(text.lines(ssrc)) do
    sline = sline + 1
    if not l:find("^%s*#") then
        if l:find("gh workflow run release%.yml") then
            if l:find("new_tag") and not l:find("cache_seed") then tag_dispatches = tag_dispatches + 1
            else other = other + 1; bad[#bad + 1] = "dispatch-not-on-tag@line" .. sline end
        elseif l:find("cache_seed") and l:find("%-f%s+cache_seed") then
            bad[#bad + 1] = "seed-dispatch@line" .. sline
        end
    end
end
if tag_dispatches == 0 then bad[#bad + 1] = "no-tag-dispatch=" .. skill end

if #bad > 0 then verdict.emit("refused:release-one-cloud-build:" .. table.concat(bad, ","), 1) end
verdict.emit(("ok:release-one-cloud-build:tag-dispatches=%d cache-steps=%d"):format(tag_dispatches, caches), 0)
