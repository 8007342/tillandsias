-- @trace order:832-698m, order:746-htj9, order:851-cduu, order:2360-psb8
-- @env PATH HOME
--
-- test-set-field-yaml-shapes.lua — `tillandsias-plan set-field` must write a fragment
-- that is valid YAML for every shape of value, and the value must round-trip exactly.
-- Ported from test-set-field-yaml-shapes.sh (2360-psb8); same seven shapes. The .sh counted 14 (valid + round-trip); the port also counts "a fragment was written", so 21.
--
-- THE SAME BUG TWICE. 832-698m (2026-08-22): the value was interpolated raw, and a
-- next_action beginning "Wave 2: (1) seed …" became a nested mapping. 2026-08-23: a
-- MULTI-LINE value became a block scalar indented less than its key ("did not find
-- expected '-' indicator"). Both times set-field printed ok: and the pre-push gate
-- caught it. A writer that says ok: while emitting an unparseable fragment into an
-- append-only ledger is the worst shape available.
--
-- The validator is the binary under test (746-htj9): the claim is "the WRITER emits YAML
-- whose value round-trips" and the reader is serde_yaml, the library every consumer uses.
-- HERMETIC: a tiny ledger in scratch; never touches plan/.
--
-- GRAMMAR ok:set-field-yaml-shapes:<n> arms | violation:set-field-yaml-shapes:<n>-failed
--       | refused:set-field-yaml-shapes:no-plan-binary

local fixture = require "common.fixture"
local T = fixture.new("set-field-yaml-shapes")
local ROOT = fixture.repo_root()
local PLAN = fixture.plan_binary()
if PLAN == "" then T:refuse("no-plan-binary", "build one: cargo build --release -p tillandsias-plan") end
if PLAN:sub(1, 1) ~= "/" then PLAN = ROOT .. "/" .. PLAN:gsub("^%./", "") end

local W = T:scratch()
local SEED = [[
plan_index:
  steps:
    - packet_id: fixture/alpha
      order: 900-aaaa
      title: "A fixture packet"
      status: ready
      kind: fix
      events:
        - type: note
          ts: "2025-12-31T00:00:00Z"
          agent_id: seed
          host: fixture
          summary: |
            A pre-existing event so the events list is block-style.
]]

local n = 0
local function case(label, value)
    -- A fresh ledger per case, so "the fragment" is the only one there.
    n = n + 1
    local d = W.rel .. "/c" .. n
    fs.mkdir(d .. "/index.d")
    fs.write(d .. "/index.yaml", SEED)
    local idx = W.abs .. "/c" .. n .. "/index.yaml"
    T:run{ PLAN, "--index", idx, "set-field", "900-aaaa", "next_action", value, "--host", "fixture",
        cwd = ROOT, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 60000 }
    local frag
    for _, f in ipairs(fs.list(d .. "/index.d") or {}) do
        if f:match("%.yaml$") then frag = W.abs .. "/c" .. n .. "/index.d/" .. f end
    end
    if not T:arm(label .. ": a fragment was written", frag ~= nil, "missing") then return end
    local v = T:run{ PLAN, "validate-yaml", frag, timeout_ms = 30000 }
    if not T:arm(label .. ": fragment is valid YAML", v.code == 0, (v.stdout or "") .. (v.stderr or "")) then return end
    local got = (T:run{ PLAN, "yaml-get", frag, "status.0.value", timeout_ms = 30000 }.stdout or ""):gsub("\n$", "")
    T:arm(label .. ": value round-trips exactly", got == value, "[" .. got .. "]")
end

-- 832-698m: colon-space in prose opened a nested mapping.
case("colon-space", "Wave 2: (1) seed the corpus, then measure")
-- 2026-08-23: multi-line became an under-indented block scalar.
case("multi-line", "CAMPAIGN STATE.\nSecond line, with a colon: here.\n(1) a numbered clause")
-- Continuation lines that are list-shaped: the characters the failing parse named.
case("multi-line-with-dashes", "Header line\n- a dash-led line\n- another")
-- Shapes that would break a naive quoted emitter.
case("apostrophe", "the host's own claimed work")
case("leading-dash", "- starts with a dash")
case("trailing-colon", "see also:")
case("blank-line", "First paragraph.\n\nSecond paragraph after a blank line.")

T:finish()
