-- @trace spec:project-summarizers, order:2312-psb3
--
-- test-summarize-pubspec.lua — scripts/summarize-pubspec.sh on hermetic
-- manifests. Ported from test-summarize-pubspec.sh (2312-psb3); the .sh's
-- three groups become three arms, each naming every line it missed.
--
--   1 a Flutter manifest: Flutter, Dart SDK, Provider, Riverpod, 5 direct deps;
--     the same manifest gives the same output twice
--   2 a Dart-only manifest: SDK and 1 dep; never "Flutter", and provider_tools
--     is not reported as provider
--   3 a missing manifest: rc 2 and no output
--
-- GRAMMAR ok:summarize-pubspec:3 arms | violation:summarize-pubspec:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("summarize-pubspec")
local ROOT = fixture.repo_root()
local SH = fixture.posix_shell()
local W = T:scratch()
fs.mkdir(W.rel .. "/flutter"); fs.mkdir(W.rel .. "/dart")

local function summarize(dir)
    local r = proc.run{ argv = { SH, ROOT .. "/scripts/summarize-pubspec.sh", W.abs .. "/" .. dir }, timeout_ms = 30000 }
    return (r.status == "exited") and r.code or -1, r.stdout or "", r.stderr or ""
end
local function missing(o, wants)
    local m = {}
    for _, w in ipairs(wants) do if not o:find(w, 1, true) then m[#m + 1] = w end end
    return m
end

fs.write(W.rel .. "/flutter/pubspec.yaml", table.concat({
    "name: freshness_probe", "version: 1.2.3", "environment:", "  sdk: '>=3.4.0 <4.0.0'", '  flutter: ">=3.22.0"',
    "dependencies:", "  flutter:", "    sdk: flutter", "  riverpod: ^2.5.1", "  provider: ^6.1.2",
    "dev_dependencies:", "  flutter_test:", "    sdk: flutter", "  lints: ^4.0.0",
    "flutter:", "  uses-material-design: true", "" }, "\n"))
local c1, f1 = summarize("flutter")
local _, f2 = summarize("flutter")
local m1 = missing(f1, { "- Dart (Flutter project)", "- Flutter (>=3.22.0)", "- Dart SDK (>=3.4.0 <4.0.0)",
    "- Provider (state management)", "- Riverpod (reactive state)", "- Direct pub dependencies (5 total)" })
T:arm("1 a Flutter manifest is summarised, deterministically", c1 == 0 and #m1 == 0 and f1 == f2,
    "rc=" .. c1 .. " missing=[" .. table.concat(m1, "; ") .. "] same=" .. tostring(f1 == f2))

fs.write(W.rel .. "/dart/pubspec.yaml", table.concat({
    "name: dart_only", "environment:", '  sdk: ">=3.3.0 <4.0.0"', "dependencies:", "  provider_tools: ^1.0.0", "" }, "\n"))
local c2, d = summarize("dart")
local m2 = missing(d, { "- Dart SDK (>=3.3.0 <4.0.0)", "- Direct pub dependencies (1 total)" })
local flutter = d:find("Flutter", 1, true) ~= nil
local provider = d:find("Provider (state management)", 1, true) ~= nil
T:arm("2 a Dart-only manifest is not Flutter, and provider_tools is not provider",
    c2 == 0 and #m2 == 0 and not flutter and not provider,
    "rc=" .. c2 .. " missing=[" .. table.concat(m2, "; ") .. "] flutter=" .. tostring(flutter) .. " provider=" .. tostring(provider))

local c3, o3, e3 = summarize("missing")
T:arm("3 a missing manifest exits 2 and writes nothing", c3 == 2 and o3 == "" and e3 == "",
    "rc=" .. c3 .. " out='" .. text.trim(o3 .. e3) .. "'")
T:finish()
