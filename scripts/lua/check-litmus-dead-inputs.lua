-- @trace spec:litmus-framework, order:765-mza8, order:1643-q3at
--
-- check-litmus-dead-inputs.lua — order 765-mza8, the 634-39ik/698-7n6q family.
-- (Ported from scripts/check-litmus-dead-inputs.sh: the shell-to-lua item
-- 1643-q3at carried.)
--
-- An `inputs:` glob that matches NOTHING is the dangerous kind of wrong. It
-- cannot make a test run; it can only make it skip. So a typo'd or stale glob
-- ("crate/**", a renamed script, a deleted image dir) silently subtracts that
-- test from every `--diff-scope` run while the suite still reports green. This
-- guard makes that class impossible to commit.
--
-- THE PROPERTY, not the literal. It does not pin which globs exist or how many.
-- It asserts of every declared glob: it resolves to at least one tracked file
-- today. That stays true as annotations are added, renamed, and removed, and it
-- fails exactly when an annotation stops describing the tree.
--
-- Matching reproduces bash `[[ path == $glob ]]`, DELIBERATELY the matcher
-- run-litmus-test.sh uses at selection time (litmus_inputs_intersect_diff):
-- `*` and `?` cross `/`, `[...]` / `[!...]` are classes. git's pathspec engine
-- would answer a different question — `**` and `*` mean different things there.
--
-- Verdicts: ok:litmus-dead-inputs:<n> glob(s) across <m> annotated test(s)
--           ok:litmus-dead-inputs:not-a-git-repo | ok:litmus-dead-inputs:no-tracked-files
--           violation:litmus-dead-inputs:<n>   (exit 1; each dead glob named on stderr)

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 15000 })
if top.code ~= 0 then verdict.ok("litmus-dead-inputs", "not-a-git-repo (nothing to resolve against)") end
local root = text.trim(top.stdout or "")

local ls = proc.run({ argv = { "git", "ls-files" }, cwd = root, timeout_ms = 60000 })
local tracked = text.lines(ls.stdout or "")
if #tracked == 0 or (#tracked == 1 and tracked[1] == "") then
    verdict.ok("litmus-dead-inputs", "no-tracked-files")
end

-- bash [[ == ]] glob → anchored Lua pattern.
local function glob_to_pattern(g)
    local out, i, n = { "^" }, 1, #g
    while i <= n do
        local c = g:sub(i, i)
        if c == "*" then
            out[#out + 1] = ".*"
        elseif c == "?" then
            out[#out + 1] = "."
        elseif c == "[" then
            local j = g:find("]", i + 2, true)
            if j then
                local body = g:sub(i + 1, j - 1)
                if body:sub(1, 1) == "!" then body = "^" .. body:sub(2) end
                body = body:gsub("%%", "%%%%")
                out[#out + 1] = "[" .. body .. "]"
                i = j
            else
                out[#out + 1] = "%["
            end
        elseif c == "\\" and i < n then
            i = i + 1
            out[#out + 1] = (g:sub(i, i):gsub("%W", "%%%0"))
        else
            out[#out + 1] = (c:gsub("%W", "%%%0"))
        end
        i = i + 1
    end
    out[#out + 1] = "$"
    return table.concat(out)
end

local files = {}
for _, f in ipairs(fs.list(root .. "/openspec/litmus-tests") or {}) do
    local name = f:match("([^/]+)$") or f
    if name:match("^litmus%-.*%.yaml$") then files[#files + 1] = "openspec/litmus-tests/" .. name end
end
table.sort(files)

local dead, checked, annotated = 0, 0, 0
for _, file in ipairs(files) do
    local ok, doc = pcall(yaml.parse, fs.read(root .. "/" .. file))
    local globs = ok and type(doc) == "table" and type(doc.inputs) == "table" and doc.inputs or nil
    if globs and #globs > 0 then
        annotated = annotated + 1
        for _, g in ipairs(globs) do
            g = tostring(g)
            if g ~= "" then
                checked = checked + 1
                local pat = glob_to_pattern(g)
                local hit = false
                for _, p in ipairs(tracked) do
                    if p:match(pat) then hit = true; break end
                end
                if not hit then
                    dead = dead + 1
                    log.raw("REFUSED: " .. file .. " declares inputs glob '" .. g .. "', which matches no tracked file.")
                    log.raw("         A glob that matches nothing can only SUBTRACT this test from")
                    log.raw("         --diff-scope runs. Fix the glob, or drop it if the dependency")
                    log.raw("         is gone. Matching is bash [[ == ]], so '*' crosses '/'.")
                end
            end
        end
    end
end

if dead > 0 then verdict.emit("violation:litmus-dead-inputs:" .. dead, 1) end
verdict.ok("litmus-dead-inputs", checked .. " glob(s) across " .. annotated .. " annotated test(s)")
