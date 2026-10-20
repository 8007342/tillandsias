-- @trace spec:ci-release, plan 1325-ygq5 (family), 1329-m8dk (discovery)
--
-- census-litmus-reachability.lua — PORTED from census-litmus-reachability.sh
-- (1118-fqfk carry). How many litmus tests cannot be reached under the name
-- they give themselves?
--
-- THE QUESTION. Of the tests that ARE bound, how many run credited to a spec
-- they do not declare, so that asking for them by their own spec name returns
-- "no litmus tests matched filter" and the spec they name reads covered with
-- nothing behind it? check-litmus-bindings refuses NEW mismatches only (it is
-- diff-scoped), so every pre-existing one is inherited and silent; this counts
-- the standing set.
--
-- Multi-spec declarations are honoured: `spec: a, b, c` matches a binding under
-- any of a, b or c, as check-litmus-bindings.lua splits them. ORDER 1333-jpq5:
-- every binding of a name is consulted, not the first; a mismatch exists only
-- when NO binding matches ANY declared spec.
--
-- Grammar (one line on stdout, plus an optional listing):
--   census:litmus-reachability files=N retired=N grandfathered-unbound=N unbound=N spec-binding-mismatch=N
--
-- Usage: tillandsias-plan script run scripts/lua/census-litmus-reachability.lua [-- --list]

local TESTS_DIR = "openspec/litmus-tests"
local BINDINGS = "openspec/litmus-bindings.yaml"
local GRAND = TESTS_DIR .. "/unbound-grandfathered.txt"
local list = arg[1] == "--list"

local ok_b, bindings = pcall(fs.read, BINDINGS)
if not ok_b then
    log.raw("  note: " .. BINDINGS .. " absent")
    out.line("census:litmus-reachability files=0 retired=0 grandfathered-unbound=0 unbound=0 spec-binding-mismatch=0")
    verdict.emit("ok:census-litmus-reachability:no-bindings", 0)
end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

-- name -> list of spec_ids it is bound under
local bound_under, bound = {}, {}
local current = nil
for line in (bindings .. "\n"):gmatch("(.-)\n") do
    local sid = line:match("^%- spec_id:%s*(%S+)")
    if sid then current = sid end
    for nm in line:gmatch("litmus:[a-z0-9._-]+") do bound[nm] = true end
    local item = line:match("^  %- (litmus:[a-z0-9._-]+)%s*$")
    if item and current then
        bound_under[item] = bound_under[item] or {}
        table.insert(bound_under[item], current)
    end
end

local grand = {}
local ok_g, gtext = pcall(fs.read, GRAND)
if ok_g then
    for line in (gtext .. "\n"):gmatch("(.-)\n") do
        if not line:match("^%s*#") then
            local v = trim(line:gsub("%s*#.*$", ""))
            if v ~= "" then grand[v] = true end
        end
    end
end

local files = {}
for _, f in ipairs(fs.walk(TESTS_DIR)) do
    local base = f:match("([^/]+)$")
    if base and base:match("^litmus%-.*%.yaml$") and not f:sub(#TESTS_DIR + 2):find("/", 1, true) then
        files[#files + 1] = f
    end
end
table.sort(files)

local n_files, retired, gf, unbound, mismatch = 0, 0, 0, 0, 0
for _, f in ipairs(files) do
    local text = fs.read(f)
    local nm = text:match("\nname:%s*([^\n]-)%s*\n") or text:match("^name:%s*([^\n]-)%s*\n")
    if nm and nm ~= "" then
        n_files = n_files + 1
        local base = f:match("([^/]+)$")
        if text:match("\nphase:%s*retired%s*\n") or text:match("^phase:%s*retired%s*\n") then
            retired = retired + 1
        elseif not bound[nm] then
            if grand[nm] then
                gf = gf + 1
                if list then out.line("grandfathered-unbound  " .. nm .. "  (" .. base .. ")") end
            else
                unbound = unbound + 1
                if list then out.line("UNBOUND                " .. nm .. "  (" .. base .. ")") end
            end
        else
            local decl = text:match("\nspec:%s*([^\n]-)%s*\n") or text:match("^spec:%s*([^\n]-)%s*\n")
            local unders = bound_under[nm] or {}
            if decl and decl ~= "" and #unders > 0 then
                local declset = {}
                for part in decl:gmatch("[^,]+") do
                    local p = trim(part)
                    if p ~= "" then declset[p] = true end
                end
                local matched = false
                for _, u in ipairs(unders) do
                    if declset[u] then matched = true end
                end
                if not matched then
                    mismatch = mismatch + 1
                    if list then
                        out.line("spec-binding-mismatch  " .. nm .. "  declares=[" .. decl .. "]  bound-under=" .. table.concat(unders, " "))
                    end
                end
            end
        end
    end
end

out.line(("census:litmus-reachability files=%d retired=%d grandfathered-unbound=%d unbound=%d spec-binding-mismatch=%d")
    :format(n_files, retired, gf, unbound, mismatch))
verdict.ok("census-litmus-reachability", n_files)
