-- @trace order:2118-asur
--
-- merge-floor-min.lua — a git merge driver for scripts/portability/*-floor.txt.
--
-- A floor may only DESCEND: each line is a key (a path, or a lane plus a path)
-- with a count, or, in a list floor, a bare key whose presence is the count.
-- Two branches that each lowered or removed lines of the same floor used to
-- conflict textually on adjacent lines, and a human then had to re-derive the
-- numbers. The merge is mechanical, key by key:
--   * a key both sides keep: the LOWER count (the floor only descends);
--   * a key one side removed (present in the base, absent on that side):
--     removed (it fell to zero);
--   * a key one side added (absent from the base): kept, with its count.
-- Comments and blank lines come from "ours". The gate's ratchet (the floor
-- checkers) stays the backstop: a merge that lowers a floor below the real
-- count is refused there, exactly as a hand edit would be.
--
-- A line's count is its LAST token when that is an integer (`path 3`,
-- `scripts path 3`), else its FIRST token when that is (`3 path`), else the
-- line has no count and is a list member.
--
-- Wiring (scripts/ensure-hooks.sh): .gitattributes routes the floors to
-- `merge=floor-min`; `git config merge.floor-min.driver` runs this through
-- the resolved plan binary with %O %A %B. Without a binary the driver exits
-- non-zero and git falls back to an ordinary conflict, never a silent merge.
--
-- Usage: tillandsias-plan script run scripts/lua/merge-floor-min.lua -- <base> <ours> <theirs>
-- Result is written to <ours>. Exit 0 merged; 1 refused (unreadable input).

local base_p, ours_p, theirs_p = arg and arg[1], arg and arg[2], arg and arg[3]
if not (base_p and ours_p and theirs_p) then
    io.stderr:write("usage: merge-floor-min.lua -- <base> <ours> <theirs>\n")
    verdict.emit("refused:merge-floor-min:usage", 1)
end

local function read(p)
    local ok, body = pcall(fs.read, p)
    if not ok or body == nil then return nil end
    return body
end

local function lines(body)
    local t = {}
    for l in ((body or "") .. "\n"):gmatch("([^\n]*)\n") do t[#t + 1] = l end
    if t[#t] == "" then t[#t] = nil end
    return t
end

local function is_data(l) return l:match("%S") ~= nil and not l:match("^%s*#") end

-- Parse a data line: key, count (number or nil), shape ("suffix"/"prefix"/"bare").
local function parse(l)
    local first, rest_after_first = l:match("^(%S+)%s+(.+)$")
    local before_last, last = l:match("^(.-)%s+(%S+)$")
    if last and last:match("^%d+$") then return before_last, tonumber(last), "suffix" end
    if first and first:match("^%d+$") then return rest_after_first, tonumber(first), "prefix" end
    return l, nil, "bare"
end

local function load(body)
    local map, order = {}, {}
    for _, l in ipairs(lines(body)) do
        if is_data(l) then
            local key, n, shape = parse(l)
            if map[key] == nil then order[#order + 1] = key end
            map[key] = { n = n, shape = shape }
        end
    end
    return map, order
end

local base_b, ours_b, theirs_b = read(base_p), read(ours_p), read(theirs_p)
if not ours_b or not theirs_b then
    verdict.emit("refused:merge-floor-min:unreadable-side", 1)
end
local base = load(base_b or "")
local ours, ours_order = load(ours_b)
local theirs, theirs_order = load(theirs_b)

local function render(key, rec)
    if rec.shape == "suffix" then return key .. " " .. rec.n end
    if rec.shape == "prefix" then return rec.n .. " " .. key end
    return key
end

local function merged(key)
    local a, b = ours[key], theirs[key]
    if base[key] ~= nil and (a == nil or b == nil) then return nil end -- one side removed it
    if a and b then
        if a.n and b.n then return { n = math.min(a.n, b.n), shape = a.shape } end
        return a
    end
    return a or b -- added on one side
end

-- Ours' line order with its comments; theirs' new keys after, in theirs' order.
local out, seen = {}, {}
for _, l in ipairs(lines(ours_b)) do
    if not is_data(l) then
        out[#out + 1] = l
    else
        local key = parse(l)
        if not seen[key] then
            seen[key] = true
            local rec = merged(key)
            if rec then out[#out + 1] = render(key, rec) end
        end
    end
end
local added = {}
for _, key in ipairs(theirs_order) do
    if not seen[key] then
        seen[key] = true
        local rec = merged(key)
        if rec then added[#added + 1] = render(key, rec) end
    end
end
-- If ours' data lines were sorted, keep the file sorted.
local data_sorted = true
local prev
for _, key in ipairs(ours_order) do
    if prev and key < prev then data_sorted = false; break end
    prev = key
end
for _, l in ipairs(added) do out[#out + 1] = l end
if data_sorted and #added > 0 then
    local comments, data = {}, {}
    for _, l in ipairs(out) do
        if is_data(l) then data[#data + 1] = l else comments[#comments + 1] = l end
    end
    -- leading comment block stays first; data sorted by key
    table.sort(data, function(x, y) return (parse(x)) < (parse(y)) end)
    out = {}
    for _, l in ipairs(comments) do out[#out + 1] = l end
    for _, l in ipairs(data) do out[#out + 1] = l end
end

fs.write(ours_p, table.concat(out, "\n") .. "\n")
verdict.emit("ok:merge-floor-min:" .. #out .. " lines", 0)
