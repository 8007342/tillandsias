-- @trace order:2118-9awa
--
-- check-no-fixture-writes-live-ledger.lua — PORTED from
-- check-no-fixture-writes-live-ledger.sh (2118-9awa, check-[n-z] batch 1).
-- A fixture (scripts/test-*.sh) must never write into the LIVE ledger
-- directories plan/index.d/ or plan/loop_status.d/: it plants its probes in a
-- scaffold and asserts the live plan/ unchanged.
--
-- The rules are the .sh's awk, one for one (a line is judged on its own, with
-- two pieces of state carried down the file):
--   * comment lines are skipped;
--   * `NAME=plan/index.d/...` (or loop_status.d) records NAME as a ledger var;
--   * `cd $ROOT` (or REPO_ROOT, PROJECT_ROOT, or `$(dirname ...)/..`) makes the
--     cwd LIVE until another `cd`; a same-line `( cd ...` subshell is local;
--   * a write is `>`, `>>`, `tee [-a]` or `touch` followed by a target. It is a
--     violation when the target is $ROOT/plan/(index|loop_status).d/..., or
--     $ROOT/$LEDGERVAR..., or, with a live cwd, plan/... or a bare $LEDGERVAR.
--     The first violation on a line is reported and the line is done.
-- As in the awk, `.` in "index.d" matches any character.
--
-- Grammar, unchanged:
--   violation:fixture-writes-live-ledger:<file>:<line>   (one per offending line)
--   ok:fixtures-write-scaffolds-only:<n> checked          exit 0
--   refused:fixtures-write-live-ledger:<hits>             exit 1 (remedy on stderr)
--
-- Usage: tillandsias-plan script run scripts/lua/check-no-fixture-writes-live-ledger.lua [-- <file>...]

local files = {}
if arg and arg[1] then
    for i = 1, #arg do files[#files + 1] = arg[i] end
else
    for _, f in ipairs(fs.walk("scripts", { suffix = ".sh" }) or {}) do
        local b = path.basename(f)
        if b:match("^test%-.*%.sh$") and path.dirname(f) == "scripts" then files[#files + 1] = f end
    end
    table.sort(files)
end

local ROOTS = { "ROOT", "REPO_ROOT", "PROJECT_ROOT" }
local function ledger(p) return p:match("^plan/index.d/") ~= nil or p:match("^plan/loop_status.d/") ~= nil end
local function clean(t)
    t = t:gsub("[\"']", "")
    return (t:gsub("^%./", "", 1))
end
-- `$ROOT/`, `${ROOT}/`, `$ROOT}/` (awk's \{? and \}? are independent); returns the rest
local function strip_rootvar(t)
    for _, r in ipairs(ROOTS) do
        for _, pre in ipairs({ "$" .. r, "${" .. r }) do
            for _, close in ipairs({ "/", "}/" }) do
                local p = pre .. close
                if t:sub(1, #p) == p then return t:sub(#p + 1) end
            end
        end
    end
    return nil
end
local function leading_var(t) -- `$NAME` or `${NAME`; returns NAME and what follows it
    local name, after = t:match("^%${?([%a_][%w_]*)}?(.*)$")
    return name, after
end

local function judge(file, body)
    local hits = {}
    local relvar, livecwd = {}, false
    local nr = 0
    for _, line in ipairs(text.lines(body)) do
        nr = nr + 1
        if not line:match("^%s*#") then
            local v = line:match("^%s*([%a_][%w_]*)=[\"']?plan/index.d/")
                or line:match("^%s*([%a_][%w_]*)=[\"']?plan/loop_status.d/")
            if v then relvar[v] = true end

            -- localcd: `( cd ` not preceded by `$` (so not `$( cd`)
            local localcd = false
            local i = 1
            while true do
                local s = line:find("%(%s*cd%s", i)
                if not s then break end
                if s == 1 or line:sub(s - 1, s - 1) ~= "$" then localcd = true; break end
                i = s + 1
            end
            if not localcd then
                local has_cd = false
                i = 1
                while true do
                    local s = line:find("cd%s+", i)
                    if not s then break end
                    local prev = s == 1 and "" or line:sub(s - 1, s - 1)
                    if prev == "" or prev:match("[;&%s]") then has_cd = true; break end
                    i = s + 1
                end
                if has_cd then
                    local live = false
                    for _, r in ipairs(ROOTS) do
                        for _, pre in ipairs({ "$" .. r, "${" .. r }) do
                            local pos = 1
                            while true do
                                local a, b = line:find("cd%s+\"?", pos)
                                if not a then break end
                                local rest = line:sub(b + 1)
                                if rest:sub(1, #pre) == pre then
                                    local after = rest:sub(#pre + 1):gsub("^}", "", 1):gsub("^\"", "", 1)
                                    if after == "" or after:match("^[%s;|&)]") then live = true end
                                end
                                pos = a + 1
                            end
                        end
                    end
                    if not live and line:find("cd%s+\"?%$%(dirname[^)]*%)/%.%.") then live = true end
                    livecwd = live
                end
            end

            local function live_target(t)
                t = clean(t)
                local rest = strip_rootvar(t)
                if rest then
                    if ledger(rest) then return true end
                    local name = leading_var(rest)
                    if name and relvar[name] then return true end
                    return false
                end
                if not livecwd or localcd then return false end
                if ledger(t) then return true end
                local name, after = leading_var(t)
                if name and (after == "" or after:sub(1, 1) == "/") and relvar[name] and not t:find("/", 1, true) then
                    return true
                end
                return false
            end

            -- writes: (>>?|tee(\s+-a)?|touch)\s*["']?[^\s;|&)<>]+ , leftmost first
            local s = line
            local done = false
            while not done do
                local best_s, best_e, w
                local n = #s
                for p = 1, n do
                    local op_e
                    if s:sub(p, p + 1) == ">>" then op_e = p + 1
                    elseif s:sub(p, p) == ">" then op_e = p
                    elseif s:sub(p, p + 2) == "tee" then
                        op_e = p + 2
                        local a, b = s:find("^%s+%-a", p + 3)
                        if a then op_e = b end
                    elseif s:sub(p, p + 4) == "touch" then op_e = p + 4
                    end
                    if op_e then
                        local q = op_e + 1
                        local _, sp = s:find("^%s*", q); q = sp + 1
                        local qs = q
                        if s:sub(q, q) == '"' or s:sub(q, q) == "'" then q = q + 1 end
                        local a, b = s:find("^[^%s;|&)<>]+", q)
                        if a then best_s, best_e, w = p, b, s:sub(qs, b); break end
                        -- `tee -a` may also match as plain `tee` with the
                        -- `-a` as its target: awk takes the longest at p.
                        if s:sub(p, p + 2) == "tee" then
                            local q2 = p + 3
                            local _, sp2 = s:find("^%s*", q2); q2 = sp2 + 1
                            local qs2 = q2
                            if s:sub(q2, q2) == '"' or s:sub(q2, q2) == "'" then q2 = q2 + 1 end
                            local a2, b2 = s:find("^[^%s;|&)<>]+", q2)
                            if a2 then best_s, best_e, w = p, b2, s:sub(qs2, b2); break end
                        end
                    end
                end
                if not best_s then break end
                if w:sub(1, 1) ~= "&" and w ~= "/dev/null" and live_target(w) then
                    hits[#hits + 1] = "violation:fixture-writes-live-ledger:" .. file .. ":" .. nr
                    done = true
                else
                    s = s:sub(best_e + 1)
                end
            end
        end
    end
    return hits
end

local total, n = 0, 0
for _, f in ipairs(files) do
    if fs.exists(f) then
        n = n + 1
        local rel = f:gsub("^%./", "")
        for _, h in ipairs(judge(rel, fs.read(f) or "")) do
            out.line(h); total = total + 1
        end
    end
end

if total == 0 then
    out.line("ok:fixtures-write-scaffolds-only:" .. n .. " checked")
    verdict.emit("ok:fixtures-write-scaffolds-only", 0)
end
out.line("refused:fixtures-write-live-ledger:" .. total)
log.raw("  remedy: plant the probe in a scaffold (a copied plan tree under mktemp or target/, as scripts/test-pending-capability-row-does-not-wedge.sh does) and assert the live plan/ unchanged")
verdict.emit("refused:fixtures-write-live-ledger", 1)
