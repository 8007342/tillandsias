-- @trace order:2080-zcur
--
-- test-summarize-pubspec.lua — scripts/summarize-pubspec.sh summarizes a
-- pubspec.yaml deterministically: a Flutter app names Flutter, the SDK range,
-- state-management packages and the direct dependency count; a Dart-only
-- package is not called Flutter and provider_tools is not provider; a missing
-- manifest exits 2 and prints nothing.
-- Ported from scripts/test-summarize-pubspec.sh onto common.fixture.
--
-- Usage: tillandsias-plan script run scripts/lua/test-summarize-pubspec.lua
-- Verdict: ok:summarize-pubspec:<n> arms | violation:summarize-pubspec:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("summarize-pubspec")
local S = fixture.repo_root() .. "/scripts/summarize-pubspec.sh"
local W = T:scratch()
fs.mkdir(W.rel .. "/flutter"); fs.mkdir(W.rel .. "/dart")
fs.write(W.rel .. "/flutter/pubspec.yaml", table.concat({
    "name: freshness_probe", "version: 1.2.3", "environment:", "  sdk: '>=3.4.0 <4.0.0'",
    '  flutter: ">=3.22.0"', "dependencies:", "  flutter:", "    sdk: flutter", "  riverpod: ^2.5.1",
    "  provider: ^6.1.2", "dev_dependencies:", "  flutter_test:", "    sdk: flutter", "  lints: ^4.0.0",
    "flutter:", "  uses-material-design: true" }, "\n") .. "\n")
fs.write(W.rel .. "/dart/pubspec.yaml", table.concat({
    "name: dart_only", "environment:", '  sdk: ">=3.3.0 <4.0.0"', "dependencies:", "  provider_tools: ^1.0.0" }, "\n") .. "\n")
local function sum(dir)
    local r = T:run{ S, W.abs .. "/" .. dir }
    return r.code, (r.stdout or ""), (r.stderr or "")
end

local _, f1 = sum("flutter")
local missing = {}
for _, want in ipairs{ "- Dart (Flutter project)", "- Flutter (>=3.22.0)", "- Dart SDK (>=3.4.0 <4.0.0)",
    "- Provider (state management)", "- Riverpod (reactive state)", "- Direct pub dependencies (5 total)" } do
    if not text.contains(f1, want) then missing[#missing + 1] = want end
end
local _, f2 = sum("flutter")
T:arm("1 a Flutter manifest is summarized, the same way twice", #missing == 0 and f1 == f2,
    #missing > 0 and ("missing: " .. table.concat(missing, "; ")) or "two runs differ")
local _, d = sum("dart")
T:arm("2 a Dart-only manifest is not Flutter, and provider_tools is not provider",
    text.contains(d, "- Dart SDK (>=3.3.0 <4.0.0)") and text.contains(d, "- Direct pub dependencies (1 total)")
        and not text.contains(d, "Flutter") and not text.contains(d, "Provider (state management)"), d)
local rc, o, e = sum("missing")
T:arm("3 a missing manifest exits 2 and prints nothing", rc == 2 and o == "" and e == "",
    "rc=" .. tostring(rc) .. " out='" .. o .. e .. "'")
T:finish()
