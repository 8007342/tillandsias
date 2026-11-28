-- @trace order:2456-lrly
-- @env LEMONADE_RELAY_FIXTURE_FILE
-- check-lemonade-relay-policy.lua: the forge -> host Lemonade relay keeps its
-- approved security policy (order 2456-lrly).
--
-- Two halves, both required:
--   1. STATIC: the route allowlist in lemonade_relay.rs is EXACTLY the
--      approved one. Adding a route (say /api/v1/pull) is a policy change, so
--      it must change this pin in the same diff, where review sees it.
--   2. RUN: the policy tests are run, not grepped: a name survives an emptied
--      or #[ignore]d body. The relay core is portable (no cfg gate), so any
--      host's cargo compiles the real module, not a stub.
--
-- Grammar (one line):
--   ok:lemonade-relay-policy-verified:<count>                    exit 0
--   skip:lemonade-relay-policy-unverifiable:no-cargo             exit 0
--   skip:lemonade-relay-policy-unverifiable:toolchain-blocked    exit 0 (Smart App Control)
--   violation:lemonade-relay-policy:allowlist-drift:<route>      exit 1
--   violation:lemonade-relay-policy:runner-failed                exit 1
--   violation:lemonade-relay-policy:missing-test:<name>          exit 1
--   violation:lemonade-relay-policy:tests-failed:<name>          exit 1
-- Test seam: LEMONADE_RELAY_FIXTURE_FILE names a recorded cargo transcript.

local SOURCE = "crates/tillandsias-windows-tray/src/lemonade_relay.rs"

local APPROVED_ROUTES = {
    "GET /api/v1/models",
    "POST /api/v1/chat/completions",
    "POST /api/v1/completions",
    "POST /api/v1/embeddings",
    "POST /api/v1/reranking",
    "POST /api/v1/audio/transcriptions",
    "POST /api/v1/audio/speech",
    "POST /api/v1/images/generations",
    "POST /api/v1/images/edits",
}

local PINNED_TESTS = {
    "every_refused_route_is_a_named_403_and_opens_no_upstream_connection",
    "an_allowlisted_request_reaches_upstream_with_rebuilt_headers",
    "an_unapproved_model_is_refused_in_json_and_in_multipart",
    "content_length_with_transfer_encoding_is_refused",
    "an_oversized_body_is_refused_before_it_is_read",
    "a_bad_credential_is_dropped_silently_with_no_upstream_connection",
    "get_models_is_built_from_the_approved_set_without_upstream",
    "a_lane_at_its_concurrency_cap_is_refused",
    "the_tray_default_upstream_is_fixed_loopback_13305",
}

-- 1. Static allowlist pin.
local src = fs.read(SOURCE) or ""
local found, seen = {}, {}
for method, path in src:gmatch('method:%s*"(%u+)",%s*path:%s*"([^"]+)"') do
    local r = method .. " " .. path
    found[#found + 1] = r
    seen[r] = true
end
local approved = {}
for _, r in ipairs(APPROVED_ROUTES) do
    approved[r] = true
    if not seen[r] then verdict.emit("violation:lemonade-relay-policy:allowlist-drift:missing:" .. r, 1) end
end
for _, r in ipairs(found) do
    if not approved[r] then verdict.emit("violation:lemonade-relay-policy:allowlist-drift:added:" .. r, 1) end
end

-- 2. Run the policy tests.
local output
local fixture = env.get("LEMONADE_RELAY_FIXTURE_FILE")
if fixture ~= nil and fixture ~= "" then
    output = fs.read(fixture) or ""
else
    local cargo = require("common.fixture").which("cargo") or require("common.fixture").which("cargo.exe")
    if not cargo then verdict.emit("skip:lemonade-relay-policy-unverifiable:no-cargo", 0) end
    local r = proc.run({ argv = { cargo, "test", "-p", "tillandsias-windows-tray",
        "--bin", "tillandsias-windows-tray", "lemonade_relay" }, timeout_ms = 170000 })
    output = (r.stdout or "") .. "\n" .. (r.stderr or "")
end

if text.contains(output, "Application Control policy has blocked") then
    verdict.emit("skip:lemonade-relay-policy-unverifiable:toolchain-blocked", 0)
end
if not text.is_match(output, "(?m)^test .* \\.\\.\\. (ok|FAILED|ignored)") then
    for _, l in ipairs(text.lines(output)) do
        if l:find("^error") then out.line("  " .. l) end
    end
    verdict.emit("violation:lemonade-relay-policy:runner-failed", 1)
end
for _, t in ipairs(PINNED_TESTS) do
    if text.is_match(output, "(?m)^test .*" .. t .. " \\.\\.\\. FAILED") then
        verdict.emit("violation:lemonade-relay-policy:tests-failed:" .. t, 1)
    end
    if not text.is_match(output, "(?m)^test .*" .. t .. " \\.\\.\\. ok") then
        verdict.emit("violation:lemonade-relay-policy:missing-test:" .. t, 1)
    end
end

verdict.emit("ok:lemonade-relay-policy-verified:" .. tostring(#PINNED_TESTS), 0)
