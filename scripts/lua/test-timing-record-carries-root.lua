-- @env PATH HOME SystemRoot
-- @trace order:1299-s2sv, order:1268-m2ir, spec:methodology-accountability, order:2150-vf2v, order:2367-d5gx
--
-- test-timing-record-carries-root.lua — a timing record says which checkout wrote it. On 2026-09-18
-- four records landed in /tmp and nothing in them said from where. The canonical read is
-- `.root // .root_unusable`; ABSENT MEANS PRE-FIELD, never /tmp. Ported from the .sh of the same name;
-- its arm 4a asserted jq's own null handling and has no subject here.
--
-- Usage: tillandsias-plan script run scripts/lua/test-timing-record-carries-root.lua
-- Verdict: ok:timing-record-root:<n> arms | violation:timing-record-root:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("timing-record-root")
local SH, ROOT = fixture.posix_shell(), fixture.repo_root()
local EMITTER = "scripts/cycle-metrics.sh"
if not fs.exists(EMITTER) then T:refuse("subject-missing") end
local W = T:scratch()

-- 2150-vf2v: every metrics log cycle-metrics.sh reads is pinned to an empty scratch file.
local function pinned(extra)
    local e = { PATH = env.get("PATH"), HOME = env.get("HOME") }
    for _, n in ipairs{ "TILLANDSIAS_EXPERT_USAGE_LOG", "TILLANDSIAS_CYCLE_FLOW_LOG", "TILLANDSIAS_EXPERT_HEALTH_LOG" } do
        fs.write(W.rel .. "/" .. n .. ".jsonl", "")
        e[n] = W.abs .. "/" .. n .. ".jsonl"
    end
    for k, v in pairs(extra) do e[k] = v end
    return e
end
local function sh(argv, e, stdin)
    table.insert(argv, 1, SH)
    local r = proc.run{ argv = argv, cwd = ROOT, env = pinned(e), env_unset = { "TILLANDSIAS_*", "PROJECT_ROOT" },
        stdin = stdin, timeout_ms = 120000 }
    return r.code, r.stdout or "", r.stderr or ""
end
local function record(s)
    local ok, j = pcall(json.parse, text.trim(s))
    return ok and type(j) == "table" and j or {}
end
local function where(r) return r.root or r.root_unusable end
-- One record through the real emitter, from the checkout at W/<dir>.
local function emit(dir, emitter, log)
    log = log or dir .. ".jsonl"
    local rc, _, err = sh({ emitter or (ROOT .. "/" .. EMITTER), "--emit-timing", "step=" .. dir, "phase=test", "duration_ms=5", "exit=0" },
        { TILLANDSIAS_TIMING_LOG = W.abs .. "/" .. log, PROJECT_ROOT = W.abs .. "/" .. dir })
    if rc ~= 0 or not fs.exists(W.rel .. "/" .. log) then T:refuse("emitter-wrote-nothing", "rc=" .. tostring(rc) .. " " .. err) end
    return fs.read(W.rel .. "/" .. log)
end

fs.mkdir(W.rel .. "/checkout/.git")
local line = emit("checkout")
T:arm("1 a .git-directory checkout answers with its own path", record(line).root == W.abs .. "/checkout", line)
-- A linked worktree's .git is a FILE: the shape that broke the resolver in 1268-m2ir.
fs.mkdir(W.rel .. "/worktree")
fs.write(W.rel .. "/worktree/.git", "gitdir: " .. ROOT .. "/.git/worktrees/probe\n")
line = emit("worktree")
T:arm("2 a linked worktree answers with its own path", record(line).root == W.abs .. "/worktree", line)

-- 3 the resolver pointed at a root that is not a checkout.
fs.mkdir(W.rel .. "/outside/nested")
local LIB = fs.read("scripts/metrics-log-path.sh"):gsub("\r\n", "\n")
local function fallback(lib)
    fs.write(W.rel .. "/outside/nested/metrics-log-path.sh", lib)
    local _, o, e = sh({ "-s", "--", W.abs .. "/outside/nested" }, {}, 'cd "$1" || exit 9\n. ./metrics-log-path.sh\n'
        .. 'p="$(metrics_default_log tillandsias-timing.jsonl "" 2>/dev/null)"\nprintf \'{"step":"arm3"%s}\' "$(metrics_root_fields "$p")"\n')
    return record(o), o .. e
end
local r, raw = fallback(LIB)
T:arm("3 a fallback record is never silent about where", r.root == nil and (r.root_unusable or "") ~= "", raw)
T:arm("3 and says why", (r.fallback_reason or "") ~= "", raw)

-- 4 the preserved 2026-09-18 records, verbatim, against the same records with the field.
local HOST = '"host":"macuahuitl.ayahuitlcalpan.com"'
local corpus = {}
for _, x in ipairs{ { "2026-09-18T21:17:42Z", "litmus:credential-isolation", "all", 88 },
    { "2026-09-18T21:17:42Z", "litmus:opencode-web-session-otp-shape", "all", 90 },
    { "2026-09-18T21:17:42Z", "litmus-suite", "all", 210 }, { "2026-09-18T21:21:53Z", "litmus-suite", "pre-build", 286740 } } do
    corpus[#corpus + 1] = '{"ts":"' .. x[1] .. '",' .. HOST .. ',"step":"' .. x[2] .. '","phase":"' .. x[3] .. '","duration_ms":' .. x[4] .. ',"exit":0'
end
fs.write(W.rel .. "/without.jsonl", table.concat(corpus, "}\n") .. "}\n")
fs.write(W.rel .. "/with.jsonl", table.concat(corpus, ',"root":"/some/checkout"}\n') .. ',"root":"/some/checkout"}\n')
-- The metrics, not source=<path>: the two corpora are different files.
local function read_verdict(f)
    local _, o = sh({ ROOT .. "/" .. EMITTER, "--no-experts", "--no-repo-scan" }, { TILLANDSIAS_TIMING_LOG = W.abs .. "/" .. f })
    return ((("\n" .. o):match("\n(timing:[^\r\n]*)") or ""):gsub(" source=%S*", ""))
end
local without = read_verdict("without.jsonl")
if without == "" then
    out.line("skip: 4 the timing reader printed no verdict here, so the comparison would prove nothing")
else
    local with = read_verdict("with.jsonl")
    T:arm("4 the reader's verdict is the same with the field and without", with == without, without .. " / " .. with)
end

-- MUTATION
local function swap(from, to)
    local a, b = LIB:find(from, 1, true)
    if not a then T:refuse("mutation-anchor-missing", from) end
    return LIB:sub(1, a - 1) .. to .. LIB:sub(b + 1)
end
r, raw = fallback(swap('        /tmp/*)\n', '        /no-such-prefix/*)\n'))
T:arm("5 MUTATION without the fallback branch the record is silent", where(r) == nil or r.fallback_reason == nil, raw)

-- 6 a checkout's own log names that checkout, whatever root the process was handed.
fs.mkdir(W.rel .. "/checkout/.cache/metrics")
line = emit("worktree", nil, "checkout/.cache/metrics/t.jsonl")
T:arm("6 a record in a checkout's own log answers with that checkout", record(line).root == W.abs .. "/checkout", line)

T:finish()
