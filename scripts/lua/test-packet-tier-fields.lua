-- @trace order:1437-khnx, order:1832-5a9z, spec:meta-orchestration, order:2385-psbb
-- inputs: methodology/convergence.yaml methodology/distributed-work.yaml plan/index.yaml scripts/agent-identity.sh scripts/build-image.sh scripts/derive-host-identity.sh scripts/lib/tool-dispatch.sh scripts/lua/check-claims-across-branches.lua scripts/lua/test-capability-routing.lua scripts/lua/test-claims-across-branches.lua scripts/nix-toolbox.sh scripts/plan-binary-probe.sh scripts/select-work-batch.sh lib/lua/common/ crates/tillandsias-plan/
-- @env PATH HOME TMPDIR
--
-- test-packet-tier-fields.lua — fixture for the tier-routing scalars `size` and
-- `implementer_tier` (1437-khnx) and the `local` routing floor (1832-5a9z), over scratch
-- ledgers driven through --index. Ported from test-packet-tier-fields.sh (2385-psbb); same
-- ten arms.
--
--   1  top-level scalars project (S haiku); an untagged row projects NEITHER key (the
--      untagged=opus rule is the selector's, 1437-vdz5, never a projection default)
--   2  the notes-line fallback projects identically
--   3  set-field implementer_tier sonnet is folded over the note
--   4  NEGATIVE CONTROL: check --strict-fragments and set-field refuse size=XL /
--      implementer_tier=gpt by name
--   5  set-field implementer_tier local is accepted and folded; strict-fragments passes it
--   6  local caller + reachable endpoint gets only the local row (tier=local)
--   7  local caller + endpoint down is demoted (tier=haiku tier_demoted=local)
--   8  local caller with no local rows refuses refused:no-tier-work:model-tier=local
--   9  haiku caller takes haiku rows first, then drains local rows
--   10 an unknown tier is still refused
--
-- Every child runs with TILLANDSIAS_* stripped (the selector reads a dozen ambient host and
-- tier knobs) and gets the .sh's exported TILLANDSIAS_PLAN_BIN; set-field runs without
-- TILLANDSIAS_HOST_KIND, as the .sh's `env -u`. The selector gets a curl shim on PATH and a
-- plan shim pinned to the scratch ledger. No build.sh child: gate_inherit n/a.
--
-- GRAMMAR ok:packet-tier-fields:<n> arms | violation:packet-tier-fields:<n>-failed
--       | skip:packet-tier-fields:no-validator

local fixture = require "common.fixture"
local T = fixture.new("packet-tier-fields")
local ROOT, SH = fixture.repo_root(), fixture.posix_shell()
local PLAN = fixture.plan_binary()
if PLAN == "" then T:skip("no-validator") end
local W = T:scratch()
local UNSET = { "TILLANDSIAS_*" }
local BASE = { TILLANDSIAS_PLAN_BIN = PLAN }
local TMPDIR = env.get("TMPDIR")
if TMPDIR and TMPDIR ~= "" then BASE.TMPDIR = TMPDIR end
local function with(extra)
    local e = {}
    for k, v in pairs(BASE) do e[k] = v end
    for k, v in pairs(extra or {}) do e[k] = v end
    return e
end
local function plan(...)
    local a = { PLAN }
    for _, v in ipairs({ ... }) do a[#a + 1] = v end
    a.cwd, a.env, a.env_unset, a.timeout_ms = ROOT, with(), UNSET, 60000
    local r = T:run(a)
    return r.code, (r.stdout or "") .. (r.stderr or ""), r.stdout or ""
end

local function mk(name, extra)
    fs.mkdir(W.rel .. "/" .. name .. "/plan/index.d")
    fs.write(W.rel .. "/" .. name .. "/plan/index.yaml", "packets: []\n")
    fs.write(W.rel .. "/" .. name .. "/plan/index.d/20260927t000000z-00000000-fixture.yaml",
        "packets:\n  - packet_id: a-tier-row\n    order: 1-tier\n    status: ready\n"
        .. "    kind: enhancement\n    priority: p2\n    desired_release: v0.5\n"
        .. "    pickup_role: any\n    title: a row with tier fields\n"
        .. "    unscoreable: \"fixture packet; not scored\"\n" .. extra .. "\n")
    return W.abs .. "/" .. name .. "/plan/index.yaml"
end
-- "size implementer_tier" of the fixture row, "-" when absent; the plan binary's own reader.
local function proj(index)
    local _, _, q = plan("--index", index, "query", "--json", "--limit", "50")
    local r = T:run{ PLAN, "json", "get", "-c",
        '.[] | select(.packet_id == "a-tier-row") | [.size, .implementer_tier]',
        stdin = q, env = with(), env_unset = UNSET, timeout_ms = 60000 }
    local s = text.trim(r.stdout or ""):gsub("null", '"-"'):gsub('^%["', ""):gsub('"%]$', ""):gsub('","', " ", 1)
    return s
end
local function set_field(index, value, reason)
    local a = { PLAN, "--index", index, "set-field", "1-tier", "implementer_tier", value, "--reason", reason,
        cwd = ROOT, env = with(), env_unset = { "TILLANDSIAS_*", "TILLANDSIAS_HOST_KIND" }, timeout_ms = 60000 }
    local r = T:run(a)
    return r.code, (r.stdout or "") .. (r.stderr or "")
end

-- 1
local a1 = mk("a1", "    size: S\n    implementer_tier: haiku")
local got = proj(a1)
local gotu = proj(mk("a1u", "    notes: |\n      no tier stated here"))
T:arm("arm 1: top-level scalars project (S haiku); an untagged row projects neither key",
    got == "S haiku" and gotu == "- -", "want 'S haiku' and '- -', got '" .. got .. "' / '" .. gotu .. "'")

-- 2
local a2 = mk("a2", "    notes: |\n      size: S\n      implementer_tier: haiku\n      Prose that follows the two lines.")
local got2 = proj(a2)
T:arm("arm 2: notes-line fallback projects identically", got2 == "S haiku", "want 'S haiku', got '" .. got2 .. "'")

-- 3
local rc3, out3 = set_field(a2, "sonnet", "fixture correction")
local got3 = proj(a2)
T:arm("arm 3: set-field implementer_tier sonnet is folded over the note", rc3 == 0 and got3 == "S sonnet",
    "rc=" .. tostring(rc3) .. " '" .. got3 .. "': " .. out3)

-- 4 NEGATIVE CONTROL
local rc4, out4 = plan("--index", mk("a4", "    size: XL\n    implementer_tier: gpt"), "check", "--strict-fragments")
local rc4s, out4s = set_field(a1, "gpt", "fixture")
local named_size = out4:find("refused:tier-vocabulary", 1, true) ~= nil
    and out4:find('size="XL"', (out4:find("refused:tier-vocabulary", 1, true) or 1), true) ~= nil
T:arm("arm 4: check --strict-fragments and set-field refuse size=XL / implementer_tier=gpt by name",
    rc4 ~= 0 and named_size and text.contains(out4, 'implementer_tier="gpt"')
        and rc4s ~= 0 and text.contains(out4s, "refused:set-field:tier-vocabulary"),
    "check rc=" .. tostring(rc4) .. ": " .. out4 .. " | set-field rc=" .. tostring(rc4s) .. ": " .. out4s)

-- 5 (1832-5a9z) `local` is in the vocabulary; gpt still refused (rc4s).
local a5 = mk("a5", "    implementer_tier: haiku")
local rc5, out5 = set_field(a5, "local", "fixture")
local got5 = proj(a5)
local _, out5s = plan("--index", mk("a5s", "    implementer_tier: local"), "check", "--strict-fragments")
local voc5 = text.contains(out5s, "refused:tier-vocabulary")
T:arm("arm 5: set-field implementer_tier local is accepted and folded; strict-fragments passes it; gpt still refused",
    rc5 == 0 and got5 == "- local" and not voc5 and rc4s ~= 0,
    "rc=" .. tostring(rc5) .. " '" .. got5 .. "' voc=" .. tostring(voc5) .. " gpt_rc=" .. tostring(rc4s) .. ": " .. out5 .. " | " .. out5s)

-- Selector fixtures: one ready role-any row per tier ("-" = untagged).
local function sel_ledger(name, ...)
    local b = { "plan_index:\n" }
    for n, t in ipairs({ ... }) do
        b[#b + 1] = string.format("  - packet_id: tier-sel-%s-%d\n    order: 99%d-tsel\n    status: ready\n    kind: bug\n    priority: p2\n", t, n, n)
        b[#b + 1] = string.format("    desired_release: v0.5\n    release_target: tier-sel-epic-%d\n    pickup_role: any\n", n)
        b[#b + 1] = string.format("    title: tier selector fixture %s\n    unscoreable: fixture row, never landed\n", t)
        if t ~= "-" then b[#b + 1] = "    implementer_tier: " .. t .. "\n" end
    end
    fs.write(W.rel .. "/" .. name, table.concat(b))
    return W.abs .. "/" .. name
end
local function exe(rel, body) fs.write(W.rel .. "/" .. rel, body); T:must{ "chmod", "+x", W.abs .. "/" .. rel } end
fs.mkdir(W.rel .. "/bin-curl-up"); fs.mkdir(W.rel .. "/bin-curl-down")
exe("bin-curl-up/curl", "#!/usr/bin/env bash\nexit 0\n")
exe("bin-curl-down/curl", "#!/usr/bin/env bash\nexit 22\n")
exe("plan-shim.sh", '#!/usr/bin/env bash\nexec "' .. PLAN .. '" --index "$TIER_SEL_LEDGER" "$@"\n')
local PATH = env.get("PATH") or ""
local function sel(led, cs, tier)
    local r = T:run{ SH, ROOT .. "/scripts/select-work-batch.sh", "any", "--budget", "5", "--tier", tier, cwd = ROOT,
        env = with{ TIER_SEL_LEDGER = led, PATH = W.abs .. "/bin-" .. cs .. ":" .. PATH,
            TILLANDSIAS_PLAN_BIN = W.abs .. "/plan-shim.sh", TILLANDSIAS_HOST_TIER = "general",
            TILLANDSIAS_XBRANCH_CHECK = "/bin/true", TILLANDSIAS_INFERENCE_ENDPOINT = "http://127.0.0.1:9" },
        env_unset = UNSET, timeout_ms = 120000 }
    return (r.stdout or "") .. (r.stderr or "")
end
local function orders(o)
    local s = ""
    for _, l in ipairs(text.lines(o)) do
        local f1, f2 = l:match("^([^\t]*)\t([^\t]*)")
        if f1 == "packet" then s = s .. f2 .. " " end
    end
    return s
end
local function head(o, n) local ls = text.lines(o); return table.concat(ls, "\n", 1, math.min(n, #ls)) end

local s1 = sel_ledger("s1.yaml", "local", "haiku", "-")
local out6 = sel(s1, "curl-up", "local")
T:arm("arm 6: local caller + reachable endpoint gets only the local row (tier=local)",
    text.contains(out6, " tier=local tier_fallback=0") and orders(out6) == "991-tsel ",
    "[" .. orders(out6) .. "]: " .. head(out6, 3))

local out7 = sel(s1, "curl-down", "local")
T:arm("arm 7: local caller + endpoint down is demoted to haiku (tier=haiku tier_demoted=local), haiku row first",
    text.contains(out7, " tier=haiku tier_fallback=0 tier_demoted=local") and orders(out7) == "992-tsel ",
    "[" .. orders(out7) .. "]: " .. head(out7, 3))

local out8 = sel(sel_ledger("s2.yaml", "haiku", "sonnet", "-"), "curl-up", "local")
T:arm("arm 8: local caller with no local rows refuses refused:no-tier-work:model-tier=local",
    text.starts_with(out8, "refused:no-tier-work:model-tier=local"), head(out8, 2))

local out9a = sel(s1, "curl-up", "haiku")
local out9b = sel(sel_ledger("s3.yaml", "local", "sonnet", "-"), "curl-up", "haiku")
T:arm("arm 9: haiku caller takes haiku rows first, then drains local rows (never sonnet or untagged)",
    text.contains(out9a, " tier=haiku tier_fallback=0") and orders(out9a) == "992-tsel "
        and text.contains(out9b, " tier=haiku tier_fallback=1") and orders(out9b) == "991-tsel ",
    "[" .. orders(out9a) .. "] / [" .. orders(out9b) .. "]")

local out10 = sel(s1, "curl-up", "gpt")
T:arm("arm 10: an unknown tier is still refused",
    text.starts_with(out10, "refused:") and text.contains(out10, "unknown model tier gpt"), head(out10, 2))

T:finish()
