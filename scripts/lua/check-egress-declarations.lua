-- @trace spec:proxy-container, order:2041-jb57
-- @env TILLANDSIAS_IMAGES_DIR
-- @env TILLANDSIAS_STUDIO_REGISTRY_JSON
--
-- check-egress-declarations.lua — every image and every studio declares its
-- egress tiers, and every tier it names is on the ladder.
--
-- curated-egress-tiers: a container reaches only what its tiers allow, and an
-- undeclared one gets none. That default is only safe if a missing
-- declaration is caught here rather than discovered as a broken container,
-- so this decider refuses:
--   * an images/<dir> holding a Containerfile* but no egress.yaml;
--   * an egress.yaml without a `tiers: [...]` line or a `reason:` line;
--   * a tier name that is not on the ladder;
--   * `none` or `egress-point` combined with another tier;
--   * `egress-point` on anything but the containers that ARE an egress
--     (the proxy and the WARP sidecar);
--   * a studio in the registry whose `egress` is missing or names a bad tier.
--
-- Verdict grammar, one line on stdout:
--   ok:egress-declarations:<n> images,<m> studios                  exit 0
--   violation:egress-declarations:<what>[,<what>]                  exit 1
--   blocked:egress-declarations:<file>-unreadable                  exit 2

local IMAGES = env.get("TILLANDSIAS_IMAGES_DIR") or "images"
local REGISTRY = env.get("TILLANDSIAS_STUDIO_REGISTRY_JSON") or "crates/tillandsias-headless/data/studios.json"

local LADDER = {
    none = true, siblings = true, host = true, registries = true, assets = true,
    providers = true, ["model-hubs"] = true, vcs = true, research = true,
    ["egress-point"] = true,
}
local EGRESS_POINTS = { proxy = true, warp = true }
local ALONE = { none = true, ["egress-point"] = true }

local bad = {}
local function refuse(what) bad[#bad + 1] = what end

-- Judge one tier list; `who` names it in the verdict.
local function judge(who, tiers, image_dir)
    if #tiers == 0 then refuse(who .. ":no-tiers") return end
    for _, t in ipairs(tiers) do
        if not LADDER[t] then
            refuse(who .. ":unknown-tier:" .. t)
        elseif ALONE[t] and #tiers > 1 then
            refuse(who .. ":" .. t .. "-not-alone")
        elseif t == "egress-point" and not EGRESS_POINTS[image_dir or ""] then
            refuse(who .. ":egress-point-not-an-egress")
        end
    end
end

-- The image directories: those holding a Containerfile or Containerfile.<x>.
local dirs = {}
for _, path in ipairs(fs.walk(IMAGES) or {}) do
    local d, file = path:match("^" .. IMAGES:gsub("%p", "%%%0") .. "/([^/]+)/([^/]+)$")
    if d and file:match("^Containerfile") then dirs[d] = true end
end

local images = 0
local names = {}
for d in pairs(dirs) do names[#names + 1] = d end
table.sort(names)
for _, d in ipairs(names) do
    images = images + 1
    local path = IMAGES .. "/" .. d .. "/egress.yaml"
    local text = fs.exists(path) and fs.read(path) or nil
    if not text then
        refuse(d .. ":undeclared")
    else
        local list = text:match("\ntiers:%s*%[([^%]]*)%]") or text:match("^tiers:%s*%[([^%]]*)%]")
        if not list then
            refuse(d .. ":no-tiers-line")
        else
            local tiers = {}
            for t in list:gmatch("[^,%s]+") do tiers[#tiers + 1] = t end
            judge(d, tiers, d)
        end
        if not (text:match("\nreason:%s*%S") or text:match("^reason:%s*%S")) then
            refuse(d .. ":no-reason")
        end
    end
end

local studios = 0
local reg_text = fs.exists(REGISTRY) and fs.read(REGISTRY) or nil
if not reg_text then
    verdict.emit("blocked:egress-declarations:" .. REGISTRY .. "-unreadable", 2)
end
local reg = json.parse(reg_text)
for i, s in ipairs((reg and reg.studios) or {}) do
    studios = studios + 1
    local who = "studio:" .. tostring(s.id or i)
    if type(s.egress) ~= "table" then
        refuse(who .. ":undeclared")
    else
        judge(who, s.egress, nil)
    end
end

if #bad > 0 then
    verdict.emit("violation:egress-declarations:" .. table.concat(bad, ","), 1)
end
verdict.emit(string.format("ok:egress-declarations:%d images,%d studios", images, studios), 0)
