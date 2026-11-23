-- @trace order:2118-asur
-- @env TILLANDSIAS_PLAN_BIN PATH HOME
--
-- test-merge-floor-min.lua — litmus:floor-merge-driver-merges-clean. Real
-- `git merge`s in scratch repos, the driver armed as ensure-hooks.sh arms it.
--   CONTROL   the same merge without the attribute conflicts
--   FLOORS    clean; min wins; removed stays removed; added kept; comments kept;
--             each count shape; a lone count; a key whose file is gone is
--             dropped, one whose file only the other side has is kept; sorted
--   COMMENTS  the other side's comment edit survives
--   TEXTUAL   a line outside the grammar, or an absent binary: ordinary conflict
--             markers, never a silent "ours"
--   PROSE     gate-divergence-declared: union, removal sticks, one side's edit
--             kept, both sides' edits conflict on that key only
--   DEGRADED  labels that are not commits drop nothing
--   MERGETREE `git merge-tree` (the landing path) gives the same answer
--
-- Verdict: ok:merge-floor-min:<n> arms | violation:merge-floor-min:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("merge-floor-min")
local BIN = env.get("TILLANDSIAS_PLAN_BIN")
if not BIN or BIN == "" then T:refuse("no-plan-binary", "set TILLANDSIAS_PLAN_BIN (the litmus step does)") end

local PIPE = "scripts/portability/pipe-site-floor.txt"
local JQ = "scripts/portability/jq-callsite-floor.txt"
local LIST = "scripts/portability/shell-decider-floor.txt"
local LONE = "scripts/portability/installer-prompt-floor.txt"
local DIV = "scripts/gate-divergence-declared.txt"
local COPY = { "scripts/merge-floor-driver.sh", "scripts/lua/merge-floor-min.lua", "scripts/plan-binary-probe.sh" }

-- merge(tag, opts): base/left/right are { path = body | false (delete) };
-- merges right into left. Returns the repo, the merge result, and its git.
local function merge(tag, o)
    local d = T:git_repo(tag)
    local function g(...) return T:must{ "git", "-C", d.abs, ... } end
    local function put(set)
        for p, body in pairs(set) do
            if body == false then g("rm", "-q", "--", p) else
                fs.mkdir(d.rel .. "/" .. (p:match("^(.*)/[^/]+$") or "."))
                fs.write(d.rel .. "/" .. p, body)
            end
        end
        g("add", "-A"); g("commit", "-q", "--allow-empty", "-m", "c")
    end
    local b = {}
    for _, p in ipairs(COPY) do b[p] = fs.read(p) end
    local eol = (fs.read(".gitattributes") or ""):match("(%* text=auto eol=lf)") -- the real repo's line
    b[".gitattributes"] = (eol or "# no eol line in .gitattributes") .. "\n" .. (o.attr == false and "" or
        "scripts/portability/*-floor.txt merge=tillandsias-floor\n" .. DIV .. " merge=tillandsias-floor\n")
    for p, body in pairs(o.base) do b[p] = body end
    -- A native Windows checkout's setting, on every host: the repo's own
    -- eol=lf attribute (below) must win over it.
    g("config", "core.autocrlf", "true")
    g("config", "merge.tillandsias-floor.driver", o.driver or "bash scripts/merge-floor-driver.sh %O %A %B %P %X %Y")
    put(b)
    local main = text.trim(g("rev-parse", "--abbrev-ref", "HEAD").stdout)
    g("checkout", "-q", "-b", "left"); put(o.left)
    g("checkout", "-q", main); g("checkout", "-q", "-b", "right"); put(o.right)
    g("checkout", "-q", "left")
    local e = { TILLANDSIAS_PLAN_BIN = o.bin or BIN, PATH = env.get("PATH"), HOME = env.get("HOME") }
    local r
    if o.tree then
        r = T:run{ "git", "-C", d.abs, "merge-tree", "--write-tree", "left", "right", env = e }
    else
        r = T:run{ "git", "-C", d.abs, "merge", "-q", "--no-edit", "right", env = e }
    end
    return d, r, g
end
local function show(d, p) return fs.read(d.rel .. "/" .. p) or "" end
local F = { ["a.sh"] = "a\n", ["b.sh"] = "b\n", ["c.sh"] = "c\n", ["x.yaml"] = "x\n", ["y.yaml"] = "y\n" }
local function with(t) local r = {}; for k, v in pairs(F) do r[k] = v end; for k, v in pairs(t) do r[k] = v end; return r end

local two = {
    base = with{ [PIPE] = "# header\nscripts a.sh 5\nscripts b.sh 3\nscripts c.sh 2\n", [JQ] = "4 x.yaml\n4 y.yaml\n", [LONE] = "# p\n4\n" },
    left = { [PIPE] = "# header\nscripts a.sh 4\nscripts b.sh 3\nscripts c.sh 2\n", [JQ] = "3 x.yaml\n4 y.yaml\n", [LONE] = "# p\n3\n" },
    right = { [PIPE] = "# header\nscripts a.sh 2\nscripts Z.sh 1\nscripts b.sh 3\n", [JQ] = "4 x.yaml\n1 y.yaml\n", [LONE] = "# p\n2\n", ["Z.sh"] = "z\n" },
}
local ctl = { attr = false, base = two.base, left = two.left, right = two.right }
local _, c = merge("control", ctl)
T:arm("control: without the driver the sibling floors conflict", c.code ~= 0, "merged clean")

local d, r = merge("floors", two)
T:arm("floors merge clean", r.code == 0, tostring(r.stderr) .. tostring(r.stdout))
T:arm("min wins, removal sticks, the other side's new file keeps its key, comments kept, sorted bytewise",
    show(d, PIPE) == "# header\nscripts Z.sh 1\nscripts a.sh 2\nscripts b.sh 3\n", show(d, PIPE))
T:arm("count-first shape", show(d, JQ) == "3 x.yaml\n1 y.yaml\n", show(d, JQ))
T:arm("a lone count takes the minimum", show(d, LONE) == "# p\n2\n", show(d, LONE))
local st = T:run{ "git", "-C", d.abs, "status", "--porcelain" }
T:arm("nothing unmerged, no temp file left behind", (st.stdout or "") == "", st.stdout)

local gone = {
    base = with{ [LIST] = "# l\na.sh\nb.sh\nc.sh\n" },
    left = { [LIST] = "# l\na.sh\nb.sh\nc.sh\nl.sh\n", ["l.sh"] = "l\n" },
    right = { [LIST] = "# l\na.sh\nb.sh\nc.sh\nr.sh\n", ["r.sh"] = "r\n", ["b.sh"] = false },
}
d, r = merge("gone", gone)
T:arm("a key whose file the other side deleted is dropped; both new keys kept",
    r.code == 0 and show(d, LIST) == "# l\na.sh\nc.sh\nl.sh\nr.sh\n", show(d, LIST))
local deg = { base = gone.base, left = gone.left, right = gone.right,
    driver = "bash scripts/merge-floor-driver.sh %O %A %B %P nope-1 nope-2" }
d, r = merge("degraded", deg)
T:arm("labels that are not commits drop nothing", r.code == 0 and show(d, LIST) == "# l\na.sh\nb.sh\nc.sh\nl.sh\nr.sh\n", show(d, LIST))
local mt = { base = gone.base, left = gone.left, right = gone.right, tree = true }
local g
d, r, g = merge("mergetree", mt)
local oid = text.trim(r.stdout or "")
local got = r.code == 0 and T:run{ "git", "-C", d.abs, "show", oid .. ":" .. LIST }.stdout or (r.stdout or "") .. (r.stderr or "")
T:arm("git merge-tree answers the same", got == "# l\na.sh\nc.sh\nl.sh\nr.sh\n", got)

d, r = merge("comments", { base = with{ [LIST] = "# l\na.sh\nb.sh\nc.sh\n" },
    left = { [LIST] = "# l\na.sh\nc.sh\n" }, right = { [LIST] = "# l, edited\na.sh\nb.sh\n" } })
T:arm("the other side's comment edit survives", r.code == 0 and show(d, LIST) == "# l, edited\na.sh\n", show(d, LIST))

local odd = { base = with{ [PIPE] = "scripts a.sh 5\nscripts b.sh 3\n" },
    left = { [PIPE] = "scripts a.sh five\nscripts b.sh 3\n" }, right = { [PIPE] = "scripts a.sh 2\nscripts b.sh 3\n" } }
d, r = merge("odd", odd)
T:arm("a line outside the grammar is an ordinary conflict with markers",
    r.code ~= 0 and show(d, PIPE):find("<<<<<<<", 1, true) ~= nil and show(d, PIPE):find("scripts a.sh 2", 1, true) ~= nil, show(d, PIPE))
d, r = merge("nobin", { bin = "/nonexistent/plan", base = two.base, left = two.left, right = two.right })
T:arm("an absent binary conflicts with markers, never a silent ours",
    r.code ~= 0 and show(d, PIPE):find("<<<<<<<", 1, true) ~= nil, show(d, PIPE))

local pb = "# head\n\na.sh  infra  one\nb.sh  excluded  two words\n# mid\nc.sh  untriaged  three\n"
d, r = merge("prose", { base = with{ [DIV] = pb },
    left = { [DIV] = "# head\n\na.sh  infra  one\nb.sh  excluded  left edit\n# mid\nl.sh  infra  new l\n" },
    right = { [DIV] = "# head\n\na.sh  infra  right edit\nb.sh  excluded  two words\n# mid\nc.sh  untriaged  three\nr.sh  infra  new r\n" } })
T:arm("prose: union, removal sticks, each side's own edit kept, comments in place",
    r.code == 0 and show(d, DIV) == "# head\n\na.sh  infra  right edit\nb.sh  excluded  left edit\n# mid\nl.sh  infra  new l\nr.sh  infra  new r\n", show(d, DIV))
d, r = merge("prose-both", { base = with{ [DIV] = pb },
    left = { [DIV] = (pb:gsub("two words", "LEFT")) },
    right = { [DIV] = (pb:gsub("two words", "RIGHT"):gsub("one", "uno")) } })
T:arm("prose: both sides' edits to one key conflict on that key only",
    r.code ~= 0 and show(d, DIV) == "# head\n\na.sh  infra  uno\n<<<<<<< ours\nb.sh  excluded  LEFT\n=======\nb.sh  excluded  RIGHT\n>>>>>>> theirs\n# mid\nc.sh  untriaged  three\n",
    show(d, DIV))

-- Every real file parses: an unparseable line would demote it to textual merges.
local bad = {}
for _, p in ipairs(fs.list("scripts/portability")) do
    local n = p:match("([^/]+%-floor%.txt)$")
    if n then
        local f = "scripts/portability/" .. n
        local s = fs.read(f)
        local rel = "target/plan-scratch/floor-self-" .. tostring(time.now_ms())
        fs.mkdir(rel)
        for _, k in ipairs({ "o", "a", "b" }) do fs.write(rel .. "/" .. k, s) end
        local q = T:run{ BIN, "script", "run", "scripts/lua/merge-floor-min.lua", "--", rel .. "/o", rel .. "/a", rel .. "/b", f }
        if not (q.stdout or ""):find("^ok:merge%-floor:%d") then bad[#bad + 1] = f .. ": " .. (q.stdout or "") .. (q.stderr or "") end
    end
end
T:arm("every live floor is in the grammar", #bad == 0, table.concat(bad, " "))

T:finish()
