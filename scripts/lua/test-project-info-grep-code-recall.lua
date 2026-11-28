-- @trace order:1388-pfys, order:2380-psba
-- @env PATH HOME TMPDIR
--
-- test-project-info-grep-code-recall.lua — project-info's grep_code must never answer
-- "No matches found" for a string that exists. Ported from
-- test-project-info-grep-code-recall.sh (2380-psba); same fourteen arms.
--
-- WHY. Measured from inside a forge 2026-09-26: grep_code said "No matches found" for six
-- strings git grep finds (a `find | head -200` file cap, the pattern read as a BASIC regex,
-- errors and empty file sets reported as absence, `result` not reset per call). The server
-- is driven HERMETICALLY over stdio (one initialize + tools/call lines), never a live MCP.
-- H1-H5 need a tree OUTSIDE any git work tree (the .sh used $TMPDIR): kit scratch sits in
-- this checkout's ignored target/, so GIT_CEILING_DIRECTORIES hides the checkout from the
-- server there and it takes find's file set, not git's (a recursive rm outside the
-- workspace is a consent-gated policy refusal, so the trees stay in scratch). L1-L8 replay the survey's queries against this
-- checkout and demand PARITY with `git grep -InE --untracked` over the same file set
-- (a different tool, so the oracle is not the subject; .claude/worktrees excluded, 1515-e49s).
--
--   H1  all 260 files searched, truncation announced with the true count
--   H2  a|b alternation matches (extended regex)
--   H3  a zero-file-set call after a hit call names the empty set, no stale result
--   H4  an invalid pattern is named, not an absence
--   H6  git tree: tracked+untracked searched, ignored target/ not, path glob filters
--   H5  control: an absent string -> No matches found
--   L1-L8  live parity with the oracle (hits named only from the truth; cap announced)
--
-- GRAMMAR ok:project-info-grep-code-recall:<n> arms
--       | violation:project-info-grep-code-recall:<n>-failed
--       | refused:project-info-grep-code-recall:no-server | skip:...:no-jq

local fixture = require "common.fixture"
local T = fixture.new("project-info-grep-code-recall")
local ROOT, SH = fixture.repo_root(), fixture.posix_shell()
local SERVER_REL = "images/default/config-overlay/mcp/project-info.sh"
if not fs.exists(SERVER_REL) then T:refuse("no-server", SERVER_REL) end
local SERVER = ROOT .. "/" .. SERVER_REL
if not fixture.which("jq") then T:skip("no-jq") end   -- the server parses its args with jq
local TMP = env.get("TMPDIR")

-- Temp trees in kit scratch (removed by T:finish). The scratch root sits inside this
-- checkout's work tree, so the find-regime arms pin GIT_CEILING_DIRECTORIES at it: git then
-- finds no work tree above the hermetic tree, as under the .sh's $TMPDIR. gtree has its own
-- .git, found before the ceiling.
local W = T:scratch()
local WORK = W.abs
local CEIL = WORK:match("^(.*)/[^/]+$")
fs.mkdir(W.rel .. "/tree/d")
for i = 1, 260 do fs.write(W.rel .. "/tree/d/f" .. i .. ".txt", "x\nneedle-" .. i .. "\n") end
fs.write(W.rel .. "/tree/alpha.txt", "only alpha here\n")
local G = WORK .. "/gtree"
fs.mkdir(W.rel .. "/gtree/src"); fs.mkdir(W.rel .. "/gtree/target")
T:must{ "git", "-C", G, "init", "-q" }
fs.write(W.rel .. "/gtree/.gitignore", "target/\n")
fs.write(W.rel .. "/gtree/src/a.txt", "probe-h6 tracked\n")
T:must{ "git", "-C", G, "add", "-A" }
T:must{ "git", "-C", G, "-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false", "commit", "-qm", "a" }
fs.write(W.rel .. "/gtree/src/b.txt", "probe-h6 untracked\n")
fs.write(W.rel .. "/gtree/target/c.txt", "probe-h6 ignored\n")
local function finish() T:finish() end

-- One server session, one grep_code call per args table; returns the answers' texts.
local function gc_session(cwd, ...)
    local e = { TMPDIR = TMP, TILLANDSIAS_EXPERT_HEALTH_LOG = WORK .. "/h.jsonl", TILLANDSIAS_EXPERT_USAGE_LOG = WORK .. "/u.jsonl" }
    if cwd ~= ROOT then e.GIT_CEILING_DIRECTORIES = CEIL end
    local req = { '{"jsonrpc":"2.0","id":1,"method":"initialize"}' }
    for i, a in ipairs({ ... }) do
        req[#req + 1] = json.encode({ jsonrpc = "2.0", id = i + 1, method = "tools/call",
            params = { name = "grep_code", arguments = a } })
    end
    local r = T:run{ SH, SERVER, cwd = cwd, stdin = table.concat(req, "\n") .. "\n", timeout_ms = 300000,
        env_unset = { "TILLANDSIAS_*" },
        env = e }
    local answers = {}
    for _, l in ipairs(text.lines(r.stdout or "")) do
        local ok, m = pcall(json.parse, l)
        if ok and type(m) == "table" and m.id ~= 1 then
            local t = type(m.result) == "table" and type(m.result.content) == "table"
                and type(m.result.content[1]) == "table" and m.result.content[1].text
            if type(t) ~= "string" then
                t = type(m.error) == "table" and type(m.error.message) == "string" and m.error.message or "<no-text>"
            end
            answers[#answers + 1] = t
        end
    end
    return answers
end
local function gc(cwd, a) return gc_session(cwd, a)[1] or "" end
local function args(p, i, d) return { pattern = p, include = i, path = d } end
local function first(s) return (s or ""):match("^[^\n]*") end
local function has_line(s, re) return text.is_match(s or "", "(?m)" .. re) end

local TR = WORK .. "/tree"

-- H1: every file searched; 260 hits, so the cap must be ANNOUNCED with the true count.
local o = gc(TR, args("needle-[0-9]+", "*.txt", "d"))
T:arm("H1 all 260 files searched, truncation announced", text.contains(o, "showing 50 of 260 matches"),
    "expected 'showing 50 of 260 matches', got: " .. ((o:gsub("\n+$", "")):match("[^\n]*$") or ""))

-- H2: extended regex — alternation matches (pre-fix: BRE, a|b literal).
o = gc(TR, args("alpha|beta", "*.txt", "."))
T:arm("H2 a|b alternation matches (extended regex)", text.contains(o, "alpha.txt:1:only alpha here"), first(o))

-- H3: a zero-hit call after a hit call must not return the previous answer.
local s = gc_session(TR, args("alpha", "*.txt", "."), args("alpha", "*.nomatch", "."))
o = s[2] or ""
T:arm("H3 empty file set named, no stale result",
    not text.contains(o, "alpha.txt") and text.contains(o, "no file matches include"),
    text.contains(o, "alpha.txt") and "stale result: second call returned the first call's hits" or first(o))

-- H4: an invalid pattern is an error, not an absence.
o = gc(TR, args("foo(", "*.txt", "."))
T:arm("H4 invalid pattern named", text.contains(o, "invalid extended regex"), first(o))

-- H6 (2151-gcls): inside a git work tree the file set is git's. Premise first.
local prem = T:run{ "git", "-C", G, "check-ignore", "-q", "target/c.txt" }
if prem.code ~= 0 then
    T:arm("H6 git tree: tracked+untracked searched, ignored target/ not, path glob filters", false,
        "premise: target/c.txt is not ignored")
else
    o = gc(G, args("probe-h6", "*.txt", "."))
    local set_ok = has_line(o, [[^\./src/a\.txt:1:]]) and has_line(o, [[^\./src/b\.txt:1:]])
        and not text.contains(o, "target/c.txt")
    local o2 = set_ok and gc(G, args("probe-h6", "src/*.txt", ".")) or ""
    T:arm("H6 git tree: tracked+untracked searched, ignored target/ not, path glob filters",
        set_ok and text.count_lines(o2, [[^\./src/]]) == 2,
        set_ok and ("path glob: " .. o2) or ("git file set: " .. o:sub(1, 160)))
end

-- H5: control — a genuinely absent string still says No matches found.
o = gc(TR, args("zzz-absent-zzz", "*.txt", "."))
T:arm("H5 absent string -> No matches found", has_line(o, "^No matches found"), first(o))

-- Live parity. truth: git's file set read by git grep, spelled as find would print it.
local function truth(p, inc, path)
    local ps, pfx = nil, ""
    if path == "." then pfx = "./"; ps = ":(glob)**/" .. inc else ps = ":(glob)" .. path .. "/**/" .. inc end
    if inc == "*" then ps = path end
    local r = T:run{ "git", "grep", "-InE", "--untracked", "-e", p, "--", ps, cwd = ROOT, timeout_ms = 300000 }
    local out = {}
    for _, l in ipairs(text.lines(r.stdout or "")) do
        local sp = pfx .. l
        if not text.is_match(sp, [[^(\./)?\.claude/worktrees/]]) then out[#out + 1] = sp end
    end
    return out
end
local function live(label, p, inc, path)
    local want = truth(p, inc, path)
    local got = gc(ROOT, args(p, inc, path))
    local nwant = 0
    for _, l in ipairs(want) do if l ~= "" then nwant = nwant + 1 end end
    if nwant == 0 then
        T:arm(label .. " truth=0 -> No matches found", has_line(got, "^No matches found"), first(got):sub(1, 120))
        return
    end
    if has_line(got, "^(No matches found|grep_code:)") then
        T:arm(label .. " parity with grep", false, "FALSE NEGATIVE: truth has " .. nwant .. " hit(s) (e.g. "
            .. (want[1]:match("^[^:]*:[^:]*") or "") .. "), answer: " .. first(got):sub(1, 100))
        return
    end
    local files = {}
    for _, l in ipairs(want) do files[l:match("^[^:]*")] = true end
    local bad_f
    for _, l in ipairs(text.lines(got)) do
        if not text.starts_with(l, "[truncated") then
            local f = l:match("^[^:]*")
            if f ~= "" and not files[f] then bad_f = f end
        end
    end
    if bad_f then T:arm(label .. " parity with grep", false, "answer names " .. bad_f .. ", which the truth does not"); return end
    if nwant > 50 and not text.contains(got, "showing 50 of " .. nwant .. " matches") then
        T:arm(label .. " parity with grep", false, "truth=" .. nwant .. " > cap but truncation not announced with the true count")
        return
    end
    T:arm(label .. " parity with grep (truth=" .. nwant .. ")", true)
end
live("L1 q24 GIT_TRACE",      "GIT_TRACE", "*.yaml", "plan")
live("L2 q25 json-get",       "json-get-absent|json verb", "*", "plan")
live("L3 q26 analyze-bands",  "analyze-bands", "*", "plan")
live("L4 q27 dashboard",      "update-convergence-dashboard.*(locale|printf)|pct_display", "*", "plan")
live("L5 q28 measure-bands",  "measure-bands", "*", "plan")
live("L6 q30 grammar string", "does not match the configured branch-creation grammar", "*", ".")
live("L7 q29 control a",      "push-plan-fragments.*untracked|untracked.*push-plan-fragments", "*", "plan")
live("L8 q29 control b",      "does not match the configured branch-creation grammar|work/\\* .*grammar", "*", "plan")

finish()
