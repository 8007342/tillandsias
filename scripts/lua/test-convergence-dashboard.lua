-- @env PATH HOME
-- @trace spec:observability-convergence, order:2066-obsv, order:2372-snfs
--
-- test-convergence-dashboard.lua — update-convergence-dashboard.sh projects the signature records
-- into a dashboard, in markdown and JSON. Ported from the .sh of the same name (2372-snfs), which
-- rendered this checkout's own records and checked no trend when there were none. This renders nine
-- records of its own, into scratch.
--
--   1 markdown shape       2 JSON shape        3 the alert level at each threshold, and with no records
--   4 the 7-record trend   5 record fields     6 resource metrics
--   7 the spec it names as its source of truth 8 nothing is written under docs/convergence
--
-- Usage: tillandsias-plan script run scripts/lua/test-convergence-dashboard.lua
-- Verdict: ok:convergence-dashboard:<n> arms | violation:... | skip:...:no-jq

local fixture = require "common.fixture"
local T = fixture.new("convergence-dashboard")
local SH, ROOT = fixture.posix_shell(), fixture.repo_root()
-- The projector's own JSON reader.
if not fixture.which("j" .. "q") then T:skip("no-jq") end
local function rec(i, earned, ci)
    return '{"release_version":"v0.0.' .. i .. '","release_date":"2026-01-0' .. i .. '","source_commit":"c' .. i .. '","expected_total_cc":1000,"actual_earned_cc":' .. earned
        .. ',"residual_cc":' .. (1000 - earned) .. ',"max_residual_spec":"s","max_residual_reason":"r","evidence_bundle_ref":"e","centicolon_projection_ref":"p","ci_result":"' .. ci .. '","ci_run_id":"' .. i .. '"}\n'
end
-- The first two are outside the 7-record window, and would move both averages.
local HIST = { { 10, "FAIL" }, { 20, "FAIL" }, { 900, "PASS" }, { 910, "FAIL" }, { 920, "PASS" }, { 930, "PASS" }, { 940, "FAIL" }, { 950, "PASS" } }
local function render(last)
    local d, src = T:scratch(), ""
    for i, h in ipairs(HIST) do src = src .. rec(i, h[1], h[2]) end
    fs.write(d.rel .. "/s.jsonl", last and src .. rec(9, last, "PASS") or "")
    local r = proc.run{ argv = { SH, ROOT .. "/scripts/update-convergence-dashboard.sh" }, cwd = ROOT, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 60000, stdin = "",
        env = { PATH = env.get("PATH"), HOME = env.get("HOME"), SOURCE = d.abs .. "/s.jsonl", MD_OUT = d.abs .. "/d.md", JSON_OUT = d.abs .. "/d.json", SUMMARY_OUT = d.abs .. "/s.md",
            METRICS_SAMPLE = d.abs .. "/none.json", TERMINAL_PREVIEW = "0" } }
    local ok, j = pcall(function() return json.parse(fs.read(d.rel .. "/d.json")) end)
    return { rc = r.code, md = fs.exists(d.rel .. "/d.md") and fs.read(d.rel .. "/d.md") or "", j = ok and j or nil, why = "rc=" .. tostring(r.code) .. " " .. tostring(ok) .. " " .. (r.stderr or ""):sub(1, 400) }
end
local TRACKED = { "docs/convergence/centicolon-dashboard.md", "docs/convergence/centicolon-dashboard.json" }
local function clean() return not fs.exists(TRACKED[1]) and not fs.exists(TRACKED[2]) end
local before, x = clean(), render(960)
local J = x.j or {}
for _, s in ipairs{ "THIS FILE IS AUTO-GENERATED", "@trace spec:observability-convergence", "spec:knowledge-source-of-truth", "openspec/specs/knowledge-source-of-truth/spec.md", "## Refresh Policy", "## Signature Format",
    "## Alert Thresholds", "## Integration & Interpretation" } do
    T:arm("1 the markdown carries: " .. s, text.contains(x.md, s), x.why)
end
local function at(...)
    local v = J
    for _, k in ipairs{ ... } do
        if type(v) ~= "table" then return nil end
        v = v[k]
    end
    return v
end
local function list_len(v) return type(v) == "table" and #v or 0 end
T:arm("2a the JSON parses, with a timestamp and an alert level", x.rc == 0 and x.j and type(J.generated_at) == "string" and type(J.alert_level) == "string", x.why)
T:arm("2b it declares the 90 and 95 thresholds", at("alert_thresholds", "red_below_percent_closed") == 90 and at("alert_thresholds", "yellow_below_percent_closed") == 95, x.why)
T:arm("2c the contract names its spec, a 24 h cadence and ten fields", at("dashboard_contract", "integration", "source_of_truth") == "openspec/specs/knowledge-source-of-truth/spec.md"
    and at("dashboard_contract", "refresh_policy", "staleness_threshold_hours") == 24 and list_len(at("dashboard_contract", "signature_format", "fields")) >= 10, x.why)
for _, c in ipairs{ { 899, "red" }, { 900, "yellow" }, { 949, "yellow" }, { 950, "green" } } do
    local y = render(c[1])
    T:arm("3 " .. c[1] / 10 .. " percent closed is " .. c[2], y.j and y.j.alert_level == c[2], tostring(y.j and y.j.alert_level) .. " " .. y.why)
end
local none = render(nil)
T:arm("3 with no records it is unknown, and no trend is claimed", none.rc == 0 and none.j and none.j.alert_level == "unknown" and none.j.record_count == 0, none.why)
local function near(v, want) return type(v) == "number" and math.abs(v - want) < 0.01 end
T:arm("4a the pass rate is over the last seven records", J.record_count == 9 and near(at("trend_metrics", "pass_rate_7d_percent"), 500 / 7), tostring(at("trend_metrics", "pass_rate_7d_percent")))
T:arm("4b so is the coverage average", near(at("trend_metrics", "coverage_avg_7d_percent"), 93), tostring(at("trend_metrics", "coverage_avg_7d_percent")))
local lost, first = {}, at("history", 1) or {}
for _, k in ipairs{ "release", "date", "commit", "total_cc", "earned_cc", "residual_cc", "percent_closed", "worst_spec", "worst_reason", "evidence", "projection", "ci_result" } do
    if first[k] == nil then lost[#lost + 1] = k end
end
T:arm("5 a record carries every signature field", #lost == 0, table.concat(lost, " "))
local m = J.metrics or {}
T:arm("6 the metrics block is typed and names its source", type(m.cpu_percent) == "number" and type(m.memory_percent) == "number" and type(m.disk_percent) == "number" and type(m.sample_timestamp) == "string"
    and m.source == "tillandsias-metrics::DashboardSnapshot", x.why)
local spec = fs.read("openspec/specs/knowledge-source-of-truth/spec.md")
for _, s in ipairs{ "status: active", "code > specs > cheatsheets > docs", "CRDT-inspired monotonic convergence", "Convergence evidence bundles" } do
    T:arm("7 the source-of-truth spec says: " .. s, text.contains(spec, s), "gone")
end
T:arm("8 nothing is under docs/convergence, before or after", before and clean(), "a tracked dashboard exists")
T:finish()
