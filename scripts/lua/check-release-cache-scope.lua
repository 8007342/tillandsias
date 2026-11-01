-- @trace order:1942-mijg, order:1916-nxcs, spec:ci-release
--
-- check-release-cache-scope.lua — a release workflow's caches are SAVED only
-- under main's ref, and main has a producer.
--
-- GitHub restores an Actions cache only from the run's own ref or the default
-- branch. Releases are dispatched on a fresh tag, so a cache a tag run saves is
-- restorable by nobody (gh cache list: refs/tags/v56.10.31.2, v56.11.1.1 —
-- each release cold-built ~499 derivations, 67 min on v56.11.1.1). Three
-- rules:
--   1. every cache save is scoped to main: cache-nix-action's `save:` and
--      rust-cache's `save-if:` must test github.ref == 'refs/heads/main'
--      (a bare `true` saves under the tag); an actions/cache step that saves
--      is refused outright (use actions/cache/restore + a scoped save);
--   2. main has a producer, without a trigger (litmus:github-actions-budget
--      forbids push and schedule): the release skill dispatches the
--      cache_seed run on main BEFORE it dispatches the tag.
--
-- GRAMMAR (exactly one line on stdout)
--   ok:release-cache-scope:<n> saves scoped to main               exit 0
--   refused:release-cache-scope:<rule>=<detail>[,...]              exit 1
--   could-not-run:release-cache-scope:<reason>                     exit 3
--
-- Usage: tillandsias-plan script run scripts/lua/check-release-cache-scope.lua [-- <workflow.yml> [<release SKILL.md>]]
local wf = arg[1] or ".github/workflows/release.yml"
local ok, src = pcall(fs.read, wf)
if not ok or not src then verdict.emit("could-not-run:release-cache-scope:no-file:" .. wf, 3) end
local skill = arg[2] or "skills/merge-to-main-and-release/SKILL.md"
local sok, ssrc = pcall(fs.read, skill)
if not sok or not ssrc then verdict.emit("could-not-run:release-cache-scope:no-file:" .. skill, 3) end

local MAIN = "github%.ref%s*==%s*'refs/heads/main'"
local bad, saves = {}, 0
local step, line_no = nil, 0

for _, l in ipairs(text.lines(src)) do
    line_no = line_no + 1
    if l:find("^%s*#") then goto continue end

    if l:find("^%s*%- name:") or l:find("^%s*%- uses:") then step = nil end
    do
        local action = l:match("uses:%s*(%S+)")
        if action then
            if action:find("^nix%-community/cache%-nix%-action@") then step = "nix"
            elseif action:find("^swatinem/rust%-cache@") or action:find("^Swatinem/rust%-cache@") then step = "rust"
            elseif action:find("^actions/cache@") or action:find("^actions/cache/save@") then
                bad[#bad + 1] = "unscoped-save=actions-cache@line" .. line_no
            end
        end
    end
    do
        local key, val
        if step == "nix" then val = l:match("^%s+save:%s*(.-)%s*$"); key = "save" end
        if step == "rust" then val = l:match("^%s+save%-if:%s*(.-)%s*$"); key = "save-if" end
        if val then
            saves = saves + 1
            if not val:find(MAIN) then
                bad[#bad + 1] = ("unscoped-save=%s-%s:%s@line%d"):format(step, key, val:gsub("%s", ""), line_no)
            end
        end
    end
    ::continue::
end

if saves == 0 then bad[#bad + 1] = "no-cache-save-found=" .. wf end
-- Rule 2: an uncommented dispatch of the seed on main, before the tag's.
do
    local seed, tag
    for i, l in ipairs(text.lines(ssrc)) do
        if not l:find("^%s*#") and l:find("gh workflow run release%.yml") then
            if l:find("%-%-ref main") and l:find("cache_seed=true") then seed = seed or i
            elseif l:find("new_tag") then tag = tag or i end
        end
    end
    if not seed then bad[#bad + 1] = "no-main-producer=" .. skill .. ":no-seed-dispatch-on-main"
    elseif tag and tag < seed then bad[#bad + 1] = "no-main-producer=seed-dispatched-after-the-tag" end
end
if #bad > 0 then verdict.emit("refused:release-cache-scope:" .. table.concat(bad, ","), 1) end
verdict.emit(("ok:release-cache-scope:%d saves scoped to main"):format(saves), 0)
