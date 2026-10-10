-- @trace order:1581-d9ig
--
-- check-fixture-prunes-checkout.lua — no fixture runs `git worktree prune` or
-- `git gc` against the operator's checkout.
--
-- WHY. Two fixtures' teardown traps ran `git -C "$ROOT" worktree prune` on the
-- REAL checkout (test-pre-push-trailer-states-what-it-saw.sh,
-- test-fragment-ts-skew.sh). Inside the WSL guest that prune deletes every
-- Windows worktree whose C:/ path the guest cannot see, because to the guest
-- those worktrees look missing. Each fixture already removed its OWN worktree
-- with `git worktree remove --force`, so the prune bought nothing. A prune or a
-- gc belongs to the operator, never to a test; a fixture may prune or gc its
-- OWN scratch repo (`git -C "$WORK/copy" gc` stays allowed).
--
-- POPULATION. Fixtures: scripts/**/test-*.sh. A shell fixture is read with its
-- comments stripped (a `#` that starts a word outside quotes ends the line),
-- then every `git` invocation is cut at the next `;`, `&&`, `||`, `|`, `'`, `)`
-- or backtick, so a site inside a single-quoted trap body is still seen.
--
-- AGAINST THE CHECKOUT means the invocation's -C (or --git-dir/--work-tree)
-- names a ROOT variable, `.`, or `$(git rev-parse --show-toplevel)`, or the
-- invocation has none at all (it acts on the cwd, which for a fixture run by
-- build.sh is the checkout). The ROOT variables are ROOT and REPO_ROOT, plus any
-- variable the file assigns from `git rev-parse --show-toplevel` or from
-- `dirname` of BASH_SOURCE / $0.
--
-- Verdicts:
--   ok:fixture-prunes-checkout:fixtures=<n> scratch-sites=<k>          exit 0
--   violation:fixture-prunes-checkout:<path>:<line>:<worktree-prune|gc> exit 1 (one line each)
--   could-not-run:fixture-prunes-checkout:empty-population              exit 3
local function read(p) local ok, s = pcall(fs.read, p); if ok then return s end; return nil end

local fixtures = {}
for _, f in ipairs(fs.walk("scripts", { suffix = ".sh" })) do
    if (f:match("([^/]+)$") or ""):find("^test%-") then fixtures[#fixtures + 1] = f end
end
table.sort(fixtures)
if #fixtures == 0 then
    verdict.emit("could-not-run:fixture-prunes-checkout:empty-population", 3,
        "no scripts/**/test-*.sh found: nothing was read, so nothing is vouched for")
end

-- Drop a shell comment: a `#` at the start of a word, outside quotes.
local function strip_comment(l)
    local sq, dq, prev = false, false, " "
    for i = 1, #l do
        local c = l:sub(i, i)
        if c == "'" and not dq then sq = not sq
        elseif c == '"' and not sq then dq = not dq
        elseif c == "#" and not sq and not dq and prev:match("%s") then return l:sub(1, i - 1) end
        prev = c
    end
    return l
end

-- Split one invocation into words, honouring double quotes (the -C target is
-- usually "$ROOT"); single quotes cut the segment before it gets here.
local function words(seg)
    local t, cur, dq, any = {}, "", false, false
    for i = 1, #seg do
        local c = seg:sub(i, i)
        if c == '"' then dq = not dq; any = true
        elseif c:match("%s") and not dq then
            if any then t[#t + 1] = cur end
            cur, any = "", false
        else cur = cur .. c; any = true end
    end
    if any then t[#t + 1] = cur end
    return t
end

local function roots_of(src)
    local r = { ROOT = true, REPO_ROOT = true }
    for _, l in ipairs(text.lines(src)) do
        local name, rhs = l:match("^%s*[%w%s]-([%a_][%w_]*)=(.*)$")
        if name and (rhs:find("rev-parse --show-toplevel", 1, true)
            or (rhs:find("dirname", 1, true) and (rhs:find("BASH_SOURCE", 1, true) or rhs:find("$0", 1, true)))) then
            r[name] = true
        end
    end
    return r
end

local function is_root(target, roots)
    if target == nil then return true end -- no -C: the cwd, i.e. the checkout
    if target == "." or target:find("rev-parse --show-toplevel", 1, true) then return true end
    local v = target:match("^%${?([%a_][%w_]*)}?$") or target:match("^%${?([%a_][%w_]*)}?/%.git$")
    return v ~= nil and roots[v] == true
end

-- What a `git …` segment does: "worktree-prune", "gc" or nil, and its target.
local function judge(seg)
    local w = words(seg)
    if w[1] ~= "git" then return nil end
    local i, target = 2, nil
    while w[i] do
        local a = w[i]
        if a == "-C" or a == "--git-dir" or a == "--work-tree" then target = target or w[i + 1]; i = i + 2
        elseif a:find("^%-%-git%-dir=") or a:find("^%-%-work%-tree=") then target = target or a:match("=(.*)$"); i = i + 1
        elseif a == "-c" then i = i + 2
        elseif a:find("^%-") then i = i + 1
        else break end
    end
    if w[i] == "gc" then return "gc", target end
    if w[i] == "worktree" and w[i + 1] == "prune" then return "worktree-prune", target end
    return nil
end

local violations, scratch = {}, 0
for _, f in ipairs(fixtures) do
    local src = read(f) or ""
    local roots = roots_of(src)
    for n, raw in ipairs(text.lines(src)) do
        local l = strip_comment(raw)
        local from = 1
        while true do
            local s, e = l:find("%f[%w_%-]git%f[^%w_%-]", from)
            if not s then break end
            local rest = l:sub(s)
            local cut = #rest + 1
            for _, sep in ipairs({ ";", "&&", "||", "|", "'", ")", "`" }) do
                local p = rest:find(sep, 1, true)
                if p and p < cut then cut = p end
            end
            local what, target = judge(rest:sub(1, cut - 1))
            if what then
                if is_root(target, roots) then
                    violations[#violations + 1] = ("violation:fixture-prunes-checkout:%s:%d:%s"):format(f, n, what)
                    log.raw(("  %s:%d runs `git %s` against %s — the operator's checkout. Remove only the fixture's own worktree (`git worktree remove --force \"$WT\"`), or pass -C a scratch repo (1581-d9ig).")
                        :format(f, n, what == "gc" and "gc" or "worktree prune", target and ("-C " .. target) or "the cwd"))
                else
                    scratch = scratch + 1
                end
            end
            from = e + 1
        end
    end
end

for i = 1, #violations - 1 do out.line(violations[i]) end
if #violations > 0 then verdict.emit(violations[#violations], 1) end
verdict.emit(("ok:fixture-prunes-checkout:fixtures=%d scratch-sites=%d"):format(#fixtures, scratch), 0)
