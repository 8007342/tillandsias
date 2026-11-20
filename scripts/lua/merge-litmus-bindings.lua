-- @trace order:2118-asur
--
-- merge-litmus-bindings.lua — a git merge driver for openspec/litmus-bindings.yaml.
--
-- Operator 2026-11-20 (landing-pipeline redesign, P4 row 2): sibling branches
-- that each bind a litmus test to the same spec, or to neighbouring specs,
-- conflicted textually in this one shared registry. The ruling named a .d/
-- split; this file is read directly by more than thirty consumers (the plan
-- binary, the litmus runner, the census and centicolon tools, their
-- fixtures), so the registry stays one file and its MERGE becomes structural
-- instead. Same outcome (sibling bindings merge clean), no consumer moves.
--
-- The file is a header, then one block per spec:
--   - spec_id: <id>
--     <field>: <scalar>
--     litmus_tests:            (or `litmus_tests: []`)
--     - litmus:<name>
-- Three-way, block by block (keyed by spec_id):
--   * litmus_tests: a set merge — ours' order, theirs' additions appended,
--     a removal on either side honoured;
--   * every other field line: theirs when ours kept the base's, else ours;
--   * a block one side added is kept; a block one side deleted (and the other
--     left unchanged) is deleted; deleted on one side and CHANGED on the other
--     is a real conflict, refused (git then leaves an ordinary conflict).
-- The header (everything before the first block) comes from ours.
-- Anything that does not parse as this shape is refused, never guessed.
--
-- Usage: tillandsias-plan script run scripts/lua/merge-litmus-bindings.lua -- <base> <ours> <theirs>
-- Result is written to <ours>. Exit 0 merged; 1 refused.

local base_p, ours_p, theirs_p = arg and arg[1], arg and arg[2], arg and arg[3]
if not (base_p and ours_p and theirs_p) then
    io.stderr:write("usage: merge-litmus-bindings.lua -- <base> <ours> <theirs>\n")
    verdict.emit("refused:merge-litmus-bindings:usage", 1)
end

local function refuse(why)
    io.stderr:write("merge-litmus-bindings: " .. why .. "\n")
    verdict.emit("refused:merge-litmus-bindings:" .. why, 1)
end

local function lines(body)
    local t = {}
    for l in ((body or "") .. "\n"):gmatch("([^\n]*)\n") do t[#t + 1] = l end
    if t[#t] == "" then t[#t] = nil end
    return t
end

-- A block is a sequence of entries in file order, each carrying the comment
-- lines just above it (`pre`):
--   {t="field", key=, line=, pre=}   {t="tests", empty=bool, pre=}   {t="test", v=, pre=}
-- Comments before the next block, or at the end, are the block's `trail`.
local function load(body, side)
    local doc = { header = {}, order = {}, blocks = {} }
    local cur, in_tests, pending = nil, false, {}
    for _, l in ipairs(lines(body)) do
        local id = l:match("^%- spec_id:%s*(.-)%s*$")
        if id then
            if cur then cur.trail = pending end
            pending = {}
            if doc.blocks[id] then refuse("duplicate-spec-" .. side .. ":" .. id) end
            cur = { seq = {}, trail = {} }
            doc.blocks[id] = cur
            doc.order[#doc.order + 1] = id
            in_tests = false
        elseif not cur then
            doc.header[#doc.header + 1] = l
        elseif l:match("^  #") then
            pending[#pending + 1] = l
        elseif l:match("^  litmus_tests:%s*%[%]%s*$") then
            cur.seq[#cur.seq + 1] = { t = "tests", empty = true, pre = pending }; pending = {}
            in_tests = false
        elseif l:match("^  litmus_tests:%s*$") then
            cur.seq[#cur.seq + 1] = { t = "tests", empty = false, pre = pending }; pending = {}
            in_tests = true
        elseif in_tests and l:match("^  %- ") then
            cur.seq[#cur.seq + 1] = { t = "test", v = l:match("^  %- (.-)%s*$"), pre = pending }; pending = {}
        elseif l:match("^  [%w_]+:") then
            in_tests = false
            cur.seq[#cur.seq + 1] = { t = "field", key = l:match("^  ([%w_]+):"), line = l, pre = pending }
            pending = {}
        else
            refuse("unparsed-line-" .. side)
        end
    end
    if cur then cur.trail = pending end
    return doc
end

local function read(p)
    local ok, body = pcall(fs.read, p)
    if ok then return body end
    return nil
end

local base_b, ours_b, theirs_b = read(base_p), read(ours_p), read(theirs_p)
if not ours_b or not theirs_b then refuse("unreadable-side") end
local base = load(base_b or "", "base")
local ours = load(ours_b, "ours")
local theirs = load(theirs_b, "theirs")

local function tests_of(blk)
    local t = {}
    for _, e in ipairs(blk.seq) do if e.t == "test" then t[#t + 1] = e end end
    return t
end
local function fields_of(blk)
    local m = {}
    for _, e in ipairs(blk.seq) do if e.t == "field" then m[e.key] = e end end
    return m
end
local function render(blk)
    local r = {}
    for _, e in ipairs(blk.seq) do
        for _, c in ipairs(e.pre) do r[#r + 1] = c end
        r[#r + 1] = e.t == "field" and e.line or e.t == "test" and e.v or (e.empty and "[]" or ":")
    end
    for _, c in ipairs(blk.trail) do r[#r + 1] = c end
    return table.concat(r, "\n")
end

-- Merge one block. Returns the list of output lines (without the spec_id line), or nil (deleted).
local function merge_block(id, o, t, b)
    if b and (not o or not t) then
        local kept = o or t
        if render(kept) == render(b) then return nil end
        refuse("delete-modify:" .. id)
    end
    local src = o or t
    o = o or t; t = t or src
    -- fields
    local om, tm, bm = fields_of(o), fields_of(t), b and fields_of(b) or {}
    local function pick(key)
        local oe, te, be = om[key], tm[key], bm[key]
        if oe and te then
            if be and oe.line == be.line and te.line ~= be.line then return te end
            return oe
        end
        if oe and not te then
            if be and oe.line == be.line then return nil end -- theirs removed it
            return oe
        end
        if te and not oe then
            if be then return nil end -- ours removed it
            return te
        end
        return nil
    end
    -- tests: three-way set merge, each test with its comments
    local bset = {}
    if b then for _, e in ipairs(tests_of(b)) do bset[e.v] = true end end
    local oset, tset = {}, {}
    for _, e in ipairs(tests_of(o)) do oset[e.v] = true end
    for _, e in ipairs(tests_of(t)) do tset[e.v] = true end
    local merged_tests, have = {}, {}
    for _, e in ipairs(tests_of(o)) do
        if not (bset[e.v] and not tset[e.v]) and not have[e.v] then
            merged_tests[#merged_tests + 1] = e; have[e.v] = true
        end
    end
    for _, e in ipairs(tests_of(t)) do
        if not have[e.v] and not (bset[e.v] and not oset[e.v]) then
            merged_tests[#merged_tests + 1] = e; have[e.v] = true
        end
    end
    -- emit in ours' order; theirs-only fields after
    local outl, seen, tests_done = {}, {}, false
    local function put_pre(e) for _, c in ipairs(e.pre) do outl[#outl + 1] = c end end
    local function put_tests(hdr)
        tests_done = true
        if hdr then put_pre(hdr) end
        if #merged_tests == 0 then
            outl[#outl + 1] = "  litmus_tests: []"
        else
            outl[#outl + 1] = "  litmus_tests:"
            for _, e in ipairs(merged_tests) do put_pre(e); outl[#outl + 1] = "  - " .. e.v end
        end
    end
    for _, e in ipairs(o.seq) do
        if e.t == "field" then
            seen[e.key] = true
            local f = pick(e.key)
            if f then put_pre(f); outl[#outl + 1] = f.line end
        elseif e.t == "tests" then
            put_tests(e)
        end
    end
    if not tests_done and #merged_tests > 0 then put_tests(nil) end
    for _, e in ipairs(t.seq) do
        if e.t == "field" and not seen[e.key] then
            seen[e.key] = true
            local f = pick(e.key)
            if f then put_pre(f); outl[#outl + 1] = f.line end
        end
    end
    for _, c in ipairs(o.trail) do outl[#outl + 1] = c end
    return outl
end

local out = {}
for _, l in ipairs(ours.header) do out[#out + 1] = l end
local function emit(id, body)
    out[#out + 1] = "- spec_id: " .. id
    for _, l in ipairs(body) do out[#out + 1] = l end
end
local done = {}
for _, id in ipairs(ours.order) do
    done[id] = true
    local body = merge_block(id, ours.blocks[id], theirs.blocks[id], base.blocks[id])
    if body then emit(id, body) end
end
for _, id in ipairs(theirs.order) do
    if not done[id] then
        done[id] = true
        local body = merge_block(id, nil, theirs.blocks[id], base.blocks[id])
        if body then emit(id, body) end
    end
end

fs.write(ours_p, table.concat(out, "\n") .. "\n")
verdict.emit("ok:merge-litmus-bindings:" .. #out .. " lines", 0)
