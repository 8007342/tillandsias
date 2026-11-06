-- @trace order:2005-ccli
-- @env PATH
--
-- test-tillandsias-cache.lua — the forge's stage cache (2005-ccli slice 1),
-- run against a second project that is neither tillandsias nor kumbia: a
-- static site whose "thumbs" stage renders page thumbnails.
--   1 MISS      an empty cache answers hit:false, exit 1 (never a fake hit)
--   2 PUT       put stores the file and names the key and path
--   3 KEY       the key is sha256 of the canonical JSON (sorted, compact),
--               so reordered inputs hit the same entry
--   4 IDEMP     a second put of the same inputs stores nothing new
--   5 GET-OUT   get --out-dir copies the stored file out, bytes intact
--   6 NARROW    changed inputs miss
--   7 DUP       duplicate keys refuse cache_inputs_not_canonical, exit 2
--   8 NAN       NaN refuses cache_inputs_not_canonical
--   9 QUOTA     a put over the quota refuses cache_over_quota, stores nothing
--  10 PARTIAL   an entry dir without .inputs.json (an interrupted put) and a
--               .tmp- sibling are not hits, and stats does not count them
--  11 PROV      a provenance that is not tillandsias.provenance/v1 refuses
--  12 STATS     stats counts entries and bytes
--  13 PRUNE     prune keeps referenced keys, removes the rest and temporaries
--  14 NOCACHE   with no project cache: refused no_project_cache, exit 2
--  15 HELP      --help answers the usage, exit 0
-- Red before 2005-ccli: the tool did not exist.
--
-- Usage: tillandsias-plan script run scripts/lua/test-tillandsias-cache.lua

local TOOL = "images/default/cli/tillandsias-cache"
if not fs.exists(TOOL) then
    verdict.emit("violation:tillandsias-cache:no-subject", 1, TOOL .. " does not exist")
end
local py = proc.run({ argv = { "python3", "-c", "print(1)" }, timeout_ms = 30000 })
if py.status ~= "exited" or py.code ~= 0 then
    verdict.could_not_run("tillandsias-cache", "python3 is not available on this host")
end

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.status ~= "exited" or top.code ~= 0 or ROOT == "" then
    verdict.could_not_run("tillandsias-cache", "git rev-parse --show-toplevel did not answer")
end
local REL = "target/plan-scratch/tc" .. tostring(math.random(100000, 999999))
fs.mkdir(REL .. "/project-cache")
fs.mkdir(REL .. "/site")
local DIR = ROOT .. "/" .. REL
local PC = DIR .. "/project-cache"

local failed, passed = {}, 0
local function arm(name, cond, got)
    got = got and tostring(got):gsub("\n", " | ") or nil
    if cond then
        passed = passed + 1
        out.line("ok:   " .. name)
    else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got))
        failed[#failed + 1] = name
    end
end
local function has(s, needle) return (s or ""):find(needle, 1, true) ~= nil end

local function run(args, extra)
    local envt = { PATH = env.get("PATH") or "/usr/bin:/bin", HOME = DIR .. "/home", TILLANDSIAS_PROJECT_CACHE = PC }
    for k, v in pairs(extra or {}) do envt[k] = v end
    local argv = { "python3", ROOT .. "/" .. TOOL }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local r = proc.run({ argv = argv, env = envt, timeout_ms = 60000 })
    return r.code, r.stdout or "", r.stderr or ""
end
local function field(s, name)
    return s:match('"' .. name .. '": "([^"]*)"')
end

fs.write(REL .. "/site/about.png", "PNG-about-320\n")
fs.write(REL .. "/in.json", '{"page":"about.md","width":320,"theme":"plain"}')
fs.write(REL .. "/in-reordered.json", '{"theme":"plain","width":320,"page":"about.md"}')
fs.write(REL .. "/in-wider.json", '{"page":"about.md","width":640,"theme":"plain"}')
fs.write(REL .. "/in-dup.json", '{"page":"a.md","page":"b.md"}')
fs.write(REL .. "/in-nan.json", '{"width":NaN}')
fs.write(REL .. "/in-big.json", '{"page":"big.md"}')
fs.write(REL .. "/prov-bad.json", '{"schema":"kumbia.sidecar/0"}')

local IN, SITE = DIR .. "/in.json", DIR .. "/site/about.png"

local c, o, e = run({ "get", "--stage", "thumbs", "--inputs", IN })
arm("1 MISS empty cache answers hit:false exit 1", c == 1 and has(o, '"hit": false'), c .. " " .. o .. e)

c, o, e = run({ "put", "--stage", "thumbs", "--inputs", IN, "--file", SITE })
local key = field(o, "key") or ""
arm("2 PUT stores and names key and path", c == 0 and has(o, '"stored": true') and #key == 64
    and fs.exists(REL .. "/project-cache/stage-cache/thumbs/" .. key .. "/about.png"), c .. " " .. o .. e)

local want = proc.run({ argv = { "python3", "-c",
    "import hashlib,json;print(hashlib.sha256(json.dumps({'page':'about.md','width':320,'theme':'plain'},sort_keys=True,separators=(',',':')).encode()).hexdigest())" },
    timeout_ms = 30000 })
c, o, e = run({ "get", "--stage", "thumbs", "--inputs", DIR .. "/in-reordered.json" })
arm("3 KEY canonical sha256; reordered inputs hit", text.trim(want.stdout or "") == key and c == 0
    and has(o, '"hit": true') and field(o, "key") == key, key .. " " .. c .. " " .. o .. e)

c, o, e = run({ "put", "--stage", "thumbs", "--inputs", DIR .. "/in-reordered.json", "--file", SITE })
arm("4 IDEMP a repeat put stores nothing new", c == 0 and has(o, '"stored": false') and field(o, "key") == key, o .. e)

c, o, e = run({ "get", "--stage", "thumbs", "--key", key, "--out-dir", DIR .. "/out" })
arm("5 GET-OUT copies the file out intact", c == 0 and fs.read(REL .. "/out/about.png") == "PNG-about-320\n", o .. e)

c, o, e = run({ "get", "--stage", "thumbs", "--inputs", DIR .. "/in-wider.json" })
arm("6 NARROW changed inputs miss", c == 1 and has(o, '"hit": false'), c .. " " .. o)

c, o, e = run({ "put", "--stage", "thumbs", "--inputs", DIR .. "/in-dup.json", "--file", SITE })
arm("7 DUP refuses cache_inputs_not_canonical", c == 2 and has(e, "refused:tillandsias-cache:cache_inputs_not_canonical"), c .. " " .. e)

c, o, e = run({ "put", "--stage", "thumbs", "--inputs", DIR .. "/in-nan.json", "--file", SITE })
arm("8 NAN refuses cache_inputs_not_canonical", c == 2 and has(e, "cache_inputs_not_canonical"), c .. " " .. e)

c, o, e = run({ "put", "--stage", "thumbs", "--inputs", DIR .. "/in-big.json", "--file", SITE },
    { TILLANDSIAS_STAGE_CACHE_QUOTA = "20" })
local c2, o2 = run({ "get", "--stage", "thumbs", "--inputs", DIR .. "/in-big.json" })
arm("9 QUOTA refuses cache_over_quota and stores nothing", c == 2 and has(e, "cache_over_quota") and c2 == 1, c .. " " .. e .. " " .. o2)

local fake = string.rep("a", 64)
fs.mkdir(REL .. "/project-cache/stage-cache/thumbs/" .. fake)
fs.write(REL .. "/project-cache/stage-cache/thumbs/" .. fake .. "/half.png", "half")
fs.mkdir(REL .. "/project-cache/stage-cache/thumbs/.tmp-" .. string.rep("b", 64) .. "-1")
c, o = run({ "get", "--stage", "thumbs", "--key", fake })
local _, so = run({ "stats" })
arm("10 PARTIAL an unfinished entry is no hit and is not counted", c == 1 and has(so, '"entries": 1'), c .. " " .. o .. " " .. so)

c, o, e = run({ "put", "--stage", "thumbs", "--inputs", DIR .. "/in-wider.json", "--file", SITE, "--provenance", DIR .. "/prov-bad.json" })
arm("11 PROV a non-v1 sidecar refuses provenance_not_v1", c == 2 and has(e, "provenance_not_v1"), c .. " " .. e)

_, so = run({ "stats", "--stage", "thumbs" })
arm("12 STATS counts entries and bytes", has(so, '"entries": 1') and not has(so, '"bytes": 0,'), so)

fs.write(REL .. "/keep.txt", key .. "\n")
run({ "put", "--stage", "thumbs", "--inputs", DIR .. "/in-wider.json", "--file", SITE })
c, o = run({ "prune", "--older-than", "0", "--keep-referenced-by", DIR .. "/keep.txt" })
local c3 = run({ "get", "--stage", "thumbs", "--key", key })
arm("13 PRUNE keeps referenced keys, removes the rest and temporaries", c == 0 and has(o, '"removed": 1') and c3 == 0
    and not fs.exists(REL .. "/project-cache/stage-cache/thumbs/.tmp-" .. string.rep("b", 64) .. "-1"), c .. " " .. o)

c, o, e = run({ "stats" }, { TILLANDSIAS_PROJECT_CACHE = DIR .. "/no-such-cache" })
arm("14 NOCACHE refuses no_project_cache, exit 2, no empty answer", c == 2 and o == "" and has(e, "no_project_cache"), c .. " " .. o .. e)

c, o = run({ "--help" })
arm("15 HELP answers the usage", c == 0 and has(o, "Usage: tillandsias-cache"), c .. " " .. o)

proc.run({ argv = { "rm", "-rf", DIR }, timeout_ms = 30000 })
if #failed > 0 then
    verdict.emit("violation:tillandsias-cache:" .. table.concat(failed, ","), 1, passed .. " passed")
end
verdict.ok("tillandsias-cache", passed .. " arms")
