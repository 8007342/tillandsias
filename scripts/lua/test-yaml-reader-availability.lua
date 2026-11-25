-- @env PATH HOME
-- @trace order:746-htj9, order:1247-sv4d, order:2344-64wz
--
-- test-yaml-reader-availability.lua — the sanctioned YAML reader runs HERE, and a file that will not
-- load is never reported as a vocabulary mismatch (720-24u6). Ported from the .sh of the same name.
--
--   1-7   the availability check, the real ledger, and the reader's own verdicts
--   8-9   the gate names a missing reader; yaml-type speaks yq's vocabulary
--   12-17 each check-plan-schema-divergence refusal says why: and remedy: on stderr, and the
--         remedy, EXECUTED, clears it (1247-amcu)
--   18    MUTATION: each distinction, removed from the gate, changes an arm's answer
--
-- Usage: tillandsias-plan script run scripts/lua/test-yaml-reader-availability.lua
-- Verdict: ok:yaml-reader-availability:<n> arms | violation:yaml-reader-availability:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("yaml-reader-availability")
local SH, ROOT, PLAN = fixture.posix_shell(), fixture.repo_root(), fixture.plan_binary()
if PLAN == "" then T:refuse("no-plan-binary") end
local GATE = "scripts/lua/check-plan-schema-divergence.lua"
local d = T:scratch()
local W = d.abs

-- Literal pieces found in order; the first is at the start ("" to not anchor).
local function matches(s, want)
    local at = 1
    for i, w in ipairs(want) do
        local a, b = s:find(w, at, true)
        if not a or (i == 1 and a ~= 1) then return false end
        at = b + 1
    end
    return true
end
local function first(s) return (s or ""):match("^[^\r\n]*") or "" end
local function reader(verb, file, path) return T:run{ PLAN, verb, file, path, cwd = ROOT } end
local function arm(name, want, r)
    local got = first((r.stdout or "") .. (r.stderr or ""))
    T:arm(name, matches(got, want), got)
end
-- The gate, read through <bin> (default this reader), from <cwd>.
local function gate(args, o)
    o = o or {}
    local argv = { PLAN, "script", "run", o.script or (ROOT .. "/" .. GATE), "--" }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    return proc.run{ argv = argv, cwd = o.cwd or ROOT, timeout_ms = 60000, env_unset = { "TILLANDSIAS_*" },
        env = { PATH = env.get("PATH"), HOME = env.get("HOME"), PWD = o.cwd or ROOT, TILLANDSIAS_PLAN_BIN = o.bin or PLAN } }
end
local function put(name, body) fs.write(d.rel .. "/" .. name, body); return W .. "/" .. name end
local INDEX, SCHEMA = "plan_index:\n  default_status_values: [pending, ready, done]\n", "statuses: [pending, ready, done]\n"

local av = T:run{ SH, "scripts/check-yaml-reader-availability.sh", cwd = ROOT, env = { TILLANDSIAS_PLAN_BIN = PLAN } }
T:arm("1 the reader is available here", av.code == 0 and matches(first(av.stdout), { "ok:yaml-reader:" }),
    tostring(av.stdout) .. tostring(av.stderr))
arm("2 the real ledger loads", { "ok:yaml-loads:plan/index.yaml" }, reader("validate-yaml", "plan/index.yaml"))
arm("3 and its vocabulary reads", { "pending ready " }, reader("yaml-get", "plan/index.yaml", "plan_index.default_status_values"))
local bad = put("bad.yaml", "a: [1,\n")
arm("4 malformed is load-failed", { "blocked:yaml-load-failed:" }, reader("validate-yaml", bad))
arm("4 malformed through yaml-get too", { "blocked:yaml-load-failed:" }, reader("yaml-get", bad, "statuses"))
arm("5 and through the gate, never a divergence", { "blocked:index-load-failed:" }, gate{ bad, "plan/schema.yaml" })
local miss = reader("yaml-get", "plan/index.yaml", "no.such.key")
T:arm("6 a missing key is empty, rc 0", miss.code == 0 and text.trim(miss.stdout or "") == "", tostring(miss.code) .. " " .. tostring(miss.stdout))
arm("7 an absent file is unreadable, not unparseable", { "blocked:yaml-unreadable:" }, reader("validate-yaml", W .. "/nope.yaml"))
arm("8 a missing reader is named", { "blocked:index-load-failed:", "sanctioned YAML reader" }, gate({}, { bin = W .. "/no-such-binary" }))
arm("9 yaml-type of a fragment", { "!!map" }, reader("yaml-type", put("frag.yaml", "packets:\n  - packet_id: fixture\n")))
arm("9 yaml-type of a sequence", { "!!seq" }, reader("yaml-type", put("seq.yaml", "- a\n- b\n")))
arm("9 yaml-type of a broken file", { "blocked:yaml-load-failed:" }, reader("yaml-type", bad))

local function afford(name, wantv, wante, r)
    local o, e = first(r.stdout), r.stderr or ""
    T:arm(name, r.code == 1 and matches(o, wantv) and matches(e, { "", "  why: ", "  remedy: " }) and matches(e, { "", table.unpack(wante) }),
        tostring(r.code) .. " " .. o .. " | " .. e)
end
local function cleared(name, index, schema)
    local r = gate{ index, schema }
    T:arm(name .. ": the remedy clears it", r.code == 0 and text.trim((r.stdout or "") .. (r.stderr or "")) == "ok:status-vocab-in-sync",
        tostring(r.stdout) .. tostring(r.stderr))
end
local index, schema = put("index.yaml", INDEX), put("schema.yaml", SCHEMA)

fs.mkdir(d.rel .. "/empty")
afford("12 absent inputs", { "blocked:status-vocab-diverges: could not read" },
    { "plan/index.yaml and plan/schema.yaml is not a file", "name both files" }, gate({}, { cwd = W .. "/empty" }))
cleared("12 absent inputs", index, schema)
afford("13 no reader", { "blocked:index-load-failed:", "sanctioned YAML reader" },
    { "remedy: cargo build --release -p tillandsias-plan, or set TILLANDSIAS_PLAN_BIN" }, gate({ index, schema }, { bin = W .. "/no-such-binary" }))
cleared("13 no reader", index, schema)
local broken = put("broken.yaml", "plan_index:\n  default_status_values: [pending, ready, done\n")
afford("14 an unparseable index", { "blocked:index-load-failed: " .. broken .. ": " },
    { "not a vocabulary divergence", "validate-yaml" }, gate{ broken, schema })
put("broken.yaml", INDEX)
arm("14 validate-yaml agrees once fixed", { "ok:yaml-loads:" .. broken }, reader("validate-yaml", broken))
cleared("14 an unparseable index", broken, schema)
local drift = put("drift.yaml", "plan_index:\n  default_status_values: [pending, ready, archived]\n")
afford("15 a divergence names each side", { "blocked:status-vocab-diverges: " },
    { "only in " .. drift .. ": (archived); only in " .. schema .. ": (done)", "remedy: make" }, gate{ drift, schema })
put("drift.yaml", INDEX)
cleared("15 a divergence", drift, schema)
local order = put("order.yaml", "plan_index:\n  default_status_values: [ready, pending, done]\n")
afford("16 a different order is a divergence and says so", { "blocked:status-vocab-diverges: " },
    { "same statuses, in a different order" }, gate{ order, schema })
local novocab, noschema = put("novocab.yaml", "plan_index:\n  other: 1\n"), put("noschema.yaml", "other: 1\n")
afford("17 two absent vocabularies are not in sync", { "blocked:status-vocab-absent: " .. novocab .. ": plan_index.default_status_values" },
    { "no vocabulary to compare", "remedy: add plan_index.default_status_values" }, gate{ novocab, noschema })

-- MUTATION, while both vocabularies are still absent and bad.yaml is still broken.
local src = fs.read(GATE):gsub("\r\n", "\n")
local function mutant(name, from, to)
    local a, b = src:find(from, 1, true)
    if not a then T:refuse("mutation-anchor-missing", name) end
    return put(name .. ".lua", src:sub(1, a - 1) .. to .. src:sub(b + 1))
end
arm("18 MUTATION a gate that takes empty for a vocabulary says in sync", { "ok:status-vocab-in-sync" },
    gate({ novocab, noschema }, { script = mutant("empty-ok", 'if out == "" then', "if false then") }))
arm("18 MUTATION a gate that ignores the load failure calls it something else", { "blocked:status-vocab-" },
    gate({ bad, schema }, { script = mutant("load-ok", 'if r.status ~= "exited" or r.code ~= 0 then\n        local first',
        'if false then\n        local first') }))

put("novocab.yaml", INDEX)
afford("17 an absent schema vocabulary is named", { "blocked:status-vocab-absent: " .. noschema .. ": statuses" },
    { "remedy: add statuses" }, gate{ novocab, noschema })
put("noschema.yaml", SCHEMA)
cleared("17 absent vocabularies", novocab, noschema)

T:finish()
