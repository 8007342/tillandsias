-- @trace order:971-7muc, order:2387-lrg2
-- @env PATH HOME
--
-- test-ledger-prose-roundtrip.lua — does the ledger store the prose it was given, byte for
-- byte, including the characters a shell would have eaten? (971-7muc). Ported from
-- test-ledger-prose-roundtrip.sh (2387-lrg2); same arms, in its order.
--
-- The defect: an append-event summary passed as a shell argument had backtick-quoted tokens
-- command-substituted away before the program started, and the stored text read "only  licenses
-- reading accel_mem_budget_gb as the whole machine". Valid YAML and plausible prose: every
-- instrument passed it. Only a byte-identity assertion can see it.
--
--   1  --summary-file round-trips backticks, $(...) and $VAR byte-identically
--   2  --summary-file - (stdin) does the same
--   3  the argv path REFUSES residue: an unbalanced backtick, and a literal $(
--   4  the argv path still accepts correctly-quoted balanced prose
--   5  NEGATIVE CONTROL: the historical mangling, reproduced through a real shell, is silent
--
-- Each arm writes into its own scratch ledger, so no arm reads another's fragment.
--
-- GRAMMAR ok:ledger-prose-roundtrip:<n> arms | violation:ledger-prose-roundtrip:<n>-failed
--       | skip:ledger-prose-roundtrip:no-plan-binary

local fixture = require "common.fixture"
local T = fixture.new("ledger-prose-roundtrip")
local ROOT = fixture.repo_root()
local BIN = fixture.plan_binary()
if BIN == "" then T:skip("no-plan-binary") end
-- ABSOLUTE: the probe may answer repo-relative, and the cases run from a scratch directory.
if not fixture.is_abs(BIN) then BIN = ROOT .. "/" .. BIN:gsub("^%./", "") end

local PROSE = "Only `accel_mem_budget_gb` licenses reading it as the whole machine.\n"
    .. "A card will read $(nproc) and $HOME, and that is the correct answer.\n"
    .. "Trailing `balanced` pair."
local INDEX = [[
packets:
  - packet_id: roundtrip-fixture
    order: 000-test
    status: ready
    title: |
      fixture
]]

local function ledger()
    local w = T:scratch()
    fs.write(w.rel .. "/index.yaml", INDEX)
    fs.write(w.rel .. "/note.md", PROSE)
    return w
end
local function append(w, extra, stdin)
    local a = { BIN, "--index", w.abs .. "/index.yaml", "append-event", "roundtrip-fixture", "note" }
    for _, x in ipairs(extra) do a[#a + 1] = x end
    a[#a + 1] = "--host"; a[#a + 1] = "testhost"
    a.cwd, a.stdin, a.env_unset = w.abs, stdin, { "TILLANDSIAS_*" }
    a.env = { TILLANDSIAS_AGENT_ID = "linux-testhost-opus5-20260903t054300z" }
    local r = T:run(a)
    return r.code, (r.stdout or "") .. (r.stderr or "")
end
local function stored(w)
    local parts = {}
    for _, f in ipairs(fs.list(w.rel .. "/index.d") or {}) do
        if f:match("%.yaml$") then parts[#parts + 1] = fs.read(w.rel .. "/index.d/" .. f:match("[^/]+$")) or "" end
    end
    return table.concat(parts, "\n")
end
-- The body of the `summary: |` block scalar, its 8-space indent removed.
local function summary_body(s)
    local got, insum = {}, false
    for _, l in ipairs(text.lines(s)) do
        if l:match("^%s*summary: |") then insum = true
        elseif insum then
            if l ~= "" and not l:match("^        ") then insum = false
            else got[#got + 1] = (l:gsub("^        ", "")) end
        end
    end
    while #got > 0 and got[#got] == "" do got[#got] = nil end
    return table.concat(got, "\n")
end

-- 1
local w = ledger()
local rc, out = append(w, { "--summary-file", w.abs .. "/note.md" })
local s = stored(w)
local got = summary_body(s)
T:arm("1 --summary-file round-trips backticks, $(...) and $VAR byte-identically",
    s ~= "" and got == PROSE, "rc=" .. tostring(rc) .. " out='" .. out .. "' got first line: '" .. (text.lines(got)[1] or "") .. "'")

-- 2
w = ledger()
rc, out = append(w, { "--summary-file", "-" }, PROSE)
s = stored(w)
T:arm("2 --summary-file - (stdin) preserves backticks and $(...)",
    text.contains(s, "accel_mem_budget_gb") and text.contains(s, "$(nproc)") and text.contains(s, "`balanced`"),
    "stdin path lost characters: " .. out)

-- 3
w = ledger()
rc, out = append(w, { "--summary", "lost the closing ` here" })
T:arm("3 argv path REFUSES an unbalanced backtick", rc ~= 0 and text.contains(out, "unbalanced backtick"), "rc=" .. tostring(rc))
rc, out = append(w, { "--summary", "a literal $(hostname) survived" })
T:arm("3 argv path REFUSES a literal $(", rc ~= 0 and text.contains(out, "command substitution"), "rc=" .. tostring(rc))

-- 4
w = ledger()
rc, out = append(w, { "--summary", "a `balanced` pair is correct quoting" })
T:arm("4 argv path still accepts balanced backticks (correct single-quoting)", rc == 0, out)

-- 5: the hazardous form through a real shell; the word vanishes with no error. A script file,
-- not `sh -c` (the runner refuses a command string).
w = T:scratch()
fs.write(w.rel .. "/hazard.sh", 'printf "%s" "only `printf %s ""` licenses reading it"\n')
local r = T:run{ fixture.posix_shell("sh"), w.abs .. "/hazard.sh" }
T:arm("5 negative control: the shell silently deletes backticked text (no error)",
    r.code == 0 and r.stdout == "only  licenses reading it", "got: '" .. tostring(r.stdout) .. "'")

T:finish()
