-- @trace order:2118-asur
-- @env TILLANDSIAS_MERGE_OURS TILLANDSIAS_MERGE_THEIRS
--
-- merge-floor-min.lua — the git merge driver `tillandsias-floor`, for
-- scripts/portability/*-floor.txt and scripts/gate-divergence-declared.txt.
-- A three-way set merge keyed by path (operator's bundle-landing design):
--   * a key present in the base and gone on either side stays removed;
--   * a key added on one side is kept;
--   * floors: a count takes the MINIMUM (a floor only descends); a key whose
--     file is not in the merged tree is dropped; output sorted bytewise by key;
--   * gate-divergence-declared (prose): union by key, the skeleton's order; a key
--     both sides changed differently gets conflict markers for that key only.
-- Comments come from whichever side changed them. Anything this cannot read by
-- the file's own grammar (an odd line, a duplicate key, comments both sides
-- changed) goes to `git merge-file`, git's ordinary textual merge, whole file.
--
-- Grammars: `path N` / `lane path N` / `N path` / a bare path / a lone `N`
-- (a file-wide floor); divergence `path class reason...`.
--
-- FILE EXISTENCE is read from the two commits git names in %X and %Y (the
-- wrapper's TILLANDSIAS_MERGE_OURS/_THEIRS), never the worktree: the driver runs
-- before the other side's files are checked out, and `git merge-tree` has no
-- worktree. A side that does not resolve to a commit (a rebase's label, an
-- older git, a virtual base) proves nothing, and no key is dropped.
--
-- Usage: ... merge-floor-min.lua -- <base> <ours> <theirs> <path> ; the result is
-- written to <ours>. Exit 0 merged, 1 conflict markers written. Any other
-- outcome leaves <ours> for scripts/merge-floor-driver.sh to hand to merge-file.

local base_p, ours_p, theirs_p, path = arg[1], arg[2], arg[3], arg[4]
if not path then verdict.emit("refused:merge-floor:usage", 1) end
local PROSE = path:find("gate%-divergence%-declared%.txt$") ~= nil

local function read(p)
    local good, body = pcall(fs.read, p)
    return good and body or nil
end
local function lines(body)
    local t = {}
    for l in body:gmatch("([^\n]*)\n?") do t[#t + 1] = l end
    while t[#t] == "" do t[#t] = nil end
    return t
end
local function git(...)
    local r = proc.run{ argv = { "git", ... }, timeout_ms = 30000 }
    return r.code, r.stdout or ""
end

-- Hand the whole file to git's textual merge (markers included).
local function textual(why)
    log.raw("note:merge-floor:textual:" .. path .. " — " .. why)
    local rc = git("merge-file", ours_p, base_p, theirs_p)
    if rc == 0 then verdict.emit("ok:merge-floor:textual", 0) end
    verdict.emit("violation:merge-floor:conflict:" .. path, 1)
end

local function is_data(l) return l:find("%S") ~= nil and not l:find("^%s*#") end

-- key, count, shape, file; or nil when the line is not in this file's grammar.
local function parse(l)
    if PROSE then
        local p = l:match("^(%S+)%s+%S+%s+%S")
        if p then return p, nil, "prose", nil end
        return nil
    end
    local f = {}
    for w in l:gmatch("%S+") do f[#f + 1] = w end
    local function num(s) return s:find("^%d+$") and tonumber(s) or nil end
    if #f == 1 then
        if num(f[1]) then return "", num(f[1]), "lone", nil end
        return f[1], nil, "bare", f[1]
    end
    if #f == 2 and num(f[2]) and not num(f[1]) then return f[1], num(f[2]), "suffix", f[1] end
    if #f == 2 and num(f[1]) and not num(f[2]) then return f[2], num(f[1]), "prefix", f[2] end
    if #f == 3 and num(f[3]) and not num(f[2]) then return f[1] .. " " .. f[2], num(f[3]), "suffix", f[2] end
    return nil
end

local function load(p)
    local body = read(p)
    if not body then return nil end
    local s = { map = {}, order = {}, comments = {}, lines = lines(body) }
    for _, l in ipairs(s.lines) do
        if is_data(l) then
            local key, n, shape, file = parse(l)
            if not key then return nil, "a line outside this file's grammar: " .. l:sub(1, 80) end
            if s.map[key] then return nil, "key listed twice: " .. key end
            s.map[key] = { n = n, shape = shape, file = file, line = l }
            s.order[#s.order + 1] = key
        elseif l:find("%S") then
            s.comments[#s.comments + 1] = l
        end
    end
    s.ctext = table.concat(s.comments, "\n")
    return s
end

local base, e1 = load(base_p)
local ours, e2 = load(ours_p)
local theirs, e3 = load(theirs_p)
if not (base and ours and theirs) then textual(e1 or e2 or e3 or "unreadable side") end

local skel, other = ours, theirs
if ours.ctext ~= theirs.ctext and theirs.ctext ~= base.ctext then
    if ours.ctext ~= base.ctext then textual("both sides changed the comments") end
    skel, other = theirs, ours
end

-- Trees: a file is in the merge when both sides have it, or one side added it.
local function tree_of(label)
    if not label or label == "" then return nil end
    local rc, o = git("rev-parse", "--verify", "--quiet", "--end-of-options", label .. "^{commit}")
    return rc == 0 and text.trim(o) or nil
end
local X, Y = tree_of(env.get("TILLANDSIAS_MERGE_OURS")), tree_of(env.get("TILLANDSIAS_MERGE_THEIRS"))
local B = nil
if X and Y then
    local rc, o = git("merge-base", X, Y)
    if rc == 0 then B = text.trim(o) end
end
local trees = {}
local function files_in(c)
    local rc, o = git("ls-tree", "-r", "-z", "--name-only", "--full-tree", c)
    if rc ~= 0 then return nil end
    local t = {}
    for f in o:gmatch("([^%z]+)") do t[f] = true end
    return t
end
if B then trees.x, trees.y, trees.b = files_in(X), files_in(Y), files_in(B) end
local function gone(file)
    if PROSE or not file or not (trees.x and trees.y and trees.b) then return false end
    local x, y = trees.x[file], trees.y[file]
    if x and y then return false end
    return not ((x or y) and not trees.b[file])
end

local conflicts, dropped = 0, 0
-- The rendered line(s) for a key, or nil when it is not in the result.
local function merged(key)
    local o, a, b = base.map[key], ours.map[key], theirs.map[key]
    if o and (not a or not b) then return nil end
    local rec = a or b
    if gone(rec.file) then dropped = dropped + 1; return nil end
    if not (a and b) or a.line == b.line then return rec.line end
    if not PROSE and a.n and b.n and a.shape == b.shape then
        return (a.n <= b.n and a or b).line
    end
    if o and a.line == o.line then return b.line end
    if o and b.line == o.line then return a.line end
    conflicts = conflicts + 1
    return "<<<<<<< ours\n" .. a.line .. "\n=======\n" .. b.line .. "\n>>>>>>> theirs"
end

local res, seen = {}, {}
local function put(key)
    if seen[key] then return end
    seen[key] = true
    local l = merged(key)
    if l then res[#res + 1] = { key = key, line = l } end
end
local rendered = {}
if PROSE then
    for _, l in ipairs(skel.lines) do
        if is_data(l) then
            res = {}; put((parse(l)))
            if res[1] then rendered[#rendered + 1] = res[1].line end
        else rendered[#rendered + 1] = l end
    end
    res = {}
    for _, key in ipairs(other.order) do put(key) end
    for _, r in ipairs(res) do rendered[#rendered + 1] = r.line end
else
    for _, l in ipairs(skel.lines) do if not is_data(l) and l:find("%S") then rendered[#rendered + 1] = l end end
    for _, key in ipairs(skel.order) do put(key) end
    for _, key in ipairs(other.order) do put(key) end
    table.sort(res, function(x, y) return x.key < y.key end)
    for _, r in ipairs(res) do rendered[#rendered + 1] = r.line end
end
fs.write(ours_p, #rendered > 0 and (table.concat(rendered, "\n") .. "\n") or "")
if conflicts > 0 then
    log.raw("  why: both sides changed the same key differently; neither is picked\n  remedy: resolve the marked keys in " .. path)
    verdict.emit("violation:merge-floor:conflict:" .. path, 1)
end
verdict.emit("ok:merge-floor:" .. #res .. ":dropped=" .. dropped, 0)
